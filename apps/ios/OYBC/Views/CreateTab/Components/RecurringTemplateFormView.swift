import SwiftUI

/// RecurringTemplateFormView — sheet form to create or edit a
/// `RecurringBoardTemplate` (Phase 6.2). Web twin:
/// `apps/web/src/components/recurringTemplates/RecurringTemplateForm.tsx`.
///
/// Supports two modes via the optional `existing` parameter:
/// - Create: `existing` is nil. Submit calls `saveRecurringBoardTemplate`
///   on a freshly-built row.
/// - Edit: `existing` is set. Submit clones the existing row, applies
///   the form's edits, bumps version + updatedAt, and saves.
///   `lastSpawnedWindowKey` is preserved (only the spawn path mutates it).
///
/// Validation gates the Save button. MVP scope excludes
/// `CenterSquareType.chosen` — the picker only shows free / customFree /
/// none.
struct RecurringTemplateFormView: View {

    // MARK: - Inputs

    let userId: String
    let libraryTasks: [Task]
    var existing: RecurringBoardTemplate?
    let onClose: () -> Void

    // MARK: - State

    @State private var name: String = ""
    @State private var timeframe: Timeframe = .daily
    @State private var boardSize: Int = 5
    @State private var centerSquareType: CenterSquareType = .free
    @State private var centerSquareCustomName: String = ""
    @State private var poolStrategy: PoolStrategy = .all
    @State private var isRandomized: Bool = true
    @State private var isActive: Bool = true
    @State private var seedTaskIds: [String] = []
    @State private var searchQuery: String = ""
    @State private var submitting = false
    @State private var submitError: String?

    // MARK: - Constants

    private let timeframes: [(value: Timeframe, label: String)] = [
        (.daily, "Daily"),
        (.weekly, "Weekly"),
        (.monthly, "Monthly"),
        (.yearly, "Yearly"),
    ]
    private let boardSizes: [(value: Int, label: String)] = [
        (3, "3 × 3"),
        (4, "4 × 4"),
        (5, "5 × 5"),
    ]
    private let centerTypes: [(value: CenterSquareType, label: String, hint: String)] = [
        (.free, "Free space", "Auto-completed center cell"),
        (.customFree, "Custom free space", "Auto-completed with your custom label"),
        (CenterSquareType.none, "No special center", "Center cell behaves like the others"),
    ]
    private let poolStrategies: [(value: PoolStrategy, label: String, hint: String)] = [
        (.all, "Use every task", "Pool size must exactly match the cells to fill"),
        (.randomSubset, "Random subset", "Pool can be larger; spawn picks N each window"),
    ]

    // MARK: - Derived

    private var fillableCells: Int {
        recurringTemplateFillableCellCount(boardSize: boardSize, centerSquareType: centerSquareType)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var customNameOk: Bool {
        centerSquareType != .customFree ||
        !centerSquareCustomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var poolSizeOk: Bool {
        switch poolStrategy {
        case .all: return seedTaskIds.count == fillableCells
        case .randomSubset: return seedTaskIds.count >= fillableCells
        }
    }

    private var formValid: Bool {
        !trimmedName.isEmpty &&
        trimmedName.count <= 120 &&
        !seedTaskIds.isEmpty &&
        customNameOk &&
        poolSizeOk &&
        !submitting
    }

    private var filteredLibrary: [Task] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return libraryTasks }
        return libraryTasks.filter { $0.title.lowercased().contains(q) }
    }

    // MARK: - Body

    var body: some View {
        // Break up the Form into smaller sub-sections so the SwiftUI
        // type-checker doesn't time out (each Section is its own computed
        // property below).
        NavigationStack {
            Form {
                nameSection
                timeframeSection
                boardSizeSection
                centerCellSection
                poolStrategySection
                togglesSection
                taskPoolSection
                if !poolSizeOk {
                    Section {
                        Text(poolSizeMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                if !customNameOk {
                    Section {
                        Text("Custom free spaces need a label.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                if let err = submitError {
                    Section {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New template" : "Edit template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitting ? "Saving…" : "Save") {
                        submit()
                    }
                    .disabled(!formValid)
                }
            }
            .onAppear(perform: hydrateFromExisting)
        }
    }

    // MARK: - Form sections (split out so the SwiftUI type-checker doesn't time out)

    private var nameSection: some View {
        Section("Template name") {
            TextField("e.g., Daily Workout", text: $name)
                .textInputAutocapitalization(.words)
        }
    }

    private var timeframeSection: some View {
        Section("Timeframe") {
            Picker("Timeframe", selection: $timeframe) {
                ForEach(timeframes, id: \.value) { tf in
                    Text(tf.label).tag(tf.value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var boardSizeSection: some View {
        Section("Board size") {
            Picker("Board size", selection: $boardSize) {
                ForEach(boardSizes, id: \.value) { s in
                    Text(s.label).tag(s.value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var centerCellSection: some View {
        Section("Center cell") {
            ForEach(centerTypes, id: \.value) { c in
                radioButtonRow(
                    label: c.label,
                    hint: c.hint,
                    isSelected: centerSquareType == c.value,
                    action: { centerSquareType = c.value }
                )
            }
            if centerSquareType == .customFree {
                TextField("Custom label (e.g., Win!)", text: $centerSquareCustomName)
            }
        }
    }

    private var poolStrategySection: some View {
        Section("Pool strategy") {
            ForEach(poolStrategies, id: \.value) { p in
                radioButtonRow(
                    label: p.label,
                    hint: p.hint,
                    isSelected: poolStrategy == p.value,
                    action: { poolStrategy = p.value }
                )
            }
        }
    }

    private var togglesSection: some View {
        Section {
            Toggle("Randomize task placement on each spawn", isOn: $isRandomized)
            Toggle("Active (spawn boards on rollover)", isOn: $isActive)
        }
    }

    @ViewBuilder
    private var taskPoolSection: some View {
        Section {
            HStack {
                Text("Task pool")
                Spacer()
                Text(poolSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            TextField("Search your library...", text: $searchQuery)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if libraryTasks.isEmpty {
                Text("Your library is empty. Add tasks first, then come back to build a template.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if filteredLibrary.isEmpty {
                Text("No tasks match your search.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(filteredLibrary, id: \.id) { task in
                    poolRow(task: task)
                }
            }
        }
    }

    private func radioButtonRow(
        label: String,
        hint: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .foregroundColor(.primary)
                        .fontWeight(.semibold)
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func poolRow(task: Task) -> some View {
        let checked = seedTaskIds.contains(task.id)
        Button {
            togglePool(taskId: task.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundColor(checked ? .accentColor : .secondary)
                Text(task.title)
                    .foregroundColor(.primary)
                Spacer()
                Text(task.type.rawValue.capitalized)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var poolSummary: String {
        let req = poolStrategy == .all ? "\(fillableCells) required" : "\(fillableCells) min"
        return "\(seedTaskIds.count) selected · \(req)"
    }

    private var poolSizeMessage: String {
        switch poolStrategy {
        case .all:
            return "Select exactly \(fillableCells) tasks (currently \(seedTaskIds.count))."
        case .randomSubset:
            return "Select at least \(fillableCells) tasks (currently \(seedTaskIds.count))."
        }
    }

    private func togglePool(taskId: String) {
        if let i = seedTaskIds.firstIndex(of: taskId) {
            seedTaskIds.remove(at: i)
        } else {
            seedTaskIds.append(taskId)
        }
    }

    private func hydrateFromExisting() {
        guard let t = existing else { return }
        name = t.name
        timeframe = t.timeframe
        boardSize = t.boardSize
        centerSquareType = t.centerSquareType
        centerSquareCustomName = t.centerSquareCustomName ?? ""
        poolStrategy = t.poolStrategy
        isRandomized = t.isRandomized
        isActive = t.isActive
        seedTaskIds = t.seedTaskIds
    }

    // MARK: - Submit

    private func submit() {
        guard formValid else { return }
        submitting = true
        submitError = nil
        let now = AppDatabase.currentTimestamp()
        let trimmedName = self.trimmedName
        let customName: String? = centerSquareType == .customFree
            ? centerSquareCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        _Concurrency.Task.detached {
            do {
                let template: RecurringBoardTemplate
                if let prev = existing {
                    template = RecurringBoardTemplate(
                        id: prev.id,
                        userId: prev.userId,
                        name: trimmedName,
                        timeframe: timeframe,
                        boardSize: boardSize,
                        centerSquareType: centerSquareType,
                        centerSquareCustomName: customName,
                        isRandomized: isRandomized,
                        seedTaskIds: seedTaskIds,
                        poolStrategy: poolStrategy,
                        lastSpawnedWindowKey: prev.lastSpawnedWindowKey,
                        isActive: isActive,
                        createdAt: prev.createdAt,
                        updatedAt: now,
                        lastSyncedAt: prev.lastSyncedAt,
                        version: prev.version + 1,
                        isDeleted: false,
                        deletedAt: nil
                    )
                } else {
                    template = RecurringBoardTemplate(
                        id: AppDatabase.generateUUID(),
                        userId: userId,
                        name: trimmedName,
                        timeframe: timeframe,
                        boardSize: boardSize,
                        centerSquareType: centerSquareType,
                        centerSquareCustomName: customName,
                        isRandomized: isRandomized,
                        seedTaskIds: seedTaskIds,
                        poolStrategy: poolStrategy,
                        lastSpawnedWindowKey: nil,
                        isActive: isActive,
                        createdAt: now,
                        updatedAt: now,
                        lastSyncedAt: nil,
                        version: 1,
                        isDeleted: false,
                        deletedAt: nil
                    )
                }

                try AppDatabase.shared.saveRecurringBoardTemplate(template)

                let op: SyncOperationType = (existing == nil) ? .create : .update
                try AppDatabase.shared.write { db in
                    try SyncQueueBuilder.makeItem(
                        entityType: "recurringBoardTemplates",
                        entityId: template.id,
                        operationType: op,
                        payload: template,
                        now: now
                    ).insert(db)
                }

                await MainActor.run {
                    submitting = false
                    onClose()
                }
            } catch {
                await MainActor.run {
                    submitting = false
                    submitError = "Failed to save template: \(error.localizedDescription)"
                }
            }
        }
    }
}
