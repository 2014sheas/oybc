import SwiftUI

/// Counter Detail "Counts toward" section (docs/SHARED_COUNTER_SETTINGS.md §3d,
/// PR 4): the tasks whose completion credits this counter — one row per fork
/// lineage, Done → In progress → Not started — with a trailing "+ New".
///
/// Pure props (no environment, no DB) so it snapshots directly. The container
/// (`CounterDetailView`) supplies `CountsTowardSectionData` and the two taps.
/// Web twin: `components/counters/CountsTowardSection.tsx`.
struct CountsTowardSectionView: View {
    let data: CountsTowardSectionData
    /// "+ New" — opens the create sheet preset to this counter.
    var onNew: () -> Void = {}
    /// Row tap — opens that task's detail.
    var onOpenTask: (String) -> Void = { _ in }

    // MARK: - Pure copy

    /// "Counts toward · N tasks" ("· 1 task"; bare when empty).
    static func heading(count: Int) -> String {
        switch count {
        case 0: return "Counts toward"
        case 1: return "Counts toward · 1 task"
        default: return "Counts toward · \(count) tasks"
        }
    }

    /// "Nothing counts toward {counter} yet."
    static func emptyText(counterName: String) -> String {
        "Nothing counts toward \(counterName) yet."
    }

    /// "× 3" — only for a repeating contributor (≥ 2 live credits).
    static func creditMark(_ creditCount: Int) -> String? {
        creditCount >= 2 ? "\u{00D7} \(creditCount)" : nil
    }

    /// "+2" — only when the amount is not the default 1.
    static func amountMark(_ amount: Int) -> String? {
        amount != 1 ? "+\(amount)" : nil
    }

    /// "{title}, {Done|In progress|Not started}[, {board}][, counted {n} times][, plus {amount}]"
    static func accessibilityLabel(title: String, row: CountsToward.ContributorRow, boardName: String?) -> String {
        var parts = [title, RisoStatusPill.Status(row.status).label]
        if let boardName { parts.append(boardName) }
        if row.creditCount >= 2 { parts.append("counted \(row.creditCount) times") }
        if row.amount != 1 { parts.append("plus \(row.amount)") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(Self.heading(count: data.rows.count))
                    .risoSectionLabel()
                Spacer(minLength: 8)
                newButton
            }
            .padding(.bottom, 8)

            if data.rows.isEmpty {
                emptyBox
            } else {
                VStack(spacing: 5) {
                    ForEach(data.rows, id: \.taskId) { row in rowCard(row) }
                }
            }
        }
        .padding(.horizontal, Riso.gutter)
    }

    private var newButton: some View {
        Button(action: onNew) {
            Text("+ New")
                .font(.risoHead(13, .bold))
                .foregroundStyle(Color.risoInk)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .risoCard(fill: .risoPaper2)
        }
        .buttonStyle(.plain)
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .accessibilityLabel("New task counting toward \(data.counterName)")
    }

    private var emptyBox: some View {
        Text(Self.emptyText(counterName: data.counterName))
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
        return Button { onOpenTask(row.taskId) } label: {
            HStack(spacing: 8) {
                RisoTypeBadge(kind: RisoTaskKind(taskType: task?.type ?? .normal), style: .letterSquare)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.risoBody(13, .semibold))
                        .foregroundStyle(done ? Color.risoMuted : Color.risoInk)
                        .strikethrough(done)
                        .lineLimit(1)
                    boardLine(row: row, board: board)
                }
                Spacer(minLength: 4)
                if let mark = Self.amountMark(row.amount) {
                    Text(mark)
                        .font(.risoHead(11, .extraBold))
                        .foregroundStyle(Color.risoMuted)
                }
                RisoStatusPill(status: .init(row.status))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .risoCard(radius: Riso.cardRadius, keyline: Riso.Keyline.dense, fill: .risoPaper2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(title: title, row: row, boardName: board?.displayName))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func boardLine(row: CountsToward.ContributorRow, board: Board?) -> some View {
        let credit = Self.creditMark(row.creditCount)
        if board != nil || credit != nil {
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
                if let credit {
                    Text(credit)
                        .font(.risoHead(11, .extraBold))
                        .foregroundStyle(Color.risoMuted)
                }
            }
        }
    }
}
