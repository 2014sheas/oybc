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
            if task?.type == .counting { tutorialCoach?.handle(.countingSheetOpened) }
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
        if !wasDone { tutorialCoach?.handle(.simpleSquareDone) }
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
                .tutorialCoachLayer()
                // While the lesson lights the sheet it closes only through the
                // lesson; a sheet opened from a lit square (the finale's Read)
                // keeps its swipe-down, since nothing on it is scripted.
                .interactiveDismissDisabled(tutorialCoach?.session?.screenStep?.onSheet == true)
                .modifier(TutorialSheetCloser())
        }
    }

    /// Opens whatever was requested from inside the sheet now that it has
    /// unmounted: the library, a watched board, or the late-log sheet.
    func drainSquareSheetHandOffs() {
        squareLogStrip = nil
        squareSheetEntry = nil
        tutorialCoach?.handle(.squareSheetClosed) // a lesson lighting the sheet steps back
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
                tutorialCoach?.handle(.squareLogUndone) // a lesson lighting the strip steps back to the chips
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
        let before = tutorialCoach == nil || removing || taskId != bt.taskId ? nil : viewModel.placedTask(bt).map(viewModel.squareCountState)
        squareLogStrip = viewModel.performSquareLog(placement: bt, taskId: taskId, amount: amount, persistAsDefault: persistAsDefault, removing: removing)
        if squareLogStrip != nil, let before { reportTutorialLog(before: before, amount: amount) }
    }

    /// Getting Started: tells the lesson what the log produced ("22 of 20", or
    /// "13 of 20" when the chip did not finish the square) and that a chip was
    /// used — any chip moves the lesson on, as the handoff scripts it; a square
    /// left short is lit again by the finale. Inert outside a lesson.
    private func reportTutorialLog(before: SquareSheetContent.ChildCount, amount: CountValue) {
        guard let coach = tutorialCoach else { return }
        let after = before.current + amount
        coach.reportLog(
            summary: "\(formatCount(after, kind: before.kind)) of \(formatCount(before.goal, kind: before.kind))",
            finishedSquare: before.goal > 0 && after >= before.goal
        )
        coach.handle(.countLogged)
    }
}

// MARK: - Getting Started hooks

/// Closes the square sheet when the running lesson's step asks for it (the
/// lesson-3 hold-menu step follows the sheet's Undo-strip step) or when a
/// Bingo / Greenlog moment opens behind it (a finale log from the sheet).
/// Inert outside a lesson.
struct TutorialSheetCloser: ViewModifier {
    @Environment(\.tutorialSignals) private var signals
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .onChange(of: signals.closesSquareSheet) { _, closes in
                if closes { dismiss() }
            }
            .onChange(of: signals.momentOpen) { _, open in
                if open { dismiss() }
            }
    }
}
