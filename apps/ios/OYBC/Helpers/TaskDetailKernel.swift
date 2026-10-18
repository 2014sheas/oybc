import Foundation

/// Task Detail + square interactions — the pure half (docs/TASK_DETAIL_REDESIGN.md):
/// the hero's anchor board, the compound "Complete next sub-task" pick and the
/// derived Activity feed. Swift twin of `packages/shared/src/algorithms/taskDetail.ts`,
/// pinned by `taskDetailVectors.json`.
enum TaskDetailKernel {

    // MARK: - Hero anchor

    /// The board the hero anchors its progress to: the soonest-ending
    /// still-in-play board the task is placed on — the Boards tab's order
    /// (`compareBoardsForList`), board id as the final tie-break.
    ///
    /// - Parameters:
    ///   - boards: The boards the task is placed on (any status).
    ///   - now: Reference time for the ended check.
    /// - Returns: The anchor board, or `nil` when none is in play.
    static func heroAnchorBoard(_ boards: [Board], now: Date = Date()) -> Board? {
        boards
            .filter { !$0.isDeleted && isBoardActiveForList($0, now: now) }
            .sorted { a, b in
                if compareBoardsForList(a, b, now: now) { return true }
                if compareBoardsForList(b, a, now: now) { return false }
                return a.id < b.id
            }
            .first
    }

    // MARK: - Next sub-task

    /// One compound child as the pick sees it, in display order.
    struct SubtaskCandidate: Equatable {
        let id: String
        let type: TaskType
        let isCompleted: Bool
    }

    /// What "Complete next sub-task" does.
    enum SubtaskAction: Equatable {
        case toggle(childId: String)
        case log(childId: String)
    }

    /// The first open child that can be toggled (Normal only); when only
    /// counting children remain open, a log on the first of them. A nested
    /// Compound owns no events (its completion derives from its own children)
    /// and an Achievement is a watcher, so neither is ever picked.
    ///
    /// - Parameter children: The compound's children in display order.
    /// - Returns: The action, or `nil` when nothing is open.
    static func nextSubtask(_ children: [SubtaskCandidate]) -> SubtaskAction? {
        let open = children.filter { !$0.isCompleted }
        if let t = open.first(where: { $0.type == .normal }) { return .toggle(childId: t.id) }
        if let c = open.first(where: { $0.type == .counting }) { return .log(childId: c.id) }
        return nil
    }

    // MARK: - Activity

    /// The Activity row's kind — it picks the dot colour.
    enum ActivityKind: String, Equatable {
        case logged, removed, completed, placed, missed, created

        fileprivate var tieOrder: Int {
            switch self {
            case .missed: return 0
            case .completed: return 1
            case .logged: return 2
            case .removed: return 3
            case .placed: return 4
            case .created: return 5
            }
        }
    }

    /// One Activity row, newest first.
    struct ActivityRow: Equatable {
        let key: String
        let kind: ActivityKind
        /// ISO8601 — what the row sorts and dates by.
        let at: String
        let text: String
    }

    /// An ended board whose window the task did not complete.
    struct MissedBoard: Equatable {
        let boardId: String
        let endDate: String
    }

    /// The feed plus the footer's all-time completion count.
    struct Activity: Equatable {
        let rows: [ActivityRow]
        let completionCount: Int
    }

    /// The Activity tab's feed (E5): logs, removals and completions from the
    /// task's live events, one "Placed on" row per live placement, one
    /// "Missed" row per ended board it did not complete, and "Created".
    /// Newest first; equal instants order missed → completed → logged →
    /// removed → placed → created, then by key (ASCII ids, so scalar order
    /// matches TS). An unparseable instant sorts as the oldest.
    ///
    /// - Parameters:
    ///   - taskId: The task's id.
    ///   - createdAt: The task's `createdAt`.
    ///   - unit: The task's unit (ignored for duration).
    ///   - kind: The family kind (`resolveFamilyCountKind`).
    ///   - events: The task's events (tombstones skipped).
    ///   - placements: The task's placements (tombstones skipped).
    ///   - missed: Ended boards it did not complete.
    ///   - boardNames: Board id → healed display name.
    /// - Returns: The rows and the all-time completion count.
    static func activity(
        taskId: String, createdAt: String, unit: String?, kind: CountKind,
        events: [TaskEvent], placements: [BoardTask], missed: [MissedBoard],
        boardNames: [String: String]
    ) -> Activity {
        /// The " · ‹board›" suffix, or "" when the board is unknown.
        func onBoard(_ id: String?) -> String {
            guard let id, let name = boardNames[id] else { return "" }
            return " · \(name)"
        }
        /// An amount with its unit; duration carries none.
        func amount(_ v: CountValue) -> String {
            if let unit, !unit.isEmpty, kind != .duration { return formatCount(v, kind: kind) + " \(unit)" }
            return formatCount(v, kind: kind)
        }
        var rows: [ActivityRow] = []
        var completions = 0
        for e in events where !e.isDeleted {
            switch e.kind {
            case .completion:
                completions += 1
                rows.append(ActivityRow(key: "e:\(e.id)", kind: .completed, at: e.occurredAt, text: "Completed" + onBoard(e.boardId)))
            case .increment:
                guard let d = e.delta, d != 0 else { continue }
                let text = d < 0 ? "Removed \(amount(-d))" : "Logged +\(amount(d))"
                rows.append(ActivityRow(key: "e:\(e.id)", kind: d < 0 ? .removed : .logged, at: e.occurredAt, text: text + onBoard(e.boardId)))
            }
        }
        for p in placements where !p.isDeleted {
            if let name = boardNames[p.boardId] {
                rows.append(ActivityRow(key: "p:\(p.id)", kind: .placed, at: p.createdAt, text: "Placed on \(name)"))
            }
        }
        for m in missed {
            if let name = boardNames[m.boardId] {
                rows.append(ActivityRow(key: "m:\(m.boardId)", kind: .missed, at: m.endDate, text: "Missed · \(name)"))
            }
        }
        rows.append(ActivityRow(key: "c:\(taskId)", kind: .created, at: createdAt, text: "Created"))
        let sorted = rows
            .map { (row: $0, t: parseISO8601Date($0.at)?.timeIntervalSince1970 ?? -.infinity) }
            .sorted { a, b in
                if a.t != b.t { return a.t > b.t }
                if a.row.kind.tieOrder != b.row.kind.tieOrder { return a.row.kind.tieOrder < b.row.kind.tieOrder }
                return a.row.key < b.row.key
            }
            .map(\.row)
        return Activity(rows: sorted, completionCount: completions)
    }

    // MARK: - Closest line

    /// The watched board's best unfinished line, for the achievement card.
    struct ClosestLine: Equatable {
        /// Row-major cell indices along the line, in reading order.
        let cells: [Int]
        /// How many of those cells are complete.
        let done: Int
    }

    /// The unfinished line (rows, columns, then the two diagonals —
    /// `detectBingos`' order) with the most completed cells; the earliest
    /// wins a tie.
    ///
    /// - Parameters:
    ///   - completionGrid: Row-major completion flags, length `gridSize²`.
    ///   - gridSize: The board's edge (3, 4 or 5).
    /// - Returns: The line, or `nil` when every line is complete or the grid
    ///   is malformed.
    static func closestLine(_ completionGrid: [Bool], gridSize: Int) -> ClosestLine? {
        guard gridSize >= 1, completionGrid.count == gridSize * gridSize else { return nil }
        let range = Array(0..<gridSize)
        var lines: [[Int]] = range.map { r in range.map { r * gridSize + $0 } }
        lines += range.map { c in range.map { $0 * gridSize + c } }
        lines.append(range.map { $0 * gridSize + $0 })
        lines.append(range.map { $0 * gridSize + (gridSize - 1 - $0) })
        var best: ClosestLine?
        for cells in lines {
            let done = cells.filter { completionGrid[$0] }.count
            if done == gridSize { continue }
            if best == nil || done > best!.done { best = ClosestLine(cells: cells, done: done) }
        }
        return best
    }
}
