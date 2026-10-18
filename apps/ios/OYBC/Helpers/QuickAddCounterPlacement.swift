import Foundation

/// Placing a shared counter from the quick-add dropdown / Board Edit picker
/// (docs/SHARED_COUNTER_SETTINGS.md §2): which rows are counter roots. A root is
/// placed as itself; its window goal rides as a placement parameter
/// (`PlacementParamsDraft.forCounterGoal`, TASK_WINDOW_REWORK slice 3b). Web
/// twin: `quickAddCounterPlacement.ts`.
enum QuickAddCounterPlacement {

    /// Whether `task` is a shared counter ROOT the match row treats as the
    /// COUNTER: counting, not itself linked, and created from the hub,
    /// carrying default goals, or linked to by another live task
    /// (`linkedRootIds`, from `counterRootIds(in:)`) — the same roots the
    /// Tasks tab shows as counters, so every search returns the counter.
    ///
    /// - Parameters:
    ///   - task: Any task.
    ///   - linkedRootIds: Ids other live tasks link to (default: none).
    /// - Returns: True for a counter root.
    static func isSharedCounterRoot(_ task: Task, linkedRootIds: Set<String> = []) -> Bool {
        task.type == .counting && task.sharedCounterId == nil
            && (task.isCounter || !(task.timeframeGoals?.isEmpty ?? true) || linkedRootIds.contains(task.id))
    }

    /// The counter roots in a surface's FULL task set (`sharedCounterRootIds`)
    /// — pass the unfiltered set: the browse list drops the linked members
    /// that make a root. Web twin: `counterRootIdsIn`.
    static func counterRootIds(in tasks: [Task]) -> Set<String> {
        sharedCounterRootIds(tasks)
    }

    /// Whether the browse surfaces (Tasks tab, Library sheet) hide `task` as
    /// expired: past its own `endDate` (`TaskExpiry.isTaskExpired`) and NOT a
    /// counter root. A root created inside a board wizard carries that board's
    /// window, but it is the counter — a live family whatever its own window —
    /// so it stays listed. Web twin: `isExpiredForBrowse`.
    ///
    /// - Parameters:
    ///   - task: A library task.
    ///   - linkedRootIds: `counterRootIds(in:)` over the surface's full task set.
    ///   - now: Reference time for the expiry check.
    /// - Returns: True when the surface leaves the row out.
    static func isExpiredForBrowse(_ task: Task, linkedRootIds: Set<String>, now: Date = Date()) -> Bool {
        !isSharedCounterRoot(task, linkedRootIds: linkedRootIds) && TaskExpiry.isTaskExpired(task, now: now)
    }

    /// The counters already sub-tasks of this compound draft: a live child
    /// linked to one (staged `sharedCounterId`, or a saved child whose task
    /// links to it), or a root linked as itself. Web twin: `countersInDraft`.
    static func countersInDraft(_ draft: TaskEditPatch, all: [Task]) -> Set<String> {
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<String>()
        for child in draft.children where !child.markedDeleted {
            if let id = child.sharedCounterId { used.insert(id) }
            if let id = child.childTaskId {
                used.insert(id)
                if let linked = byId[id]?.sharedCounterId { used.insert(linked) }
            }
        }
        return used
    }

    /// The compound editor's sub-task search set: the eligible tasks with every
    /// counter root in `library` listed as the COUNTER (a pick primes a new
    /// linked Counting sub-task). Left out: the counter the compound itself
    /// counts toward (a sub linked to it would credit it twice) and every
    /// counter already a sub-task of THIS compound (`countersInDraft`; other
    /// compounds and the board are separate scopes). Web twin:
    /// `compoundSubCandidates.ts`.
    ///
    /// - Parameters:
    ///   - parentId: The compound being edited.
    ///   - eligible: `CompoundChildEligibility.pickerCandidates` output.
    ///   - library: Browsable library tasks.
    ///   - lookup: The surface's FULL task set.
    ///   - draft: The staged structure (nil: nothing staged yet).
    /// - Returns: The search set (eligible first, then counters) and the counter ids.
    static func compoundSubCandidates(
        parentId: String, eligible: [Task], library: [Task], lookup: [Task], draft: TaskEditPatch? = nil
    ) -> (candidates: [Task], counterIds: Set<String>) {
        let all = lookup + library
        let rootIds = counterRootIds(in: all)
        let countsToward = all.first { $0.id == parentId }?.countsTowardCounterId
        let used = draft.map { countersInDraft($0, all: all) } ?? []
        let counters = library.filter {
            !$0.isDeleted && $0.id != countsToward && !used.contains($0.id)
                && isSharedCounterRoot($0, linkedRootIds: rootIds)
        }
        let counterIds = Set(counters.map(\.id))
        // A counter is only ever offered AS the counter — never as a plain task.
        let plain = eligible.filter { !isSharedCounterRoot($0, linkedRootIds: rootIds) && $0.id != countsToward }
        return (plain + counters, counterIds)
    }
}
