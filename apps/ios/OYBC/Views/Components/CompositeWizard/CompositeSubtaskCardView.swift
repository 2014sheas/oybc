import SwiftUI

/// CompositeSubtaskCardView — Renders a single subtask of a composite.
/// iOS twin of web's `SubtaskCard`. Existing-mode selections render as a
/// flat borderless row (no frame, no readiness footer — ready by
/// construction). Inline-created subtasks keep their full card frame and
/// the live readiness check that drives the green/red border.
struct CompositeSubtaskCardView: View {

    @ObservedObject var item: SubtaskItem

    /// Library feeds — needed so an existing-mode row can look up the
    /// title + metadata of its selection.
    let libraryTasks: [OYBC.Task]
    /// Compound tasks (type=.compound && !isOrdered) available as nested children.
    let libraryCompositeTasks: [OYBC.Task]
    let taskBoardCounts: [String: Int]
    let taskStepCounts: [String: Int]
    let compositeSubtaskCounts: [String: Int]
    let compositeLeafPreviews: [String: CompositeLeafPreview]

    /// Optional. When provided, an info button appears on the existing-mode
    /// row so the user can open the task's detail sheet without leaving the wizard.
    var onView: (() -> Void)? = nil

    /// Called when the user taps remove.
    let onRemove: () -> Void

    // MARK: - Body

    var body: some View {
        if item.mode == .existing {
            existingFlatRow
        } else {
            inlineCard
        }
    }

    // MARK: - Existing-mode flat row

    @ViewBuilder
    private var existingFlatRow: some View {
        let row = resolveExistingRow()
        HStack(spacing: 12) {
            if let row = row {
                TypeBadgeView(type: row.typeLabel, size: .small, letterOnly: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                // Usage hint on the selection row is intentionally
                // de-emphasised (tertiary weight) — it's less relevant
                // once the task is already in the composite, so it
                // shouldn't visually compete with the title.
                Text(row.usageHint)
                    .font(.footnote)
                    .foregroundColor(Color(.tertiaryLabel))
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                // Library target went missing (deleted elsewhere) —
                // surface a minimal remove-only row so the user can
                // clean up.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unknown task")
                        .font(.system(size: 16, weight: .semibold))
                    Text("The selected library item is no longer available. Remove this row.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            // Info button — only shown when the caller provides onView.
            if let onView {
                Button(action: onView) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View \(row?.title ?? "subtask") details")
            }

            // Bigger tap target for the remove control — the previous
            // 26pt hairline × was tap-hostile vs the 20pt checkboxes
            // in the library rows below. 44pt is the iOS HIG minimum.
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(Color(.tertiaryLabel))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Remove \(row?.title ?? "subtask")")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .overlay(
            Rectangle()
                .fill(Color(.systemGray5))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Inline-mode card (unchanged visual behavior)

    @ViewBuilder
    private var inlineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("NEW TASK (INLINE)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Remove", action: onRemove)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(.secondary)
            }

            if let pending = item.pendingTypeSwitch {
                switchConfirmPanel(target: pending)
            } else {
                inlineContent
            }

            readinessFooter
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(readiness.ready
                      ? Color.green.opacity(0.06)
                      : Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(readiness.ready
                        ? Color.green.opacity(0.55)
                        : Color(.systemGray4), lineWidth: 1.5)
        )
    }

    // MARK: - Inline content

    @ViewBuilder
    private var inlineContent: some View {
        Picker("Type", selection: typeBinding) {
            ForEach(InlineSubtaskType.allCases) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)

        TextField(
            item.inlineType == .counting
                ? "Title (auto-generated from action + count + unit if blank)"
                : "Title",
            text: $item.inlineTitle
        )
        .textFieldStyle(.roundedBorder)

        switch item.inlineType {
        case .normal:
            EmptyView()
        case .counting:
            CountingStepFieldsView(
                action: $item.inlineAction,
                maxCount: $item.inlineMaxCountStr,
                unit: $item.inlineUnit
            )
        case .progress:
            progressStepsContent
        }
    }

    private var typeBinding: Binding<InlineSubtaskType> {
        Binding(
            get: { item.inlineType },
            set: { next in
                if next == item.inlineType { return }
                if hasInlineDirtyFields {
                    item.pendingTypeSwitch = next
                } else {
                    applyTypeSwitch(to: next)
                }
            }
        )
    }

    @ViewBuilder
    private func switchConfirmPanel(target: InlineSubtaskType) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Switching to **\(target.rawValue)** will clear the fields you've filled for **\(item.inlineType.rawValue)**.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Keep \(item.inlineType.rawValue)") {
                    item.pendingTypeSwitch = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Switch to \(target.rawValue)") {
                    applyTypeSwitch(to: target)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    private func applyTypeSwitch(to target: InlineSubtaskType) {
        item.inlineType = target
        item.inlineTitle = ""
        item.inlineAction = ""
        item.inlineUnit = ""
        item.inlineMaxCountStr = ""
        item.inlineSteps = target == .progress ? [ProgressStepFormState()] : []
        item.pendingTypeSwitch = nil
    }

    @ViewBuilder
    private var progressStepsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Steps")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            ForEach(Array(item.inlineSteps.indices), id: \.self) { index in
                ProgressStepRowView(
                    index: index,
                    step: Binding(
                        get: { item.inlineSteps[index] },
                        set: { item.inlineSteps[index] = $0 }
                    ),
                    stepCount: item.inlineSteps.count,
                    onRemove: { item.inlineSteps.remove(at: index) }
                )
            }
            Button("+ Add Step") {
                item.inlineSteps.append(ProgressStepFormState())
            }
            .font(.caption)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
        )
    }

    // MARK: - Readiness

    private struct Readiness {
        let ready: Bool
        let message: String?
    }

    private var readiness: Readiness {
        // Inline-only readiness — existing rows never render this path.
        switch item.inlineType {
        case .normal:
            if item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Readiness(ready: false, message: "Add a title for this task.")
            }
            return Readiness(ready: true, message: nil)
        case .counting:
            let a = item.inlineAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = item.inlineUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let max = Int(item.inlineMaxCountStr) ?? 0
            if a.isEmpty { return Readiness(ready: false, message: "Add an action (e.g. \"Run\").") }
            if u.isEmpty { return Readiness(ready: false, message: "Add a unit (e.g. \"miles\").") }
            if max < 1 { return Readiness(ready: false, message: "Add a max count of at least 1.") }
            return Readiness(ready: true, message: nil)
        case .progress:
            let t = item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return Readiness(ready: false, message: "Add a title for this progress task.") }
            if item.inlineSteps.isEmpty {
                return Readiness(ready: false, message: "Add at least one step.")
            }
            for step in item.inlineSteps {
                switch step.type {
                case .normal:
                    if step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return Readiness(ready: false, message: "Each normal step needs a title.")
                    }
                case .counting:
                    if step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return Readiness(ready: false, message: "Each counting step needs an action.")
                    }
                    if step.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return Readiness(ready: false, message: "Each counting step needs a unit.")
                    }
                    if (Int(step.maxCount) ?? 0) < 1 {
                        return Readiness(ready: false, message: "Each counting step needs a max count of at least 1.")
                    }
                default:
                    break
                }
            }
            return Readiness(ready: true, message: nil)
        }
    }

    private var hasInlineDirtyFields: Bool {
        let t = item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        switch item.inlineType {
        case .normal:
            return !t.isEmpty
        case .counting:
            return !t.isEmpty
                || !item.inlineAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !item.inlineUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !item.inlineMaxCountStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .progress:
            if !t.isEmpty { return true }
            for step in item.inlineSteps {
                if !step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                if !step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                if !step.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                if !step.maxCount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            }
            return false
        }
    }

    @ViewBuilder
    private var readinessFooter: some View {
        HStack(spacing: 6) {
            Text(readiness.ready ? "✓" : "•")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(readiness.ready ? .green : .secondary)
            Text(readiness.ready ? "Ready" : (readiness.message ?? ""))
                .font(.caption)
                .foregroundColor(readiness.ready ? .green : .secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(readiness.ready
                      ? Color.green.opacity(0.1)
                      : Color(.systemGray6))
        )
    }

    // MARK: - Existing row resolution

    private struct ExistingRow {
        let title: String
        let typeLabel: String
        let subtitle: String
        let usageHint: String
    }

    private func resolveExistingRow() -> ExistingRow? {
        if item.selectionType == .task {
            guard let task = libraryTasks.first(where: { $0.id == item.selectedTaskId }) else {
                return nil
            }
            let boards = taskBoardCounts[task.id] ?? 0
            // Short form — matches the library-row copy on the same
            // screen. Long versions were pushing titles to truncate on
            // iPhone.
            let usage = boards == 0
                ? "unused"
                : "\(boards) board\(boards == 1 ? "" : "s")"
            return ExistingRow(
                title: task.title,
                typeLabel: task.type.rawValue,
                subtitle: Self.buildTaskSubtitle(for: task, stepCounts: taskStepCounts),
                usageHint: usage
            )
        } else {
            guard let ct = libraryCompositeTasks.first(where: { $0.id == item.selectedCompositeId }) else {
                return nil
            }
            let leaves = compositeSubtaskCounts[ct.id] ?? 0
            return ExistingRow(
                title: ct.title,
                typeLabel: "composite",
                subtitle: Self.buildCompositeSubtitle(for: ct.id, previews: compositeLeafPreviews),
                usageHint: "\(leaves) subtask\(leaves == 1 ? "" : "s")"
            )
        }
    }

    // MARK: - Subtitle helpers (mirror web)

    private static func buildTaskSubtitle(
        for task: OYBC.Task,
        stepCounts: [String: Int]
    ) -> String {
        switch task.type {
        case .counting:
            guard let action = task.action,
                  let unit = task.unit,
                  let max = task.maxCount,
                  !action.isEmpty,
                  !unit.isEmpty else {
                return ""
            }
            let derived = "\(action) \(max) \(unit)"
            if derived.lowercased() == task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                return ""
            }
            return derived
        case .compound where task.isOrdered == true:
            // Former Progress = compound + isOrdered=true under the unified model.
            let n = stepCounts[task.id] ?? 0
            if n == 0 { return "" }
            return "\(n) step\(n == 1 ? "" : "s")"
        default:
            return ""
        }
    }

    private static func buildCompositeSubtitle(
        for compositeId: String,
        previews: [String: CompositeLeafPreview]
    ) -> String {
        guard let preview = previews[compositeId], !preview.titles.isEmpty else {
            return ""
        }
        let visible = preview.titles.joined(separator: ", ")
        let hidden = preview.totalLeaves - preview.titles.count
        return hidden > 0 ? "\(visible), +\(hidden) more" : visible
    }
}
