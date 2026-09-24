import SwiftUI

// MARK: - CounterDeleteConfirmView

/// Destructive confirm sheet for deleting a shared-counter source (P5
/// decision 8: `deleteCounterWithUnlink`). iOS twin of web's
/// `CounterDeleteConfirmDialog` — copy is VERBATIM per CLAUDE.md
/// cross-platform parity rule.
///
/// Structurally mirrors `TaskDeleteConfirmView` (NavigationStack +
/// `.presentationDetents([.medium])` + a gold-toolbar Cancel/red-toolbar
/// destructive-confirm pill) rather than the simpler `.alert` `TaskDetailView`
/// uses elsewhere — the member-unlink list needs a scrollable custom body,
/// which `.alert` can't host and `.confirmationDialog` / `swipeActions`
/// (crash trap — see repo memory) can't either.
///
/// Deleting a source UNLINKS its live members (each keeps its current count
/// as an independent standalone counter) rather than cascade-deleting them —
/// distinct from the ordinary task-delete cascade `TaskDeleteConfirmView` shows.
struct CounterDeleteConfirmView: View {
    let group: SharedCounterGroup
    let impact: AppDatabase.TaskDeletionImpact
    var isDeleting: Bool = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var hasMembers: Bool { impact.counterMemberCount > 0 }

    private func boardName(for memberId: String) -> String? {
        group.tasks.first(where: { $0.taskId == memberId })?.boardName
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    Text("'\(group.name)' and its lifetime total will be deleted.")
                        .font(.risoBody(14, .semibold))
                        .foregroundStyle(Color.risoInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(13)
                        .risoCard(fill: .risoPaper2)
                        .risoHardShadow(Riso.Shadow.small)

                    if hasMembers {
                        membersSection
                    }

                    // §Member rules (B3, RC12) — window-stamped derived
                    // counters made from this root go with it (the B2
                    // deletion cascade), which the member-unlink list above
                    // does NOT cover: those rows are removed, not unlinked.
                    // Rendered OUTSIDE (below) the members section, exactly
                    // as web's `CounterDeleteConfirmDialog` places it.
                    if let note = BoardSources.derivedCounterRemovalNote(
                        count: impact.derivedWindowCounterCount
                    ) {
                        RisoImpactNote(text: note)
                    }
                }
                .padding(Riso.gutter)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Delete counter?")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .disabled(isDeleting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    RisoToolbarPill(
                        title: hasMembers
                            ? "Delete counter & unlink \(impact.counterMemberCount) tasks"
                            : "Delete counter",
                        fill: .risoRed,
                        foreground: .risoPaper
                    ) {
                        onConfirm()
                    }
                    .disabled(isDeleting)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Members section

    @ViewBuilder
    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(impact.counterMemberCount) linked task\(impact.counterMemberCount == 1 ? "" : "s") will be unlinked and keep their current counts:")
                .risoSectionLabel()

            VStack(spacing: 7) {
                ForEach(impact.counterMembers, id: \.id) { member in
                    memberRow(member)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.small)
    }

    private func memberRow(_ member: Task) -> some View {
        HStack(spacing: 8) {
            Text(member.title)
                .font(.risoHead(13, .bold))
                .foregroundStyle(Color.risoInk)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let boardName = boardName(for: member.id) {
                Text(boardName)
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Riso.cellRadius)
                .fill(Color.risoPaper)
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cellRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                )
        )
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Delete counter — confirm sheet") {
    let src = SharedCounterMemberTask(
        taskId: "src",
        taskTitle: "Push-ups",
        isSource: true,
        boardId: "bm",
        boardName: "February Fitness",
        timeframe: .monthly,
        window: "February 2026",
        goal: 1000,
        logged: 512,
        met: false,
        over: 0,
        isActive: true
    )
    let group = SharedCounterGroup(
        counterId: "src",
        name: "Push-ups",
        action: "Do",
        unit: "reps",
        lifetime: 512,
        tasks: [src],
        taskCount: 1,
        boardCount: 1,
        activeTaskCount: 1
    )
    let now = "2026-02-01T00:00:00.000"
    let member = Task(
        id: "der1", userId: "u1", title: "Push-ups", type: .counting,
        action: "Do", unit: "reps",
        totalCompletions: 0, totalInstances: 0,
        currentCount: 45,
        createdAt: now, updatedAt: now,
        version: 1, isDeleted: false
    )
    let impact = AppDatabase.TaskDeletionImpact(
        boardTaskCount: 1,
        affectedBoardIds: ["bm"],
        affectedBoards: [],
        childLinkCount: 0,
        parentLinkCount: 0,
        counterMemberCount: 1,
        counterMembers: [member],
        // B3 RC12 — non-zero so the Xcode canvas exercises the
        // derived-counter line (the snapshot suite covers 0 and > 0 both).
        derivedWindowCounterCount: 2
    )
    CounterDeleteConfirmView(
        group: group,
        impact: impact,
        onConfirm: {},
        onCancel: {}
    )
}
#endif
