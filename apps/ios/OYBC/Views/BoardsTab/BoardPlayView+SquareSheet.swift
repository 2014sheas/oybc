import SwiftUI
import UIKit

// MARK: - BoardPlayView + square sheet + tap contract

// The tap contract and the square sheet's presenter, split out of
// `BoardPlayView.swift` (frozen at its file-size cap — an extraction, not a cap
// bump). Normal → toggle + Undo toast. Counting / Compound / Achievement, and
// every tap on a closed board → the square sheet (`SquareSheet/`), a pure-props
// leaf this file feeds from the live view model. Web twin:
// `components/boardPlay/squareSheet/` + `BoardPlaySurface.tsx`.
extension BoardPlayView {

    // MARK: Tap

    /// A tap on a placed square (docs/TASK_DETAIL_REDESIGN.md §Tap contract).
    func handlePlaySquareTap(boardTask: BoardTask, task: Task?) {
        guard !pagerSwipeActive else { return }
        // A closed board opens the sheet read-only for every type.
        if isBoardLocked {
            squareSheetBoardTaskId = boardTask.id
            return
        }
        guard !viewModel.isProcessing else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if let task, task.type == .normal {
            toggleNormalSquare(boardTask: boardTask, task: task)
        } else {
            squareSheetBoardTaskId = boardTask.id
        }
    }

    /// Normal: toggle immediately and raise the Undo toast ("Finish Dune · done" /
    /// "Week 42"); a credited counter appends " · +1 Books" when the write lands
    /// (`triggerCreditToast`). Undo re-toggles.
    private func toggleNormalSquare(boardTask: BoardTask, task: Task) {
        let wasDone = windowedIsCompleted(task)
        viewModel.handleNormalTap(boardTask: boardTask)
        guard viewModel.isProcessing else { return } // the write never started
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            creditToast = CreditToastState(
                sourceTaskId: boardTask.taskId, amount: 0, unit: "", verb: .logged,
                message: "\(task.title) · \(wasDone ? "not done" : "done")",
                undo: .counterLog, toastKey: UUID().uuidString,
                detail: board?.displayName ?? "", retoggle: boardTask, wasDone: wasDone
            )
        }
    }

    // MARK: Toast

    /// Fires the toast for a ripple that credited other boards, or — when a
    /// Normal toggle's toast is up for the written task — appends the credited
    /// counter to its second line. A log from the square sheet has its own
    /// inline strip, so no toast.
    func triggerCreditToast(payload: SharedCounterCreditToastPayload) {
        guard squareSheetBoardTaskId == nil else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            if let current = creditToast, let placement = current.retoggle,
               case let .uncomplete(taskId, _) = payload.undo, taskId == placement.taskId {
                let root = taskMap[payload.sourceTaskId]
                let name = root.map { CounterSettings.counterDisplayName($0) } ?? ""
                let credit = "+\(formatCount(payload.amount, kind: resolveCountKind(root?.countKind))) \(name)"
                creditToast = CreditToastState(
                    sourceTaskId: current.sourceTaskId, amount: current.amount, unit: current.unit, verb: current.verb,
                    message: current.message, undo: current.undo, toastKey: current.toastKey,
                    detail: [current.detail, credit].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    retoggle: placement
                )
            } else {
                creditToast = CreditToastState(
                    sourceTaskId: payload.sourceTaskId, amount: payload.amount, unit: payload.unit,
                    verb: payload.isIncrement ? .logged : .removed, message: payload.message,
                    undo: payload.undo, toastKey: UUID().uuidString
                )
            }
        }
    }

    /// The toast's Undo: a Normal toggle restores the square's PRIOR state; a
    /// credited log reverses through the existing undo kinds.
    ///
    /// - Returns: False when a write is in flight — the caller keeps the toast so Undo can be retried.
    func undoCreditToastState(_ toast: CreditToastState) -> Bool {
        if let placement = toast.retoggle, let wasDone = toast.wasDone {
            return viewModel.setNormalCompleted(boardTask: placement, completed: wasDone)
        }
        viewModel.undoCreditToast(toast.undo, sourceTaskId: toast.sourceTaskId)
        return true
    }

    // MARK: Sheet

    /// The sheet's content with the Riso presentation chrome.
    @ViewBuilder
    var squareSheet: some View {
        if let id = squareSheetBoardTaskId, let content = squareSheetContent(boardTaskId: id) {
            SquareSheetView(content: content, strip: squareLogStrip, actions: squareSheetActions)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.risoPaper)
                .presentationCornerRadius(12)
        }
    }

    /// Opens whatever was requested from inside the sheet now that it has
    /// unmounted: the library, a watched board, or the late-log sheet.
    func drainSquareSheetHandOffs() {
        squareLogStrip = nil
        if let id = pendingTaskDetailTaskId {
            pendingTaskDetailTaskId = nil
            taskDetailSheetTaskId = TaskIdItem(id: id)
        }
        drainPendingOpenBoard()
        if let id = pendingLateLogBoardTaskId {
            pendingLateLogBoardTaskId = nil
            if let placement = boardTasks.first(where: { $0.id == id }) {
                let task = viewModel.placedTask(placement)
                routeLateLogTap(routable: isLateLogRoutable(task: task), boardTask: placement, task: task)
            }
        }
    }

    /// Windowed Completion (docs Decision 9): resolve `isUncompleteBlockedBySeal`
    /// for the sheet's own task and its compound children, off-main, so a
    /// completion held only by a sealed window disables its un-complete.
    func loadSealBlockedTaskIds(for boardTaskId: String?) {
        guard let boardTaskId,
              let bt = boardTasks.first(where: { $0.id == boardTaskId }),
              let task = taskMap[bt.taskId] else {
            sealBlockedTaskIds = []
            return
        }
        var candidateIds: [String] = [task.id]
        if task.type == .compound {
            candidateIds.append(contentsOf: (viewModel.compoundChildrenByCompound[task.id] ?? []).map { $0.childTaskId })
        }
        let db = viewModel.database
        _Concurrency.Task.detached(priority: .utility) {
            var blocked: Set<String> = []
            for id in candidateIds {
                if let isBlocked = try? db.isUncompleteBlockedBySeal(taskId: id), isBlocked { blocked.insert(id) }
            }
            await MainActor.run { self.sealBlockedTaskIds = blocked }
        }
    }

    // MARK: Content

    /// The windowed count state of a counting task on THIS board, with the chips
    /// `tapLogChips(familyKind, windowGoal, windowedCount)` yields.
    private func squareCountState(_ task: Task) -> SquareSheetContent.ChildCount {
        let kind = resolveFamilyCountKind(task, lookup: { taskMap[$0] })
        let goal = task.maxCount ?? 0
        let current = windowedCount(task)
        return SquareSheetContent.ChildCount(
            current: current, goal: goal, unit: task.unit ?? "", kind: kind,
            chips: CounterLogAmount.tapChips(kind: kind, goal: goal, windowedCount: current)
        )
    }

    /// Builds the sheet's props for a placement; nil when it no longer resolves.
    func squareSheetContent(boardTaskId: String) -> SquareSheetContent? {
        guard let bt = boardTasks.first(where: { $0.id == boardTaskId }), let task = viewModel.placedTask(bt) else { return nil }
        let closed: SquareSheetContent.Closed? = isBoardLocked
            ? SquareSheetContent.Closed(
                lockText: SquareSheetFormat.closedText(sealedAt: board?.sealedAt),
                canLateLog: isLateLogRoutable(task: task)
            )
            : nil
        let body: SquareSheetContent.Body
        switch task.type {
        case .normal:
            let index = bt.row * (board?.boardSize ?? 3) + bt.col
            let isDone = isSealed ? (board?.sealedCompletedCells?.contains(index) ?? false) : windowedIsCompleted(task)
            body = .normal(isDone: isDone, sealBlocked: isDone && sealBlockedTaskIds.contains(task.id))
        case .counting:
            body = .counting(squareCountState(task))
        case .compound:
            body = .compound(squareCompound(bt, task))
        case .achievement:
            body = .achievement(squareAchievement(bt, task))
        }
        return SquareSheetContent(
            boardTaskId: bt.id, taskId: task.id, title: task.title, kind: RisoTaskKind(taskType: task.type),
            boardName: board?.displayName ?? "", closed: closed, isBusy: viewModel.isProcessing, body: body
        )
    }

    private func squareCompound(_ bt: BoardTask, _ task: Task) -> SquareSheetContent.Compound {
        let children: [SquareSheetContent.Child] = (viewModel.compoundChildrenByCompound[task.id] ?? []).compactMap { link in
            guard let raw = taskMap[link.childTaskId], !raw.isDeleted else { return nil }
            let child = PlacementParams.withChildTarget(raw, childTargets: bt.childTargets)
            let isDone = viewModel.compoundChildIsCompleted(child)
            return SquareSheetContent.Child(
                id: child.id, title: child.title, kind: RisoTaskKind(taskType: child.type), isDone: isDone,
                sealBlocked: isDone && sealBlockedTaskIds.contains(child.id),
                counting: child.type == .counting ? squareCountState(child) : nil
            )
        }
        let index = bt.row * (board?.boardSize ?? 3) + bt.col
        let isComplete = isSealed
            ? (board?.sealedCompletedCells?.contains(index) ?? false)
            : CompoundEvaluation.evaluate(
                compound: task, childrenByCompound: viewModel.compoundChildrenByCompound, taskById: taskMap,
                windowContext: viewModel.compoundWindowContext, childTargets: bt.childTargets
            )
        return SquareSheetContent.Compound(children: children, isComplete: isComplete)
    }

    /// The watched-board card, from the kernel's per-cell state (the same lookup
    /// the grid cell reads); names are local lookups outside the kernel's domain.
    private func squareAchievement(_ bt: BoardTask, _ task: Task) -> SquareSheetContent.Achievement {
        let trigger = task.achievementTrigger ?? .greenlog
        let state = viewModel.kernelCellStates[bt.id]?.achievement
        if let refBoardId = task.referencedBoardId {
            let ref = viewModel.allBoardsInWorkspace.first(where: { $0.id == refBoardId && !$0.isDeleted })
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
        let template = task.referencedTemplateId.flatMap { id in viewModel.allTemplatesInWorkspace.first(where: { $0.id == id }) }
        let met = state?.templateInWindowMet ?? 0
        let required = state?.templateRequiredCount ?? (task.requiredCount ?? 0)
        return SquareSheetContent.Achievement(
            watchedName: template?.name, timeframeBadge: nil, daysLeft: nil,
            progress: "\(met) / \(required)", isMet: viewModel.kernelCellStates[bt.id]?.isCompleted ?? false, openBoardId: nil
        )
    }

    // MARK: Actions

    private var squareSheetActions: SquareSheetActions {
        SquareSheetActions(
            onOpenLibrary: { id in
                pendingTaskDetailTaskId = id
                squareSheetBoardTaskId = nil
            },
            onLog: { id, amount, persist in squareSheetLog(taskId: id, amount: amount, persistAsDefault: persist, removing: false) },
            onRemove: { id, amount in squareSheetLog(taskId: id, amount: amount, persistAsDefault: false, removing: true) },
            onUndo: {
                guard let strip = squareLogStrip else { return }
                squareLogStrip = nil
                viewModel.undoSquareLog(strip.undo)
            },
            onToggleChild: { id in
                guard !viewModel.isProcessing, let placement = currentSquareSheetPlacement,
                      let raw = taskMap[id] else { return }
                squareLogStrip = nil
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                let child = PlacementParams.withChildTarget(raw, childTargets: placement.childTargets)
                let wasDone = viewModel.compoundChildIsCompleted(child)
                viewModel.handleCompoundChildToggle(childTask: child)
                squareLogStrip = SquareLogStrip.afterWrite(started: viewModel.isProcessing, SquareLogStrip(
                    boardTaskId: placement.id, scopeTaskId: id,
                    text: SquareSheetFormat.toggleText(title: child.title, nowDone: !wasDone),
                    undo: .restoreToggle(taskId: id, wasDone: wasDone)
                ))
            },
            // Mark done toggles, closes the sheet and raises the same Undo toast as a tap.
            onMarkDone: {
                guard !viewModel.isProcessing, let placement = currentSquareSheetPlacement,
                      let task = viewModel.placedTask(placement) else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                toggleNormalSquare(boardTask: placement, task: task)
                squareSheetBoardTaskId = nil
            },
            onOpenBoard: { id in
                pendingOpenBoardId = id
                squareSheetBoardTaskId = nil
            },
            onLateLog: {
                pendingLateLogBoardTaskId = squareSheetBoardTaskId
                squareSheetBoardTaskId = nil
            }
        )
    }

    private var currentSquareSheetPlacement: BoardTask? {
        squareSheetBoardTaskId.flatMap { id in boardTasks.first(where: { $0.id == id }) }
    }

    /// One chip / entry write from the sheet, then the Undo strip. A preset or
    /// rest chip never persists a default; only an "Other…" entry does.
    private func squareSheetLog(taskId: String, amount: CountValue, persistAsDefault: Bool, removing: Bool) {
        guard !viewModel.isProcessing, let bt = currentSquareSheetPlacement else { return }
        squareLogStrip = nil // any new write invalidates the previous strip
        let isOwn = taskId == bt.taskId
        let resolved: Task? = isOwn
            ? viewModel.placedTask(bt)
            : taskMap[taskId].map { PlacementParams.withChildTarget($0, childTargets: bt.childTargets) }
        guard let task = resolved else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let placement = isOwn ? bt : boardTasks.first(where: { $0.taskId == taskId && !$0.isDeleted })
        let state = squareCountState(task)
        // The amount actually applied: a removal clamps at the windowed count.
        let applied = removing ? min(amount, state.current) : amount
        guard applied > 0 else { return }
        let delta = removing ? -applied : amount
        let undo = viewModel.squareLogUndo(for: task, placement: placement, delta: delta)
        if isOwn {
            if removing {
                viewModel.handleCountingDecrement(boardTask: bt, task: task, amount: amount, persistAsDefault: false)
            } else {
                viewModel.handleCountingTap(boardTask: bt, task: task, amount: amount, persistAsDefault: persistAsDefault)
            }
        } else {
            viewModel.handleCompoundChildIncrement(childTask: task, direction: removing ? -1 : 1, amount: amount, persistAsDefault: persistAsDefault)
        }
        let root = viewModel.sharedCounterSourceId(for: task).flatMap { taskMap[$0] }
        squareLogStrip = SquareLogStrip.afterWrite(started: viewModel.isProcessing, SquareLogStrip(
            boardTaskId: bt.id, scopeTaskId: taskId,
            text: SquareSheetFormat.logText(
                amount: applied, kind: state.kind, unit: (root ?? task).unit ?? "",
                board: board?.displayName ?? "", removed: removing
            ),
            undo: undo
        ))
    }
}
