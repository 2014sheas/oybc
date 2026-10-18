import Foundation
import UIKit

// MARK: - BoardPlayViewModel + square content and one-gesture writes

// The reads and writes a square's surfaces share — the square sheet, the hold menu
// and (through an anchor board's view model) Task Detail's hero. Extracted out of
// `BoardPlayView+SquareSheet.swift` so Task Detail reuses the exact same windowed
// reads, `SquareLogStrip` recipes and write paths board play uses.
extension BoardPlayViewModel {

    // MARK: Windowed reads

    /// Windowed completed state of a primitive square (see `BoardPlayView.windowedIsCompleted`):
    /// a linked counter reads `resolveLinkedCounterDisplay`, everything else the kernel.
    func windowedCompletedValue(_ task: Task) -> Bool {
        if task.sharedCounterId != nil {
            return resolveLinkedCounterDisplay(
                task: task, eventsByTaskId: windowEventsByTaskId, sealedAt: board?.sealedAt,
                window: board.map(LinkedCounterWindow.init(board:))
            ).isCompleted
        }
        return windowedState(of: task).isCompleted
    }

    /// Windowed count of a counting square (linked counters via `resolveLinkedCounterDisplay`).
    func windowedCountValue(_ task: Task) -> CountValue {
        if task.sharedCounterId != nil {
            return resolveLinkedCounterDisplay(
                task: task, eventsByTaskId: windowEventsByTaskId, sealedAt: board?.sealedAt,
                window: board.map(LinkedCounterWindow.init(board:))
            ).displayed
        }
        return windowedState(of: task).count
    }

    /// Whether this board is sealed (its squares read the frozen snapshot).
    var isSealedBoard: Bool { board?.sealedAt != nil }

    /// Row-major cell index of a placement.
    func cellIndex(of bt: BoardTask) -> Int { bt.row * (board?.boardSize ?? 3) + bt.col }

    // MARK: Content

    /// The windowed count state of a counting task on THIS board, with the chips
    /// `tapLogChips(familyKind, windowGoal, windowedCount)` yields.
    func squareCountState(_ task: Task) -> SquareSheetContent.ChildCount {
        let kind = resolveFamilyCountKind(task, lookup: { taskMap[$0] })
        let goal = task.maxCount ?? 0
        let current = windowedCountValue(task)
        return SquareSheetContent.ChildCount(
            current: current, goal: goal, unit: task.unit ?? "", kind: kind,
            chips: CounterLogAmount.tapChips(kind: kind, goal: goal, windowedCount: current)
        )
    }

    /// A Normal square's done state on this board (sealed boards read the snapshot).
    func squareNormalDone(_ bt: BoardTask, _ task: Task) -> Bool {
        isSealedBoard ? (board?.sealedCompletedCells?.contains(cellIndex(of: bt)) ?? false) : windowedCompletedValue(task)
    }

    /// A compound square's children and completion on this board.
    ///
    /// - Parameter sealBlocked: Task ids whose un-complete would be inert (Decision 9).
    func squareCompound(_ bt: BoardTask, _ task: Task, sealBlocked: Set<String>) -> SquareSheetContent.Compound {
        let children: [SquareSheetContent.Child] = (compoundChildrenByCompound[task.id] ?? []).compactMap { link in
            guard let raw = taskMap[link.childTaskId], !raw.isDeleted else { return nil }
            let child = PlacementParams.withChildTarget(raw, childTargets: bt.childTargets)
            let isDone = compoundChildIsCompleted(child)
            return SquareSheetContent.Child(
                id: child.id, title: child.title, kind: RisoTaskKind(taskType: child.type), isDone: isDone,
                sealBlocked: isDone && sealBlocked.contains(child.id),
                counting: child.type == .counting ? squareCountState(child) : nil
            )
        }
        let isComplete = isSealedBoard
            ? (board?.sealedCompletedCells?.contains(cellIndex(of: bt)) ?? false)
            : CompoundEvaluation.evaluate(
                compound: task, childrenByCompound: compoundChildrenByCompound, taskById: taskMap,
                windowContext: compoundWindowContext, childTargets: bt.childTargets
            )
        return SquareSheetContent.Compound(children: children, isComplete: isComplete)
    }

    /// The watched-board card, from the kernel's per-cell state (the same lookup
    /// the grid cell reads); names are local lookups outside the kernel's domain.
    func squareAchievement(_ bt: BoardTask, _ task: Task) -> SquareSheetContent.Achievement {
        let trigger = task.achievementTrigger ?? .greenlog
        let state = kernelCellStates[bt.id]?.achievement
        if let refBoardId = task.referencedBoardId {
            let ref = allBoardsInWorkspace.first(where: { $0.id == refBoardId && !$0.isDeleted })
            let isMet = state?.referencedBoardCompleted ?? false
            let timeframe = ref.map { $0.timeframe.rawValue.uppercased() }
            return SquareSheetContent.Achievement(
                watchedName: ref?.displayName,
                timeframeBadge: ref.flatMap { $0.isCore ? "Core · \(timeframe ?? "")" : timeframe },
                daysLeft: SquareSheetFormat.daysLeftText(endDate: ref?.endDate),
                progress: trigger == .bingo ? "\(isMet ? 1 : 0) / 1 bingo" : "Greenlog",
                isMet: isMet, openBoardId: ref?.id
            )
        }
        let template = task.referencedTemplateId.flatMap { id in allTemplatesInWorkspace.first(where: { $0.id == id }) }
        let met = state?.templateInWindowMet ?? 0
        let required = state?.templateRequiredCount ?? (task.requiredCount ?? 0)
        return SquareSheetContent.Achievement(
            watchedName: template?.name, timeframeBadge: nil, daysLeft: nil,
            progress: "\(met) / \(required)", isMet: kernelCellStates[bt.id]?.isCompleted ?? false, openBoardId: nil
        )
    }

    // MARK: One-gesture writes

    /// The counting write behind a sheet chip / entry, a hold-menu log and Task Detail's
    /// hero. A preset or rest chip never persists a default; only an "Other…" entry does.
    ///
    /// - Returns: The strip describing the write (text + undo recipe), or nil when no
    ///   write started. The caller shows it as a strip or a toast.
    func performSquareLog(placement bt: BoardTask, taskId: String, amount: CountValue, persistAsDefault: Bool, removing: Bool) -> SquareLogStrip? {
        guard !isProcessing else { return nil }
        let isOwn = taskId == bt.taskId
        let resolved: Task? = isOwn
            ? placedTask(bt)
            : taskMap[taskId].map { PlacementParams.withChildTarget($0, childTargets: bt.childTargets) }
        guard let task = resolved else { return nil }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let placement = isOwn ? bt : boardTasks.first(where: { $0.taskId == taskId && !$0.isDeleted })
        let state = squareCountState(task)
        // The amount actually applied: a removal clamps at the windowed count.
        let applied = removing ? min(amount, state.current) : amount
        guard applied > 0 else { return nil }
        let delta = removing ? -applied : amount
        let undo = squareLogUndo(for: task, placement: placement, delta: delta)
        if isOwn {
            if removing {
                handleCountingDecrement(boardTask: bt, task: task, amount: amount, persistAsDefault: false)
            } else {
                handleCountingTap(boardTask: bt, task: task, amount: amount, persistAsDefault: persistAsDefault)
            }
        } else {
            handleCompoundChildIncrement(childTask: task, direction: removing ? -1 : 1, amount: amount, persistAsDefault: persistAsDefault)
        }
        let root = sharedCounterSourceId(for: task).flatMap { taskMap[$0] }
        return SquareLogStrip.afterWrite(started: isProcessing, SquareLogStrip(
            boardTaskId: bt.id, scopeTaskId: taskId,
            text: SquareSheetFormat.logText(
                amount: applied, kind: state.kind, unit: (root ?? task).unit ?? "",
                board: board?.displayName ?? "", removed: removing
            ),
            undo: undo
        ))
    }

    /// The write behind a compound child toggle (sheet checklist, hold menu, Task Detail):
    /// the strip carries "‹child› · done" and the explicit revert.
    func performChildToggle(placement: BoardTask, childId: String) -> SquareLogStrip? {
        guard !isProcessing, let raw = taskMap[childId] else { return nil }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let child = PlacementParams.withChildTarget(raw, childTargets: placement.childTargets)
        let wasDone = compoundChildIsCompleted(child)
        handleCompoundChildToggle(childTask: child)
        return SquareLogStrip.afterWrite(started: isProcessing, SquareLogStrip(
            boardTaskId: placement.id, scopeTaskId: childId,
            text: SquareSheetFormat.toggleText(title: child.title, nowDone: !wasDone),
            undo: .restoreToggle(taskId: childId, wasDone: wasDone)
        ))
    }
}
