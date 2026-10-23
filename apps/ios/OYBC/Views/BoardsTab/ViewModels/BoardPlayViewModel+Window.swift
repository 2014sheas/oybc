import Foundation

// MARK: - BoardPlayViewModel + Windowed reads

/// The play surface's windowed read helpers (Windowed Completion), split out
/// of `BoardPlayViewModel.swift` when the 2026-09-24 amendment of WC
/// Decision 1 (root squares evaluate `[startDate, endDate]`, not
/// `[startDate, ∞)`) added the end bound + the compound-child resolver — a
/// ROADMAP-B6-style extraction, not a cap bump on the frozen file.
///
/// Every read here is bounded at BOTH ends by the loaded board's window, so a
/// cell, a detail-sheet child row and the tap handlers that compute a delta
/// from them all agree: an event logged after an ended board's `endDate`
/// (e.g. today, on the next window's board) never counts on it.
extension BoardPlayViewModel {

    /// The current board's window lower bound (`board.startDate`), or nil when
    /// no board is loaded.
    var windowStart: String? { board?.startDate }

    /// The current board's window INCLUSIVE upper bound (`boardWindowEnd`), or
    /// nil for an indefinite board / no board loaded.
    var windowEnd: String? { board.flatMap { boardWindowEnd($0) } }

    /// The compound window context for the current board — `[windowStart,
    /// windowEnd]` over the workspace's events — used by compound squares and
    /// the detail sheet's child rows (host-window inheritance).
    var compoundWindowContext: CompoundWindowContext {
        CompoundWindowContext(windowStart: windowStart, windowEnd: windowEnd, eventsByTaskId: windowEventsByTaskId)
    }

    /// Compound children grouped by parent compound task id, sorted by
    /// `childIndex` — the one grouping the kernel rebuild, the grid and the
    /// detail sheet share. Built once per apply (`derived`).
    var compoundChildrenByCompound: [String: [CompoundChild]] { derived.compoundChildrenByCompound }

    /// The placement-adjusted task a surface renders for `bt` (slice 2a):
    /// `PlacementParams.apply` with the root's title settings for a linked
    /// task. Web twin `placedTaskFor`.
    func placedTask(_ bt: BoardTask) -> Task? {
        guard let task = taskMap[bt.taskId] else { return nil }
        let root = task.sharedCounterId.flatMap { taskMap[$0] }
        return PlacementParams.apply(task, placement: bt, settings: root.map { CounterSettings.TitleSettings(task: $0) })
    }

    /// Resolve an event-owning primitive task's windowed state for the current
    /// board window `[windowStart, windowEnd]` (docs §Semantics). Callers must
    /// branch derived / compound / achievement BEFORE calling — this delegates
    /// to the shared `resolveTaskWindowState`. This is the play CELL read: the
    /// view's `windowedIsCompleted` / `windowedCount` resolve through it.
    ///
    /// - Parameter task: The task to resolve (its own `type` / `maxCount` are
    ///   used, so a staged edit override resolves as the staged type).
    /// - Returns: The windowed `{ isCompleted, count }`.
    func windowedState(of task: Task) -> TaskWindowState {
        resolveTaskWindowState(
            task: task,
            events: windowEventsByTaskId[task.id] ?? [],
            windowStart: windowStart,
            windowEnd: windowEnd
        )
    }

    /// `windowedState(of:)` for a task looked up by id in `taskMap`; an
    /// unknown id resolves incomplete with a zero count.
    ///
    /// - Parameter taskId: The task id.
    /// - Returns: The windowed `{ isCompleted, count }`.
    func windowedState(forTaskId taskId: String) -> TaskWindowState {
        guard let task = taskMap[taskId] else { return TaskWindowState(isCompleted: false, count: 0) }
        return windowedState(of: task)
    }

    /// Windowed-Completion-aware "is this square complete" read for the
    /// Board-Edit draft preview surface (`SquaresEditGrid`). iOS parity fix
    /// for the same class of bug the web fix in
    /// d16ff21 patched: these preview surfaces used to read the lifetime
    /// `Task.isCompleted` cache directly, so a lifetime-complete task bled
    /// green into a freshly-spawned/reused board's window even though the
    /// live play grid correctly reads windowed
    /// (docs/WINDOWED_COMPLETION.md §Task caches).
    ///
    /// The same reads the play grid's `buildPlacementRender` makes, over the
    /// task the grid was HANDED: linked counters via `resolveLinkedCounterDisplay`,
    /// a compound through `CompoundEvaluation` in this window with its placement's
    /// `childTargets`, an achievement from the kernel cell, every other primitive
    /// through `windowedState(of:)` against the goal on that task — which is the
    /// placement's goal, since `editDraftTaskMap` hands over the placement-adjusted
    /// row (TASK_WINDOW_REWORK slice 2a). Re-reading the library row by id here
    /// scored a square placed at 1.4 against its library goal (owner report
    /// 2026-10-23: a gold 2.3/1.4 pill with no done fill).
    ///
    /// - Parameter task: The task to resolve, as the edit grid renders it.
    /// - Returns: Whether the square previews as complete.
    func windowedIsCompleted(for task: Task) -> Bool {
        if task.sharedCounterId != nil {
            return resolveLinkedCounterDisplay(
                task: task, eventsByTaskId: windowEventsByTaskId, sealedAt: board?.sealedAt,
                window: board.map(LinkedCounterWindow.init(board:))
            ).isCompleted
        }
        // Placement repair guarantees at most one row per task on a board.
        let placement = boardTasks.first { $0.taskId == task.id }
        switch task.type {
        case .compound:
            // A compound staged in Edit (a type switch, a picker-born add) has no
            // persisted children yet; AND over none is vacuously true, which
            // would paint it done before Save. No children, not done.
            guard !(compoundChildrenByCompound[task.id] ?? []).isEmpty else { return false }
            return CompoundEvaluation.evaluate(
                compound: task, childrenByCompound: compoundChildrenByCompound, taskById: taskMap,
                windowContext: compoundWindowContext, childTargets: placement?.childTargets
            )
        case .achievement:
            guard let placement else { return task.isCompleted }
            return kernelCellStates[placement.id]?.isCompleted ?? false
        case .normal, .counting:
            guard isEventOwningTask(task) else { return task.isCompleted }
            return windowedState(of: task).isCompleted
        }
    }

    /// Whether a compound's CHILD reads complete in this board's window — the
    /// exact resolution the compound detail sheet paints with, and the one
    /// `handleCompoundChildToggle` inverts for its direction (never the
    /// lifetime `isCompleted` latch). Mirrors the web
    /// `resolveCompoundChildCompleted` (`db/adapters.ts`):
    ///
    ///   - deleted child → incomplete;
    ///   - nested compound → `CompoundEvaluation` in this board's window;
    ///   - linked counter → `resolveLinkedCounterDisplay` (window-stamped: its
    ///     root's in-window sum; hub-linked: the latch);
    ///   - any other non-event-owning child (a legacy achievement) → its latch;
    ///   - otherwise → `windowedState(of:)`, bounded at both ends.
    ///
    /// - Parameter child: The child task.
    /// - Returns: Whether the child reads complete on this board.
    func compoundChildIsCompleted(_ child: Task) -> Bool {
        if child.isDeleted { return false }
        if child.type == .compound {
            return CompoundEvaluation.evaluate(
                compound: child,
                childrenByCompound: compoundChildrenByCompound,
                taskById: taskMap,
                windowContext: compoundWindowContext
            )
        }
        if child.sharedCounterId != nil {
            return resolveLinkedCounterDisplay(
                task: child, eventsByTaskId: windowEventsByTaskId, sealedAt: board?.sealedAt,
                window: board.map(LinkedCounterWindow.init(board:))
            ).isCompleted
        }
        // Final-review F12: a non-event-owning child owns no events, so it
        // reads its latch (web `resolveCompoundChildCompleted` parity).
        guard isEventOwningTask(child) else { return child.isCompleted }
        return windowedState(of: child).isCompleted
    }
}
