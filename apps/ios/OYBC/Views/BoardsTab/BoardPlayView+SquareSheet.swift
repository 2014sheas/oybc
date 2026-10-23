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
    func toggleNormalSquare(boardTask: BoardTask, task: Task) {
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
        var creditedTaskId: String?
        if case let .uncomplete(taskId, _) = payload.undo { creditedTaskId = taskId }
        let action = CreditToastAction.resolve(sheetOpen: squareSheetBoardTaskId != nil, showing: creditToast, creditedTaskId: creditedTaskId)
        guard action != .ignore else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            if action == .augmentNormal, let current = creditToast, let placement = current.retoggle {
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
        if let undo = toast.squareUndo {
            guard !viewModel.isProcessing else { return false }
            viewModel.undoSquareLog(undo)
            return true
        }
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
            SquareSheetView(content: content, strip: squareLogStrip, actions: squareSheetActions, initialEntry: squareSheetEntry)
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
        squareSheetEntry = nil
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

    // MARK: Content

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
            let isDone = viewModel.squareNormalDone(bt, task)
            body = .normal(isDone: isDone, sealBlocked: isDone && viewModel.derived.sealBlockedTaskIds.contains(task.id))
        case .counting:
            body = .counting(viewModel.squareCountState(task))
        case .compound:
            body = .compound(viewModel.squareCompound(bt, task, sealBlocked: viewModel.derived.sealBlockedTaskIds))
        case .achievement:
            body = .achievement(viewModel.squareAchievement(bt, task))
        }
        return SquareSheetContent(
            boardTaskId: bt.id, taskId: task.id, title: task.title, kind: RisoTaskKind(taskType: task.type),
            boardName: board?.displayName ?? "", closed: closed, isBusy: viewModel.isProcessing, busyLook: viewModel.showsBusyLook, body: body
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
                guard let placement = currentSquareSheetPlacement else { return }
                squareLogStrip = nil
                squareLogStrip = viewModel.performChildToggle(placement: placement, childId: id)
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

    /// One chip / entry write from the sheet, then the Undo strip.
    private func squareSheetLog(taskId: String, amount: CountValue, persistAsDefault: Bool, removing: Bool) {
        guard let bt = currentSquareSheetPlacement else { return }
        squareLogStrip = nil // any new write invalidates the previous strip
        squareLogStrip = viewModel.performSquareLog(placement: bt, taskId: taskId, amount: amount, persistAsDefault: persistAsDefault, removing: removing)
    }
}
