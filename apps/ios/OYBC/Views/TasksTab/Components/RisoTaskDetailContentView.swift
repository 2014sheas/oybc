import GRDB
import SwiftUI

/// Riso-styled task detail content.
///
/// Renders the same sections as `TaskDetailContentView` but using Riso kit
/// components: big letter badge, Bricolage title, type tag pill, Riso card
/// sections, and Edit + Delete buttons using `RisoButton`. All logic callbacks
/// are identical — this is a pure presentation reskin.
///
/// Used by `RisoTaskDetailSheetWrapper` (a thin NavigationStack wrapper that
/// adds a Done button and drives the delete-confirm alert).
struct RisoTaskDetailContentView: View {

    // MARK: - Props

    let task: Task
    let placements: [BoardTask]
    let affectedBoards: [Board]
    let parentCompounds: [Task]
    let compoundChildren: [Task]
    let templates: [RecurringBoardTemplate]
    var saveError: String? = nil
    var allBoardsForPicker: [Board] = []
    var allTemplatesForPicker: [RecurringBoardTemplate] = []
    let onEditSubmit: (EditTaskSheet.Patch) -> Void
    let onDeleteTap: () -> Void
    let onOpenTask: (String) -> Void
    let onOpenBoard: (String) -> Void

    // MARK: - Local state

    @State private var showEditSheet: Bool = false

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerSection
                if let sub = typeSubtitle {
                    detailRow(label: "Details", value: sub)
                }
                // Shared-counter link caption (Phase 2) — restored so linked
                // counting tasks surface their source here, like the original detail.
                if task.type == .counting, let sharedCounterId = task.sharedCounterId {
                    LinkedCounterCaptionView(sharedCounterId: sharedCounterId)
                }
                usageRow
                if task.type == .compound && !compoundChildren.isEmpty {
                    subtasksSection
                }
                if !parentCompounds.isEmpty {
                    subtaskOfSection
                }
                if !templates.isEmpty {
                    partOfSection
                }
                activitySection
                if let saveError {
                    Text(saveError)
                        .font(.risoBody(13, .regular))
                        .foregroundStyle(Color.risoRed)
                }
                actionButtons
            }
            .padding(Riso.gutter)
        }
        .background(RisoPaperBackground())
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

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            // Large letter badge
            RisoTypeBadge(kind: risoKind, style: .letterSquare)
                .scaleEffect(2.0)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title.isEmpty ? "(untitled task)" : task.title)
                    .risoH2()
                    .lineLimit(3)
                // Type tag pill
                RisoTypeBadge(kind: risoKind, style: .pill)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard()
    }

    // MARK: - Detail row

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .risoSectionLabel()
            Text(value)
                .font(.risoBody(14, .regular))
                .foregroundStyle(Color.risoInk)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: Riso.Keyline.dense)
    }

    // MARK: - Usage

    private var usageRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("USAGE")
                .risoSectionLabel()
            HStack(spacing: 4) {
                Text("On \(affectedBoards.count) board\(affectedBoards.count == 1 ? "" : "s")")
                    .font(.risoBody(14, .semibold))
                    .foregroundStyle(Color.risoInk)
                Text("·")
                    .foregroundStyle(Color.risoMuted)
                Text("\(activePlacementCount) active")
                    .font(.risoBody(14, .semibold))
                    .foregroundStyle(Color.risoGreen)
                Text("·")
                    .foregroundStyle(Color.risoMuted)
                Text("used \(task.totalCompletions)× all-time")
                    .font(.risoBody(14, .regular))
                    .foregroundStyle(Color.risoMuted)
            }
            if !affectedBoards.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(affectedBoards, id: \.id) { board in
                        Button {
                            onOpenBoard(board.id)
                        } label: {
                            HStack(spacing: 6) {
                                Text(board.name)
                                    .font(.risoBody(13, .semibold))
                                    .foregroundStyle(Color.risoBlue)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(board.status.rawValue.uppercased())
                                    .risoSectionLabel(Color.risoMuted)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: Riso.Keyline.dense)
    }

    // MARK: - Subtasks

    @ViewBuilder
    private var subtasksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUBTASKS (\(compoundChildren.count))")
                .risoSectionLabel()
            VStack(spacing: 5) {
                ForEach(compoundChildren, id: \.id) { child in
                    Button {
                        onOpenTask(child.id)
                    } label: {
                        HStack(spacing: 8) {
                            RisoTypeBadge(kind: risoKindFor(child), style: .letterSquare)
                            Text(child.title.isEmpty ? "(untitled)" : child.title)
                                .font(.risoBody(13, .medium))
                                .foregroundStyle(Color.risoInk)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if child.isCompleted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.risoGreen)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.risoMuted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .risoCard(keyline: Riso.Keyline.dense)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: Riso.Keyline.dense)
    }

    // MARK: - Subtask of

    @ViewBuilder
    private var subtaskOfSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUBTASK OF")
                .risoSectionLabel()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(parentCompounds, id: \.id) { parent in
                        Button {
                            onOpenTask(parent.id)
                        } label: {
                            HStack(spacing: 5) {
                                RisoTypeBadge(kind: .compound, style: .letterSquare)
                                Text(parent.title.isEmpty ? "(untitled)" : parent.title)
                                    .font(.risoBody(12, .semibold))
                                    .foregroundStyle(Color.risoInk)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .risoCard(keyline: Riso.Keyline.dense)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: Riso.Keyline.dense)
    }

    // MARK: - Part of

    @ViewBuilder
    private var partOfSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PART OF")
                .risoSectionLabel()
            VStack(spacing: 4) {
                ForEach(templates, id: \.id) { template in
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.risoMuted)
                        Text(template.name)
                            .font(.risoBody(13, .medium))
                            .foregroundStyle(Color.risoInk)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .risoCard(keyline: Riso.Keyline.dense)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: Riso.Keyline.dense)
    }

    // MARK: - Activity

    @ViewBuilder
    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ACTIVITY")
                .risoSectionLabel()
            if let completedAt = task.completedAt,
               let rel = RelativeTime.formatRelativeTime(completedAt) {
                Text("Last completed: \(rel)")
                    .font(.risoBody(13, .medium))
                    .foregroundStyle(Color.risoInk)
            }
            Text("Created: \(formatDate(task.createdAt))")
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted)
            if let rel = RelativeTime.formatRelativeTime(task.updatedAt) {
                Text("Updated: \(rel)")
                    .font(.risoBody(12, .regular))
                    .foregroundStyle(Color.risoMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: Riso.Keyline.dense)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 10) {
            RisoButton(title: "Edit", kind: .neutral, fullWidth: true) {
                showEditSheet = true
            }
            RisoButton(title: "Delete", kind: .primary, fullWidth: true) {
                onDeleteTap()
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private var risoKind: RisoTaskKind {
        risoKindFor(task)
    }

    private func risoKindFor(_ t: Task) -> RisoTaskKind {
        switch t.type {
        case .normal: return .normal
        case .counting: return .counting
        case .compound: return .compound
        case .achievement: return .achievement
        }
    }

    private var typeSubtitle: String? {
        switch task.type {
        case .counting:
            guard let action = task.action, let unit = task.unit, let max = task.maxCount else { return nil }
            let current = task.currentCount ?? 0
            return "\(action) · \(current) / \(max) \(unit)"
        case .compound:
            let n = compoundChildren.count
            guard n > 0 else { return nil }
            let ruleLabel: String
            if let op = task.operatorType {
                switch op {
                case .or: ruleLabel = "any of \(n)"
                case .and: ruleLabel = task.isOrdered == true ? "in order" : "all of \(n)"
                case .mOfN:
                    let threshold = task.threshold ?? n
                    ruleLabel = "≥\(threshold) of \(n)"
                }
            } else {
                ruleLabel = "all of \(n)"
            }
            return "\(n) sub-task\(n == 1 ? "" : "s") · \(ruleLabel)"
        case .achievement:
            let trigger = task.achievementTrigger ?? .greenlog
            let trig = trigger == .bingo ? "First Bingo" : "GREENLOG"
            if let boardId = task.referencedBoardId {
                // Resolve the human-readable board name (UUID is not user-facing).
                let name = affectedBoards.first { $0.id == boardId }?.name ?? "a board"
                return "Watch \(name) · \(trig)"
            }
            if let tplId = task.referencedTemplateId {
                let name = templates.first { $0.id == tplId }?.name ?? "a template"
                let req = task.requiredCount.map { " · \($0)×" } ?? ""
                return "Watch \(name)\(req) · \(trig)"
            }
            return trig
        case .normal:
            return nil
        }
    }

    /// Count of placements on *active* boards (not all placements). Mirrors
    /// the list row's `activePlacementCounts`, so "N active" agrees across views.
    private var activePlacementCount: Int {
        affectedBoards.filter { $0.status == .active }.count
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        if let date = f.date(from: iso) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .none
            return display.string(from: date)
        }
        return iso
    }
}
