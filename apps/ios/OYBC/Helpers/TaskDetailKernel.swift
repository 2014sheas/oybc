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

    /// The first open child that can be toggled (Normal or a nested Compound);
    /// when only counting children remain open, a log on the first of them.
    /// Achievements are never actionable here.
    ///
    /// - Parameter children: The compound's children in display order.
    /// - Returns: The action, or `nil` when nothing is open.
    static func nextSubtask(_ children: [SubtaskCandidate]) -> SubtaskAction? {
        let open = children.filter { !$0.isCompleted }
        if let t = open.first(where: { $0.type == .normal || $0.type == .compound }) { return .toggle(childId: t.id) }
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
    /// removed → placed → created, then by key.
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
        func onBoard(_ id: String?) -> String {
            guard let id, let name = boardNames[id] else { return "" }
            return " · \(name)"
        }
        func amount(_ v: CountValue) -> String {
            let u = (kind == .duration || (unit ?? "").isEmpty) ? "" : " \(unit!)"
            return formatCount(v, kind: kind) + u
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
        let instants = Dictionary(rows.map { ($0.key, parseISO8601Date($0.at)) }, uniquingKeysWith: { a, _ in a })
        rows.sort { a, b in
            if let ta = instants[a.key] ?? nil, let tb = instants[b.key] ?? nil, ta != tb { return ta > tb }
            if a.kind.tieOrder != b.kind.tieOrder { return a.kind.tieOrder < b.kind.tieOrder }
            return a.key < b.key
        }
        return Activity(rows: rows, completionCount: completions)
    }
}
