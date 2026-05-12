import Foundation

/// Phase 6.3 — cycle detection for achievement-task cross-board references.
///
/// iOS twin of TypeScript `packages/shared/src/algorithms/cycleDetection.ts`.
/// When that changes, this must change in lockstep.
///
/// After the ACHIEVEMENT-as-TaskType refactor, achievement-task semantics
/// live on `Task` (`type == .achievement` carrying `referencedBoardId` XOR
/// `referencedTemplateId`). The same Task can be placed on multiple boards
/// via `BoardTask` rows; each placement contributes one cycle edge:
///
///     placingBoardId → referencedBoardId
///     placingBoardId → spawnId, for every in-template spawn
///
/// Without a check, a user could create a chain that loops back on itself —
/// Achievement Task watching B placed on A, plus an Achievement Task watching
/// A placed on B — leaving both boards stuck in a deadlock where neither can
/// ever satisfy the other (derivation reads stored states, so no infinite
/// loop, but the user-visible behavior is broken).
///
/// `hasCycle` runs at two points:
///   1. Creating/editing an ACHIEVEMENT Task. Pass `parentBoardIds` =
///      every board id currently placing that Task (empty on a brand-new
///      Task path; non-empty when editing references on a placed Task).
///   2. Placing an existing ACHIEVEMENT Task on a new board. Pass
///      `parentBoardIds` = [newBoardId] (or include existing placements
///      too; both are safe — the algorithm is idempotent).
///
/// Cycle detection is best-effort, NOT a strict invariant: two devices
/// concurrently writing achievement tasks can each individually pass their
/// own check and still form a cycle once both writes settle. Derivation
/// reads stored states (not recursive computations), so a post-sync cycle
/// just leaves the involved boards stuck rather than crashing.

/// Candidate placement under consideration.
struct CycleCheckCandidate {
    /// Every board id that places (or will place) the candidate ACHIEVEMENT
    /// Task. Each contributes one edge: `parentBoardId → target`. The
    /// cycle check passes only if NO parent is reachable from ANY target.
    let parentBoardIds: [String]
    /// Optional: the specific board id the candidate Task references.
    let referencedBoardId: String?
    /// Optional: the recurring-template id the candidate Task references.
    let referencedTemplateId: String?
}

/// Read context for the check.
struct CycleCheckContext {
    /// All non-deleted board_tasks in the workspace (placements that
    /// contribute edges when their Task is ACHIEVEMENT-typed).
    let allBoardTasks: [BoardTask]
    /// All non-deleted Tasks in the workspace. Edges are only contributed
    /// by BoardTasks whose Task is ACHIEVEMENT-typed; non-achievement
    /// placements contribute nothing.
    let allTasks: [Task]
    /// All non-deleted boards in the workspace (used to resolve template
    /// spawns AND to check parents' `spawnedFromTemplateId` for
    /// template-self-reference).
    let allBoards: [Board]
}

/// Outcome.
enum CycleCheckResult: Equatable {
    case ok
    case cycle(path: [String])
}

enum CycleDetection {
    /// Walks the reference graph from the candidate's targets looking for
    /// a path back to any of the candidate's parent boards. Self-reference
    /// of either kind is a degenerate one-step cycle and short-circuits.
    static func hasCycle(
        candidate: CycleCheckCandidate,
        context: CycleCheckContext
    ) -> CycleCheckResult {
        let parentBoardIds = candidate.parentBoardIds
        if parentBoardIds.isEmpty {
            // No placements means the candidate doesn't contribute any
            // edges yet (creating a brand-new achievement Task that hasn't
            // been placed). Trivially safe — actual cycle is detected at
            // placement time.
            return .ok
        }

        let parentSet = Set(parentBoardIds)

        // ── Self-reference: degenerate cycle ──
        if let refBoardId = candidate.referencedBoardId, parentSet.contains(refBoardId) {
            return .cycle(path: [refBoardId, refBoardId])
        }
        if let refTemplateId = candidate.referencedTemplateId {
            // Template-self-reference: any parent board is itself a spawn
            // of the template the candidate would watch. Degenerate.
            for parentId in parentBoardIds {
                if let parent = context.allBoards.first(where: { $0.id == parentId }),
                   parent.spawnedFromTemplateId == refTemplateId {
                    return .cycle(path: [parentId, parentId])
                }
            }
        }

        // ── Build adjacency from existing achievement-task placements ──
        var tasksById: [String: Task] = [:]
        for t in context.allTasks {
            if t.isDeleted { continue }
            tasksById[t.id] = t
        }
        var boardsById: [String: Board] = [:]
        for b in context.allBoards {
            if b.isDeleted { continue }
            boardsById[b.id] = b
        }

        // Index spawns once for template-fan-out edges. Holds full Board
        // objects (not just ids) so the window-filter below can read each
        // spawn's `startDate` without a second lookup. All values are
        // non-deleted (filtered through `boardsById`).
        var spawnsByTemplate: [String: [Board]] = [:]
        for b in boardsById.values {
            if let tid = b.spawnedFromTemplateId {
                spawnsByTemplate[tid, default: []].append(b)
            }
        }

        /// Return the in-window spawns of `templateId` for the given
        /// placing board. Mirrors the window filter in
        /// `DerivationPass.computeBoardStatsUpdate` so cycle edges match
        /// the spawn set derivation actually evaluates. If the placing
        /// board is missing (sync race / soft-deleted) we conservatively
        /// skip the fan-out — no edges added.
        ///
        /// Without this filter the cycle check over-approximates and
        /// rejects legitimate placements: e.g., a May spawn referencing
        /// back to an April parent doesn't contribute to April's
        /// evaluation, so it shouldn't contribute to cycle adjacency
        /// from April either.
        func inWindowSpawns(placingBoardId: String, templateId: String) -> [Board] {
            guard let placing = boardsById[placingBoardId] else { return [] }
            let all = spawnsByTemplate[templateId] ?? []
            return all.filter {
                $0.startDate >= placing.startDate && $0.startDate <= placing.endDate
            }
        }

        var adjacency: [String: Set<String>] = [:]
        func addEdge(_ from: String, _ to: String) {
            if from == to { return } // self-edges don't contribute to a multi-step cycle
            adjacency[from, default: []].insert(to)
        }

        for bt in context.allBoardTasks {
            guard let t = tasksById[bt.taskId], t.type == .achievement else { continue }
            if let refBoardId = t.referencedBoardId {
                addEdge(bt.boardId, refBoardId)
            } else if let refTemplateId = t.referencedTemplateId {
                for target in inWindowSpawns(placingBoardId: bt.boardId, templateId: refTemplateId) {
                    addEdge(bt.boardId, target.id)
                }
            }
        }

        // Inject the candidate's prospective edges from each parent. The
        // candidate (Task + its placements) may already be reflected in
        // `allBoardTasks` (e.g., editing an existing Task) — re-adding
        // identical edges is idempotent (Set semantics). Template fan-out
        // is window-aware per parent: a candidate placed on two boards
        // with different windows gets different in-window spawn sets per
        // placement.
        var allCandidateTargets: Set<String> = []
        for parentId in parentBoardIds {
            if let refBoardId = candidate.referencedBoardId {
                addEdge(parentId, refBoardId)
                allCandidateTargets.insert(refBoardId)
            }
            if let refTemplateId = candidate.referencedTemplateId {
                for target in inWindowSpawns(placingBoardId: parentId, templateId: refTemplateId) {
                    addEdge(parentId, target.id)
                    allCandidateTargets.insert(target.id)
                }
            }
        }

        // ── DFS from each candidate target looking for a path back to any parent ──
        for start in allCandidateTargets {
            var visited: Set<String> = []
            if let path = dfsToAnyTarget(
                start: start,
                targets: parentSet,
                adjacency: adjacency,
                visited: &visited
            ) {
                // The hit board id is the parent we landed on. Prepend it
                // again so the cyclePath reads parent → … → back to parent.
                let closingParent = path.last ?? start
                return .cycle(path: [closingParent] + path)
            }
        }

        return .ok
    }

    /// Iterative DFS — returns the path from `start` to any node in
    /// `targets` if reachable, or nil if not.
    ///
    /// The `visited` check runs BEFORE the `targets` hit-check so a node
    /// we've already explored isn't reported as a fresh hit on its second
    /// pop. Mirrors `dfsToAnyTarget` in the TypeScript twin.
    private static func dfsToAnyTarget(
        start: String,
        targets: Set<String>,
        adjacency: [String: Set<String>],
        visited: inout Set<String>
    ) -> [String]? {
        var stack: [(node: String, path: [String])] = [(start, [start])]
        while let frame = stack.popLast() {
            if visited.contains(frame.node) { continue }
            if targets.contains(frame.node) { return frame.path }
            visited.insert(frame.node)
            guard let neighbors = adjacency[frame.node] else { continue }
            for next in neighbors where !visited.contains(next) {
                stack.append((next, frame.path + [next]))
            }
        }
        return nil
    }
}
