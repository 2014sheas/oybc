import SwiftUI

/// Counter Detail "Unit tasks" section (docs/SHARED_COUNTER_SETTINGS.md §3d):
/// the tasks whose completion credits this counter — one row per fork
/// lineage, In progress -> Not started -> Done — with a trailing "+ New" and a
/// trailing swipe "Remove".
///
/// Pure props (no environment, no DB) so it snapshots directly. The container
/// (`CounterDetailView`) supplies `CountsTowardSectionData` and the taps; the
/// strings live in `CountsTowardLabels`.
/// Web twin: `components/counters/CountsTowardSection.tsx`.
struct CountsTowardSectionView: View {
    let data: CountsTowardSectionData
    /// "+ New" — opens the create sheet preset to this counter.
    var onNew: () -> Void = {}
    /// Row tap — opens that task's detail.
    var onOpenTask: (String) -> Void = { _ in }
    /// Remove (after the credits confirm when the lineage has any) — clears the task's counter.
    var onRemove: (String) -> Void = { _ in }
    /// The row that just arrived from "+ New": a gold ring, until the next interaction.
    var highlightedTaskId: String? = nil
    /// Fired on any interaction so the container can clear `highlightedTaskId`.
    var onInteract: () -> Void = {}

    @State private var pendingRemoval: CountsToward.ContributorRow?
    @State private var openSwipeId: String?

    // MARK: - Pure copy

    /// "× 3" — only for a repeating contributor (≥ 2 live credits).
    static func creditMark(_ creditCount: Int) -> String? {
        creditCount >= 2 ? "\u{00D7} \(creditCount)" : nil
    }

    /// The board line's progress text: "120 / 300 pages" only while in progress; a compound
    /// reads "No subtasks yet" with no children, "1 of 2" while in progress.
    static func detailText(row: CountsToward.ContributorRow, unit: String?) -> String? {
        if let c = row.childProgress, c.total == 0 { return CountsTowardLabels.childProgress(c) }
        guard row.status == .inProgress else { return nil }
        return row.progress.map { CountsTowardLabels.progress($0, unit: unit) }
            ?? row.childProgress.map(CountsTowardLabels.childProgress)
    }

    /// "{title}, {Done|In progress|Not started}[, {board}][, {progress}][, counted {n} times]"
    static func accessibilityLabel(title: String, row: CountsToward.ContributorRow, boardName: String?, unit: String? = nil) -> String {
        var parts = [title, RisoStatusPill.Status(row.status).label]
        if let boardName { parts.append(boardName) }
        if let d = detailText(row: row, unit: unit) { parts.append(d) }
        if row.creditCount >= 2 { parts.append("counted \(row.creditCount) times") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(CountsTowardLabels.heading(count: data.rows.count))
                    .risoSectionLabel()
                Spacer(minLength: 8)
                newButton
            }
            .padding(.bottom, 8)

            if data.rows.isEmpty {
                emptyBox
            } else {
                VStack(spacing: 5) {
                    ForEach(data.rows, id: \.taskId) { row in
                        SwipeToRemoveRow(
                            isOpen: Binding(
                                get: { openSwipeId == row.taskId },
                                set: { openSwipeId = $0 ? row.taskId : nil }
                            ),
                            onRemove: { requestRemoval(row) }
                        ) { rowCard(row) }
                    }
                }
            }
        }
        .padding(.horizontal, Riso.gutter)
        .alert(
            pendingRemoval.map { _ in CountsTowardLabels.removeTitle(counter: data.counterName) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { row in
            Button("Cancel", role: .cancel) {}
            Button("Remove") { onRemove(row.taskId) }
        } message: { row in
            Text(CountsTowardLabels.removeBody(
                title: data.taskById[row.taskId]?.title ?? "", credits: row.creditCount, counter: data.counterName
            ))
        }
    }

    /// Credits >= 1 -> the confirm alert; none -> removes immediately.
    private func requestRemoval(_ row: CountsToward.ContributorRow) {
        onInteract()
        openSwipeId = nil
        if CountsTowardLabels.removeNeedsConfirm(creditCount: row.creditCount) {
            pendingRemoval = row
        } else {
            onRemove(row.taskId)
        }
    }

    private var newButton: some View {
        Button {
            onInteract()
            onNew()
        } label: {
            Text("+ New")
                .font(.risoHead(13, .bold))
                .foregroundStyle(Color.risoInk)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .risoCard(fill: .risoPaper2)
        }
        .buttonStyle(.plain)
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .accessibilityLabel("New unit task for \(data.counterName)")
    }

    private var emptyBox: some View {
        Text(CountsTowardLabels.empty)
            .font(.risoBody(13, .semibold))
            .foregroundStyle(Color.risoMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 16)
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [5, 4]))
            )
    }

    private func rowCard(_ row: CountsToward.ContributorRow) -> some View {
        let task = data.taskById[row.taskId]
        let title = task?.title ?? ""
        let board = row.boardId.flatMap { data.boardById[$0] }
        let done = row.status == .done
        return Button {
            onInteract()
            onOpenTask(row.taskId)
        } label: {
            HStack(spacing: 8) {
                RisoTypeBadge(kind: RisoTaskKind(taskType: task?.type ?? .normal), style: .letterSquare)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.risoBody(13, .semibold))
                        .foregroundStyle(done ? Color.risoMuted : Color.risoInk)
                        .strikethrough(done)
                        .lineLimit(1)
                    boardLine(row: row, board: board, unit: task?.unit)
                }
                Spacer(minLength: 4)
                RisoStatusPill(status: .init(row.status))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .risoCard(radius: Riso.cardRadius, keyline: Riso.Keyline.dense, fill: .risoPaper2)
            .contentShape(Rectangle())
            .overlay {
                if highlightedTaskId == row.taskId {
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoGold, lineWidth: 3)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(title: title, row: row, boardName: board?.displayName, unit: task?.unit))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Remove") { requestRemoval(row) }
    }

    @ViewBuilder
    private func boardLine(row: CountsToward.ContributorRow, board: Board?, unit: String?) -> some View {
        let credit = Self.creditMark(row.creditCount)
        let detail = Self.detailText(row: row, unit: unit)
        if board != nil || credit != nil || detail != nil {
            HStack(spacing: 5) {
                if let board {
                    Circle()
                        .fill(board.timeframe.risoColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color.risoInkStatic, lineWidth: 1.5))
                    Text(board.displayName)
                        .font(.risoBody(10.5, .bold))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                }
                if let detail {
                    Text(detail)
                        .font(.risoBody(10.5, .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                }
                if let credit {
                    Text(credit)
                        .font(.risoHead(11, .extraBold))
                        .foregroundStyle(Color.risoMuted)
                }
            }
        }
    }
}

/// A row that reveals a plain red "Remove" button (trash glyph + label, 96pt)
/// when dragged left; a long drag commits it. Stands in for `swipeActions`,
/// which needs a `List` — this section lives inside Counter Detail's scroll.
/// The button is a plain red `Button`, never `role: .destructive`.
private struct SwipeToRemoveRow<Content: View>: View {
    @Binding var isOpen: Bool
    let onRemove: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var drag: CGFloat = 0
    private static var actionWidth: CGFloat { 96 }

    private var offset: CGFloat {
        let base: CGFloat = isOpen ? -Self.actionWidth : 0
        return min(0, base + drag)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if offset < 0 {
                Button(action: onRemove) {
                    VStack(spacing: 2) {
                        Image(systemName: "trash").font(.system(size: 15, weight: .bold))
                        Text("Remove").font(.risoHead(11, .bold))
                    }
                    .foregroundStyle(Color.risoPaper)
                    .frame(width: Self.actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoRed))
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                    )
                }
                .buttonStyle(.plain)
            }
            content()
                .contentShape(Rectangle())
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged { v in
                            guard abs(v.translation.width) > abs(v.translation.height) else { return }
                            drag = v.translation.width
                        }
                        .onEnded { v in
                            defer { drag = 0 }
                            guard abs(v.translation.width) > abs(v.translation.height) else { return }
                            let total = (isOpen ? -Self.actionWidth : 0) + v.translation.width
                            if total < -240 {
                                isOpen = false
                                onRemove()
                            } else {
                                withAnimation(.easeOut(duration: 0.18)) { isOpen = total < -Self.actionWidth / 2 }
                            }
                        }
                )
        }
    }
}
