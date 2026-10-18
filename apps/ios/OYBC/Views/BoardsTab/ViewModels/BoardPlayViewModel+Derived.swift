import Foundation

// MARK: - BoardPlayViewModel + per-apply derived state

/// Lookups and per-placement render inputs the play surface reads many times per
/// body pass, built ONCE per `apply(_:)` instead of per read. Before this, `taskMap`
/// (a 541-entry dictionary), `compoundChildrenByCompound` (regroup + sort), the
/// sealed-board `isUncompleteBlockedBySeal` DB reads and every cell's / hold menu's
/// windowed resolution re-ran on each render — the lag a counting log showed.
struct BoardPlayDerived {
    /// O(1) task lookup by id over `allTasks`.
    var taskMap: [String: Task] = [:]
    /// Compound children grouped by parent, sorted by `childIndex`.
    var compoundChildrenByCompound: [String: [CompoundChild]] = [:]
    /// Ids that head a shared-counter family through a live linked row.
    var linkedRootIds: Set<String> = []
    /// Task ids placed on THIS board with a `targetOverride` (they head a family too).
    var overriddenPlacementTaskIds: Set<String> = []
    /// "row-col" → the integrity-resolved placement (what the grid draws).
    var placementsByPosition: [String: BoardTask] = [:]
    /// Task ids on this board whose un-complete would be inert (every completion held by a sealed window).
    var sealBlockedTaskIds: Set<String> = []
    /// Per-placement cell + hold-menu inputs, keyed by `BoardTask.id`.
    var renders: [String: PlacementRender] = [:]

    #if DEBUG
    /// Test seam: how many times a `taskMap` was built (once per apply, never per read).
    nonisolated(unsafe) static var taskMapBuilds = 0
    #endif

    /// The structural lookups; renders and the seal-blocked set are filled by the view model after.
    init(tasks: [Task] = [], children: [CompoundChild] = [], boardTasks: [BoardTask] = [], boardSize: Int = 3) {
        #if DEBUG
        Self.taskMapBuilds += 1
        #endif
        taskMap = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var grouped: [String: [CompoundChild]] = [:]
        for c in children { grouped[c.compoundTaskId, default: []].append(c) }
        for id in grouped.keys { grouped[id]?.sort { $0.childIndex < $1.childIndex } }
        compoundChildrenByCompound = grouped
        for t in tasks where !t.isDeleted {
            if let root = t.sharedCounterId { linkedRootIds.insert(root) }
        }
        for bt in boardTasks where !bt.isDeleted && bt.targetOverride != nil { overriddenPlacementTaskIds.insert(bt.taskId) }
        for bt in PlacementIntegrity.resolvePlacements(boardTasks, boardSize: boardSize) {
            placementsByPosition["\(bt.row)-\(bt.col)"] = bt
        }
    }
}

/// Everything a play cell and its hold menu read for one placement, resolved at
/// apply time. Counts are the LOADED values — the view adds the view model's
/// pending (optimistic) delta on top (`displayCount(of:)` / `menuInput(for:)`).
struct PlacementRender {
    /// The placement-adjusted task (`placedTask`); nil when the task no longer resolves.
    let task: Task?
    let isCompleted: Bool
    /// The loaded windowed count for a counting square, else the lifetime `currentCount` cache.
    let baseCount: CountValue
    let maxCount: CountValue
    let countKind: CountKind
    let isSharedCounter: Bool
    let compoundDoneCount: Int
    let compoundChildCount: Int
    let compoundRequiredCount: Int
    /// The family key a pending delta on this square's count is stored under (counting only).
    let countFamilyKey: String?
    /// The hold menu's input with the loaded counts and `isBusy` false; nil without a task.
    let menu: SquareMenuInput?
    /// The compound menu's next counting child's family key, when it has one.
    let menuNextChildKey: String?
}

extension BoardPlayViewModel {

    // MARK: Family keys

    /// The key a task's displayed count moves under when a write lands on its counter family:
    /// its shared root, else itself.
    static func countFamilyKey(_ task: Task) -> String {
        if let root = task.sharedCounterId, !root.isEmpty { return root }
        return task.id
    }

    // MARK: Reads

    /// The cell/menu inputs for a placement — the apply-time value, built on the spot only when
    /// the placement isn't in the cache (a render that raced ahead of an apply).
    func placementRender(for bt: BoardTask) -> PlacementRender {
        derived.renders[bt.id] ?? buildPlacementRender(bt)
    }

    /// The count a cell / sheet shows: the loaded count plus any optimistic delta.
    func displayCount(of render: PlacementRender) -> CountValue {
        guard let key = render.countFamilyKey else { return render.baseCount }
        return render.baseCount + (pendingCountDeltas[key] ?? 0)
    }

    /// The hold menu's input with the live busy look and any optimistic count folded in.
    func menuInput(for render: PlacementRender) -> SquareMenuInput? {
        guard var input = render.menu else { return nil }
        input.isBusy = showsBusyLook
        guard !pendingCountDeltas.isEmpty else { return input }
        func moved(_ c: SquareMenuInput.Counting, _ key: String?) -> SquareMenuInput.Counting {
            guard let key, let delta = pendingCountDeltas[key] else { return c }
            return SquareMenuInput.Counting(kind: c.kind, unit: c.unit, current: c.current + delta, goal: c.goal, rememberedDefault: c.rememberedDefault)
        }
        switch input.body {
        case let .counting(c):
            input.body = .counting(moved(c, render.countFamilyKey))
        case let .compound(c):
            input.body = .compound(SquareMenuInput.Compound(
                next: c.next, nextChildTitle: c.nextChildTitle, nextChild: c.nextChild.map { moved($0, render.menuNextChildKey) },
                doneCount: c.doneCount, total: c.total
            ))
        default: break
        }
        return input
    }

    /// D15: whether a CLOSED board's square for `task` routes to the late-log sheet (NORMAL / any
    /// COUNTING, linked included / COMPOUND) rather than staying interaction-locked (ACHIEVEMENT).
    func lateLogRoutable(task: Task?) -> Bool {
        guard isSealedBoard, let t = task else { return false }
        if t.type == .compound { return true }
        return lateLogEventOwningTaskId(for: t) != nil
    }

    // MARK: Build

    /// Rebuilds every placement's render. Run by `apply(_:)` after the structural lookups, the
    /// kernel cell states and the seal-blocked set are in place.
    func buildPlacementRenders() -> [String: PlacementRender] {
        var out: [String: PlacementRender] = [:]
        for bt in boardTasks where !bt.isDeleted { out[bt.id] = buildPlacementRender(bt) }
        return out
    }

    /// Task ids on this board whose un-complete would be inert, from the data the reload already
    /// loaded (no database read): the board's placed tasks and every compound child.
    func computeSealBlockedTaskIds() -> Set<String> {
        guard allBoardsInWorkspace.contains(where: { !$0.isDeleted && $0.sealedAt != nil }) else { return [] }
        var candidates = Set<String>()
        for bt in boardTasks where !bt.isDeleted {
            candidates.insert(bt.taskId)
            for link in derived.compoundChildrenByCompound[bt.taskId] ?? [] { candidates.insert(link.childTaskId) }
        }
        return SealBlocked.blockedTaskIds(
            candidateIds: candidates, boards: allBoardsInWorkspace, tasks: allTasks, compoundChildren: allCompoundChildren,
            boardTasks: allBoardTasksInWorkspace, eventsByTaskId: windowEventsByTaskId
        )
    }

    /// One placement's cell + hold-menu inputs (the logic that used to run per cell per body pass in
    /// `BoardPlayView.risoPlaySquare` / `squareMenuInput`, unchanged).
    func buildPlacementRender(_ bt: BoardTask) -> PlacementRender {
        let task = placedTask(bt)
        let index = cellIndex(of: bt)

        let isCompleted: Bool = {
            if isSealedBoard { return board?.sealedCompletedCells?.contains(index) ?? false }
            guard let task else { return false }
            if task.type == .compound {
                return CompoundEvaluation.evaluate(
                    compound: task, childrenByCompound: compoundChildrenByCompound, taskById: taskMap,
                    windowContext: compoundWindowContext, childTargets: bt.childTargets
                )
            }
            if task.type == .achievement { return kernelCellStates[bt.id]?.isCompleted ?? false }
            return windowedCompletedValue(task)
        }()

        let baseCount: CountValue = {
            guard let t = task else { return 0 }
            return t.type == .counting ? windowedBaseCountValue(t) : (t.currentCount ?? 0)
        }()

        let links = task.map { compoundChildrenByCompound[$0.id] ?? [] } ?? []
        let compoundDone = links.filter { link in
            guard let raw = taskMap[link.childTaskId], !raw.isDeleted else { return false }
            let child = PlacementParams.withChildTarget(raw, childTargets: bt.childTargets)
            if child.type == .compound {
                return CompoundEvaluation.evaluate(
                    compound: child, childrenByCompound: compoundChildrenByCompound, taskById: taskMap, windowContext: compoundWindowContext
                )
            }
            return windowedCompletedValue(child)
        }.count
        let required: Int = {
            guard let t = task, t.type == .compound, !links.isEmpty else { return links.count }
            switch t.operatorType {
            case .or: return 1
            case .mOfN: return Swift.max(1, t.threshold ?? 1)
            case .and, nil: return links.count
            }
        }()

        let (menu, nextChildKey) = task.map { buildMenuInput(bt, $0) } ?? (nil, nil)
        return PlacementRender(
            task: task, isCompleted: isCompleted, baseCount: baseCount, maxCount: task?.maxCount ?? 0,
            countKind: task.map { resolveFamilyCountKind($0, lookup: { taskMap[$0] }) } ?? .discrete,
            isSharedCounter: showsSharedCounterMark(for: task),
            compoundDoneCount: compoundDone, compoundChildCount: links.count, compoundRequiredCount: required,
            countFamilyKey: task.flatMap { $0.type == .counting ? Self.countFamilyKey($0) : nil },
            menu: menu, menuNextChildKey: nextChildKey
        )
    }

    /// Facts a counting task's menu rows need (the quick amount's remembered default follows the
    /// shared source for discrete counters, else the task's own).
    private func menuCounting(_ t: Task) -> SquareMenuInput.Counting {
        let kind = resolveFamilyCountKind(t, lookup: { taskMap[$0] })
        let source = sharedCounterSourceId(for: t).flatMap { taskMap[$0] }
        return SquareMenuInput.Counting(
            kind: kind, unit: t.unit ?? "", current: windowedBaseCountValue(t), goal: t.maxCount ?? 0,
            rememberedDefault: kind == .discrete ? source?.defaultLogAmount : (source ?? t).defaultLogAmount
        )
    }

    private func buildMenuInput(_ bt: BoardTask, _ task: Task) -> (SquareMenuInput, String?) {
        let body: SquareMenuInput.Body
        var nextChildKey: String?
        switch task.type {
        case .normal:
            let isDone = squareNormalDone(bt, task)
            body = .normal(isDone: isDone, sealBlocked: SquareMenu.sealBlocked(
                isDone: isDone, isClosed: isSealedBoard, taskId: task.id, cached: derived.sealBlockedTaskIds
            ))
        case .counting:
            body = .counting(menuCounting(task))
        case .compound:
            let children: [Task] = (compoundChildrenByCompound[task.id] ?? []).compactMap { link in
                guard let raw = taskMap[link.childTaskId], !raw.isDeleted else { return nil }
                return PlacementParams.withChildTarget(raw, childTargets: bt.childTargets)
            }
            let candidates = children.map {
                TaskDetailKernel.SubtaskCandidate(id: $0.id, type: $0.type, isCompleted: compoundChildIsCompleted($0))
            }
            let next = TaskDetailKernel.nextSubtask(candidates)
            var nextId: String?
            switch next {
            case let .toggle(childId)?, let .log(childId)?: nextId = childId
            case nil: nextId = nil
            }
            let nextChild = children.first { $0.id == nextId }
            nextChildKey = nextChild.flatMap { $0.type == .counting ? Self.countFamilyKey($0) : nil }
            body = .compound(SquareMenuInput.Compound(
                next: next, nextChildTitle: nextChild?.title,
                nextChild: nextChild.flatMap { $0.type == .counting ? menuCounting($0) : nil },
                doneCount: candidates.filter(\.isCompleted).count, total: candidates.count
            ))
        case .achievement:
            let a = squareAchievement(bt, task)
            body = .achievement(isMet: a.isMet, watchedName: a.watchedName, openBoardId: a.openBoardId)
        }
        return (SquareMenuInput(
            title: task.title, kind: RisoTaskKind(taskType: task.type), body: body,
            isClosed: isSealedBoard, lateLogRoutable: lateLogRoutable(task: task), isBusy: false
        ), nextChildKey)
    }
}
