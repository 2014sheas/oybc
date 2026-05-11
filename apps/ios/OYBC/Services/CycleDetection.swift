import Foundation

/// Phase 6.3 — cycle detection for achievement-square cross-board references.
///
/// iOS twin of TypeScript `packages/shared/src/algorithms/cycleDetection.ts`.
/// When that changes, this must change in lockstep.
///
/// Achievement squares can reference another board (`referencedBoardId`) or a
/// recurring template (`referencedTemplateId`, which fans out to all of the
/// template's spawned boards). Without a check, a user could create a chain
/// that loops back on itself — Square on A → references B; Square on B →
/// references A — leaving both boards stuck in a deadlock where neither can
/// ever satisfy the other (derivation reads stored states, so no infinite
/// loop, but the user-visible behavior is broken).
///
/// `hasCycle` runs at placement time. Given a candidate placement, returns
/// `.ok` if no cycle would form, or `.cycle(path:)` with the chain of board
/// ids that closes the loop, suitable for surfacing in the UI.
///
/// Cycle detection is best-effort, NOT a strict invariant: two devices
/// concurrently placing achievement squares can each individually pass their
/// own check and still form a cycle once both writes settle. Derivation
/// reads stored states (not recursive computations), so a post-sync cycle
/// just leaves the involved boards stuck rather than crashing.

/// Candidate placement under consideration.
struct CycleCheckCandidate {
    /// The board the achievement square sits on (the *parent* board).
    let boardId: String
    /// Optional: the specific board id the square would reference.
    let referencedBoardId: String?
    /// Optional: the recurring-template id the square would reference.
    let referencedTemplateId: String?
}

/// Read context for the check.
struct CycleCheckContext {
    /// All non-deleted board_tasks in the workspace (used to walk the graph).
    let allBoardTasks: [BoardTask]
    /// All non-deleted boards in the workspace (used to resolve template
    /// spawns AND to check the parent's `spawnedFromTemplateId` for
    /// template-self-reference).
    let allBoards: [Board]
}

/// Outcome.
enum CycleCheckResult: Equatable {
    case ok
    case cycle(path: [String])
}

enum CycleDetection {
    /// Walks the reference graph from the candidate placement looking for a
    /// path back to the candidate's own `boardId`. Self-reference of either
    /// kind is a degenerate one-step cycle and short-circuits.
    static func hasCycle(
        candidate: CycleCheckCandidate,
        context: CycleCheckContext
    ) -> CycleCheckResult {
        let boardId = candidate.boardId

        // ── Self-reference: degenerate cycle ──
        if let refBoardId = candidate.referencedBoardId, refBoardId == boardId {
            return .cycle(path: [boardId, boardId])
        }
        if let refTemplateId = candidate.referencedTemplateId {
            // Template-self-reference: the parent board is itself a spawn of
            // the template the square would watch. The square would
            // (conceptually) wait on its own parent's status — degenerate.
            if let parent = context.allBoards.first(where: { $0.id == boardId }),
               parent.spawnedFromTemplateId == refTemplateId {
                return .cycle(path: [boardId, boardId])
            }
        }

        // ── Build adjacency from existing board_tasks ──
        var adjacency: [String: Set<String>] = [:]

        // Index spawns once for template-fan-out edges.
        var spawnsByTemplate: [String: [String]] = [:]
        for b in context.allBoards {
            if b.isDeleted { continue }
            if let tid = b.spawnedFromTemplateId {
                spawnsByTemplate[tid, default: []].append(b.id)
            }
        }

        func addEdge(_ from: String, _ to: String) {
            if from == to { return } // self-edges don't contribute to a multi-step cycle
            adjacency[from, default: []].insert(to)
        }

        for bt in context.allBoardTasks {
            if bt.isAchievementSquare != true { continue }
            if let refBoardId = bt.referencedBoardId {
                addEdge(bt.boardId, refBoardId)
            } else if let refTemplateId = bt.referencedTemplateId {
                for target in spawnsByTemplate[refTemplateId] ?? [] {
                    addEdge(bt.boardId, target)
                }
            }
        }

        // Inject the candidate's prospective edges. The candidate is NOT yet
        // in `allBoardTasks` (it's the row about to be written), so its
        // outgoing edges must be added explicitly.
        var candidateTargets: Set<String> = []
        if let refBoardId = candidate.referencedBoardId {
            candidateTargets.insert(refBoardId)
        }
        if let refTemplateId = candidate.referencedTemplateId {
            for target in spawnsByTemplate[refTemplateId] ?? [] {
                candidateTargets.insert(target)
            }
        }
        for target in candidateTargets {
            addEdge(boardId, target)
        }

        // ── DFS from each candidate target looking for a path back to boardId ──
        for start in candidateTargets {
            var visited: Set<String> = []
            if let path = dfsToTarget(
                start: start,
                target: boardId,
                adjacency: adjacency,
                visited: &visited
            ) {
                return .cycle(path: [boardId] + path)
            }
        }

        return .ok
    }

    /// Iterative DFS — returns the path from `start` to `target` if
    /// reachable, or nil if not. Visited-set prevents revisits.
    private static func dfsToTarget(
        start: String,
        target: String,
        adjacency: [String: Set<String>],
        visited: inout Set<String>
    ) -> [String]? {
        var stack: [(node: String, path: [String])] = [(start, [start])]
        while let frame = stack.popLast() {
            if frame.node == target { return frame.path }
            if visited.contains(frame.node) { continue }
            visited.insert(frame.node)
            guard let neighbors = adjacency[frame.node] else { continue }
            for next in neighbors where !visited.contains(next) {
                stack.append((next, frame.path + [next]))
            }
        }
        return nil
    }
}
