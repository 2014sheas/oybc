import GRDB
import SwiftUI

/// `TaskIdItem` — lightweight `Identifiable` + `Hashable` wrapper for a task
/// ID string. Used wherever `.sheet(item:)` or `navigationDestination(item:)`
/// needs an `Identifiable` trigger but the caller only has a plain `String`.
struct TaskIdItem: Identifiable, Hashable {
    let id: String
}

// MARK: - LinkedCounterCaptionView (Phase 2 — Shared Counters)

/// Small "Linked to <source title>" caption rendered below the counting
/// progress in the detail sheet. Detail-sheet only — no list/cell badge
/// (Decision 3 from Phase 0 design). Performs a one-shot GRDB fetch on
/// appear so the parent `TaskDetailContentView` stays a pure prop view.
struct LinkedCounterCaptionView: View {

    let sharedCounterId: String

    @State private var sourceTitle: String? = nil
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                EmptyView()
            } else if let sourceTitle {
                HStack(spacing: 4) {
                    Text("Linked to")
                        .foregroundStyle(.secondary)
                    Text(sourceTitle)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
                .font(.system(size: 12))
            } else {
                Text("Linked to source task (deleted or not found)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .onAppear { fetchSource() }
    }

    private func fetchSource() {
        _Concurrency.Task {
            do {
                let task = try await AppDatabase.shared.read { db in
                    try OYBC.Task.fetchOne(db, key: sharedCounterId)
                }
                await MainActor.run {
                    sourceTitle = task?.isDeleted == false ? task?.title : nil
                    loading = false
                }
            } catch {
                await MainActor.run { loading = false }
            }
        }
    }
}

/// Task detail content view — renders all sections for a given task.
/// Used by both the route-pushed `TaskDetailView` and the sheet-over-board
/// `TaskDetailSheetView`. Owns no async state; callers feed it props and
/// receive callbacks for edit/delete/navigation actions.
///
/// iOS twin of web's `TaskDetailContent.tsx`.
struct TaskDetailContentView: View {

    // MARK: - Props

    let task: Task
    let placements: [BoardTask]
    let affectedBoards: [Board]
    /// Compound tasks that reference this task as a child (via compound_children).
    let parentCompounds: [Task]
    /// Child tasks of this task when it is a compound (empty for non-compound).
    let compoundChildren: [Task]
    /// Recurring templates whose seedTaskIds include this task's ID.
    let templates: [RecurringBoardTemplate]
    var saveError: String? = nil
    /// Workspace-wide boards for the Achievement re-target picker. Only
    /// displayed when `task.type == .achievement`.
    var allBoardsForPicker: [Board] = []
    /// Workspace-wide templates for the Achievement re-target picker.
    var allTemplatesForPicker: [RecurringBoardTemplate] = []
    let onEditSubmit: (EditTaskSheet.Patch) -> Void
    let onDeleteTap: () -> Void
    /// Called when the user taps a parent compound chip or child task row
    /// to navigate to that task's detail.
    let onOpenTask: (String) -> Void
    /// Called when the user taps a board name in the Usage section. The
    /// caller decides where to land — typically: switch to the Boards
    /// tab and push BoardPlayView for that board id, dismissing any
    /// open sheet first. Without this, board names would be no-ops in
    /// sheet mode and broken in route mode (they previously matched
    /// the Tasks-tab `navigationDestination(for: String.self)`, which
    /// pushes a TaskDetailView with the board's id — finds no task,
    /// renders Loading… forever).
    let onOpenBoard: (String) -> Void

    // MARK: - Local state

    @State private var showEditSheet: Bool = false

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleSection
                typeSpecificSection
                subtaskOfSection
                subtasksSection
                partOfSection
                usageSection
                activitySection
                if let saveError {
                    Text(saveError)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
                actions
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showEditSheet) {
            EditTaskSheet(
                task: task,
                availableBoards: allBoardsForPicker,
                availableTemplates: allTemplatesForPicker,
                onSubmit: { patch in
                    showEditSheet = false
                    onEditSubmit(patch)
                },
                onCancel: {
                    showEditSheet = false
                }
            )
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title.isEmpty ? "(untitled task)" : task.title)
                .font(.largeTitle)
                .fontWeight(.bold)
            HStack(spacing: 8) {
                TypeBadgeView(type: typeLabel(task))
                statusPill(task)
            }
            if let desc = task.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var typeSpecificSection: some View {
        switch task.type {
        case .counting:
            section(title: "COUNTING") {
                if let action = task.action, let unit = task.unit, let max = task.maxCount {
                    let current = task.currentCount ?? 0
                    Text("\(action) · \(current) / \(max) \(unit)")
                        .font(.system(size: 14))
                    if max > 0 {
                        ProgressView(value: Double(min(current, max)), total: Double(max))
                    }
                } else {
                    Text("Incomplete counting fields.")
                        .foregroundColor(.secondary)
                }
                // Phase 2 — Shared Counters: "Linked to" caption.
                // Detail-sheet only — no list/cell badge (Decision 3).
                if let sharedCounterId = task.sharedCounterId {
                    LinkedCounterCaptionView(sharedCounterId: sharedCounterId)
                }
            }
        case .achievement:
            section(title: "ACHIEVEMENT") {
                let trigger = task.achievementTrigger ?? .greenlog
                Text("Trigger: \(trigger == .bingo ? "Bingo" : "Greenlog")")
                    .font(.system(size: 14))
                if let boardId = task.referencedBoardId {
                    Text("Watches board: \(boardId)")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                if let tplId = task.referencedTemplateId {
                    Text("Watches template: \(tplId)")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    if let req = task.requiredCount {
                        Text("Required spawns: \(req)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }
        case .compound, .normal:
            EmptyView()
        }
    }

    /// "SUBTASK OF" — chips for each parent compound that references this task.
    /// Hidden when this task is not a subtask of any compound.
    @ViewBuilder
    private var subtaskOfSection: some View {
        if !parentCompounds.isEmpty {
            section(title: "SUBTASK OF") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(parentCompounds, id: \.id) { parent in
                            Button {
                                onOpenTask(parent.id)
                            } label: {
                                HStack(spacing: 5) {
                                    TypeBadgeView(type: typeLabel(parent), size: .small)
                                    Text(parent.title.isEmpty ? "(untitled)" : parent.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray5))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// "SUBTASKS (N)" — read-only child task list. Shown only for compound tasks.
    @ViewBuilder
    private var subtasksSection: some View {
        if task.type == .compound {
            section(title: "SUBTASKS (\(compoundChildren.count))") {
                if compoundChildren.isEmpty {
                    Text("No subtasks yet.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(compoundChildren, id: \.id) { child in
                            Button {
                                onOpenTask(child.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: child.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 15))
                                        .foregroundColor(child.isCompleted ? .green : .secondary)
                                    TypeBadgeView(type: typeLabel(child), size: .small, letterOnly: true)
                                    Text(child.title.isEmpty ? "(untitled)" : child.title)
                                        .font(.system(size: 14))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("Compound subtasks are edited from the board-creation wizard.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// "PART OF" — recurring template back-references. Hidden when empty.
    @ViewBuilder
    private var partOfSection: some View {
        if !templates.isEmpty {
            section(title: "PART OF") {
                VStack(spacing: 6) {
                    ForEach(templates, id: \.id) { template in
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            Text("Part of: \(template.name)")
                                .font(.system(size: 13))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var usageSection: some View {
        section(title: "USAGE") {
            Text("Total completions: \(task.totalCompletions)")
                .font(.system(size: 14))
            if affectedBoards.isEmpty {
                Text("Not placed on any board yet.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            } else {
                ForEach(affectedBoards, id: \.id) { board in
                    Button {
                        onOpenBoard(board.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text(board.name)
                                .foregroundColor(.blue)
                            Text(board.status.rawValue.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Restyled timestamp section: leads with relative "last completed" when set,
    /// then absolute created/updated dates.
    @ViewBuilder
    private var activitySection: some View {
        section(title: "ACTIVITY") {
            if let completedAt = task.completedAt,
               let rel = RelativeTime.formatRelativeTime(completedAt) {
                Text("Last completed: \(rel)")
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
            }
            Text("Created: \(formatDate(task.createdAt))")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            if let rel = RelativeTime.formatRelativeTime(task.updatedAt) {
                Text("Updated: \(rel)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            } else {
                Text("Updated: \(formatDate(task.updatedAt))")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                showEditSheet = true
            } label: {
                Text("Edit")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Button {
                onDeleteTap()
            } label: {
                Text("Delete")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func typeLabel(_ t: Task) -> String {
        if t.type == .compound {
            return t.isOrdered == true ? "progress" : "composite"
        }
        return t.type.rawValue
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func statusPill(_ t: Task) -> some View {
        if t.isCompleted {
            pillView(text: "Completed", color: .green)
        } else if t.type == .counting, (t.currentCount ?? 0) > 0 {
            pillView(text: "In progress", color: .orange)
        } else {
            pillView(text: "Never started", color: .gray)
        }
    }

    @ViewBuilder
    private func pillView(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(Capsule())
    }

    private func formatDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: iso) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        return iso
    }
}
