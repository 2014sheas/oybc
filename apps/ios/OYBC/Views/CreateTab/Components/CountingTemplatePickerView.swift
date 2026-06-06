import GRDB
import SwiftUI

// MARK: - Supporting types

/// Which mode the picker is in.
enum CountingPickerMode {
    case template     // "Use as template" — pre-fills action/unit
    case link         // "Link to existing counter" — Phase 2
}

/// Baseline mode for "Link to existing counter".
enum CountingPickerBaselineMode: String, CaseIterable {
    case inherit = "Inherit"
    case startFromZero = "Start from zero"

    var hint: String {
        switch self {
        case .inherit:      return "Start counting from source's current total"
        case .startFromZero: return "Ignore counts before link time"
        }
    }
}

/// Result emitted by the "Link" mode's create action.
struct LinkedCounterInput {
    /// The source counting task.
    let source: OYBC.Task
    /// User-supplied threshold (>= 1).
    let maxCount: Int
    /// Title for the new task (auto-generated if user left it blank).
    let title: String
    /// Baseline mode chosen by the user.
    let baselineMode: CountingPickerBaselineMode
    /// Computed baseline: 0 for Inherit, source.currentCount for Start from zero.
    let baseline: Int
}

// MARK: - Main view

/// CountingTemplatePickerView — "Derive from existing" affordance for the
/// counting-type variant of `CreateNewTaskFormView`. Mirrors the web
/// `CountingTemplatePicker` component.
///
/// ## Modes (Phase 2 addition)
///
/// A segmented control at the top switches between:
/// - **Use as template**: original behaviour — pre-fills action/unit into
///   a brand-new independent task; `maxCount` left empty.
/// - **Link to existing counter**: picks a source, sets a personal threshold
///   (Threshold), chooses Inherit / Start from zero baseline mode, previews
///   a `DerivedCounterRowView`, then calls `onCreateLinked` on commit.
///
/// ## Template mode (unchanged from Phase 1)
///
/// When no template is selected: shows a dashed "Use existing counting task
/// as template..." button that opens a sheet list. When selected: shows a
/// compact "Template: <title>" banner with a clear button.
///
/// ## Link mode (Phase 2)
///
/// Shows source picker, Threshold input, baseline radio, live preview, and
/// "Create linked task" button that calls `onCreateLinked`.
struct CountingTemplatePickerView: View {

    // MARK: - Props

    /// The authenticated user whose task library to query.
    let userId: String

    /// The counting Task currently used as a template, or nil (template mode).
    let selectedTemplate: OYBC.Task?

    /// Called when the user picks a source counting task in template mode.
    let onSelect: (OYBC.Task) -> Void

    /// Called when the user clears the current template selection.
    let onClear: () -> Void

    /// Phase 2 — Called when the user commits the Link mode create flow.
    /// When nil the Create button is disabled (context doesn't support linking yet).
    var onCreateLinked: ((LinkedCounterInput) -> Void)? = nil

    // MARK: - Mode state

    @State private var pickerMode: CountingPickerMode = .template

    // MARK: - Template-mode state

    @State private var showTemplatePicker = false
    @State private var countingTasks: [OYBC.Task] = []
    @State private var loadError: String?

    // MARK: - Link-mode state

    @State private var linkSource: OYBC.Task? = nil
    @State private var showLinkPicker = false
    @State private var thresholdStr: String = ""
    @State private var baselineMode: CountingPickerBaselineMode = .inherit
    @State private var linkedTitle: String = ""
    @State private var linkError: String? = nil

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Mode toggle
            Picker("Mode", selection: $pickerMode) {
                Text("Use as template").tag(CountingPickerMode.template)
                Text("Link to existing counter").tag(CountingPickerMode.link)
            }
            .pickerStyle(.segmented)
            .onChange(of: pickerMode) { _, newMode in
                handleModeChange(newMode)
            }

            switch pickerMode {
            case .template:
                templateModeBody
            case .link:
                linkModeBody
            }
        }
        .onAppear { loadCountingTasks() }
        .onChange(of: showTemplatePicker) { _, showing in
            if showing { loadCountingTasks() }
        }
        .onChange(of: showLinkPicker) { _, showing in
            if showing { loadCountingTasks() }
        }
        .sheet(isPresented: $showTemplatePicker) {
            taskPickerSheet(
                title: "Choose template",
                onPick: { task in
                    onSelect(task)
                    showTemplatePicker = false
                }
            )
        }
        .sheet(isPresented: $showLinkPicker) {
            taskPickerSheet(
                title: "Choose source counter",
                onPick: { task in
                    handleLinkSourceSelect(task)
                    showLinkPicker = false
                }
            )
        }
    }

    // MARK: - Template mode body

    @ViewBuilder
    private var templateModeBody: some View {
        if let template = selectedTemplate {
            selectedBanner(label: "Template", title: template.title, onClearTap: onClear)
        } else {
            affordanceButton(label: "Use existing counting task as template...") {
                showTemplatePicker = true
            }
        }
    }

    // MARK: - Link mode body

    @ViewBuilder
    private var linkModeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Source picker
            Group {
                if let source = linkSource {
                    selectedBanner(label: "Source", title: source.title) {
                        linkSource = nil
                        linkedTitle = ""
                    }
                } else {
                    affordanceButton(label: "Pick a source counter...") {
                        showLinkPicker = true
                    }
                }
            }

            // Threshold
            VStack(alignment: .leading, spacing: 4) {
                Text("THRESHOLD")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                TextField("e.g. 50", text: $thresholdStr)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: thresholdStr) { _, _ in autoFillTitle() }
            }

            // Title (editable, auto-filled)
            VStack(alignment: .leading, spacing: 4) {
                Text("TITLE")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                TextField(titlePlaceholder, text: $linkedTitle)
                    .textFieldStyle(.roundedBorder)
            }

            // Baseline radio
            VStack(alignment: .leading, spacing: 4) {
                Text("BASELINE")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                ForEach(CountingPickerBaselineMode.allCases, id: \.self) { mode in
                    Button {
                        baselineMode = mode
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: baselineMode == mode
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .foregroundStyle(baselineMode == mode ? Color.accentColor : .secondary)
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(mode.rawValue)
                                    .foregroundStyle(.primary)
                                    .font(.subheadline)
                                Text(mode.hint)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Preview
            if let preview = linkPreviewData {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PREVIEW")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    DerivedCounterRowView(
                        data: preview.data,
                        displayed: preview.displayed,
                        isCompleted: preview.isCompleted
                    )
                }
            }

            // Error
            if let linkError {
                Text(linkError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Create button
            Button {
                handleCreateLinked()
            } label: {
                Text("Create linked task")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(onCreateLinked == nil)

            // Stub note
            Text("Linked counter — increments via source task (wire-up in Phase 3)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .italic()
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.separator), lineWidth: 1)
        )
    }

    // MARK: - Shared sub-views

    private func selectedBanner(label: String, title: String, onClearTap: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text("\(label):")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize()

            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onClearTap()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear \(label.lowercased())")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(Color(.systemGray6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    private func affordanceButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                Text(label)
                    .font(.subheadline)
                Spacer()
            }
            .foregroundColor(.secondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundColor(.secondary.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
    }

    /// Sheet that lists all counting tasks for the caller to pick from.
    private func taskPickerSheet(
        title: String,
        onPick: @escaping (OYBC.Task) -> Void
    ) -> some View {
        NavigationStack {
            Group {
                if let error = loadError {
                    Text(error).foregroundColor(.red).padding()
                } else if countingTasks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No counting tasks in your library yet.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(countingTasks, id: \.id) { task in
                        Button {
                            onPick(task)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .foregroundColor(.primary)
                                if let action = task.action, let unit = task.unit {
                                    let count = task.currentCount ?? 0
                                    Text("\(action) · \(unit) · \(count) so far")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showTemplatePicker = false
                        showLinkPicker = false
                    }
                }
            }
        }
    }

    // MARK: - Derived / computed

    private var titlePlaceholder: String {
        guard let source = linkSource,
              let maxCount = Int(thresholdStr), maxCount >= 1 else {
            return "Auto-generated from source"
        }
        let action = source.action ?? ""
        let unit = source.unit ?? ""
        // Mirror generateCounterTaskTitle from @oybc/shared:
        //   "\(action) \(maxCount) \(unit)".trimmingCharacters(in: .whitespaces)
        return [action, "\(maxCount)", unit]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private struct LinkPreview {
        let data: DerivedCounterRowData
        let displayed: Int
        let isCompleted: Bool
    }

    private var linkPreviewData: LinkPreview? {
        guard let source = linkSource,
              let maxCount = Int(thresholdStr), maxCount >= 1 else { return nil }
        let sourceCount = source.currentCount ?? 0
        let baselineVal = baselineMode == .inherit ? 0 : sourceCount
        let result = deriveDisplayedCount(
            derivedBaseline: baselineVal,
            derivedMaxCount: maxCount,
            sourceCurrentCount: sourceCount
        )
        let previewTitle = linkedTitle.isEmpty ? titlePlaceholder : linkedTitle
        let data = DerivedCounterRowData(
            id: "preview",
            title: previewTitle,
            maxCount: maxCount,
            baseline: baselineVal,
            baselineMode: baselineMode == .inherit ? .inherit : .startFromZero
        )
        return LinkPreview(data: data, displayed: result.displayed, isCompleted: result.isCompleted)
    }

    // MARK: - Handlers

    private func handleModeChange(_ newMode: CountingPickerMode) {
        if newMode == .template {
            // Reset link state when switching back.
            linkSource = nil
            thresholdStr = ""
            baselineMode = .inherit
            linkedTitle = ""
            linkError = nil
        }
        if newMode == .link, selectedTemplate != nil {
            // Clear template selection when entering link mode.
            onClear()
        }
    }

    private func handleLinkSourceSelect(_ task: OYBC.Task) {
        linkSource = task
        autoFillTitle()
    }

    private func autoFillTitle() {
        guard let source = linkSource,
              let maxCount = Int(thresholdStr), maxCount >= 1 else { return }
        let action = source.action ?? ""
        let unit = source.unit ?? ""
        linkedTitle = [action, "\(maxCount)", unit]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func handleCreateLinked() {
        linkError = nil
        guard let source = linkSource else {
            linkError = "Select a source counter."
            return
        }
        guard let maxCount = Int(thresholdStr), maxCount >= 1 else {
            linkError = "Threshold must be a positive integer."
            return
        }
        let sourceCount = source.currentCount ?? 0
        let baselineVal = baselineMode == .inherit ? 0 : sourceCount
        let finalTitle = linkedTitle.isEmpty ? titlePlaceholder : linkedTitle

        onCreateLinked?(LinkedCounterInput(
            source: source,
            maxCount: maxCount,
            title: finalTitle,
            baselineMode: baselineMode,
            baseline: baselineVal
        ))
    }

    // MARK: - Data loading

    private func loadCountingTasks() {
        _Concurrency.Task {
            do {
                let tasks = try await AppDatabase.shared.read { db in
                    try OYBC.Task
                        .filter(Column("userId") == userId &&
                                Column("type") == "counting" &&
                                Column("isDeleted") == false)
                        .order(Column("title"))
                        .fetchAll(db)
                }
                await MainActor.run {
                    self.countingTasks = tasks
                    self.loadError = nil
                }
            } catch {
                await MainActor.run {
                    self.loadError = "Could not load counting tasks: \(error.localizedDescription)"
                }
            }
        }
    }
}
