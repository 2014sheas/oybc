import Foundation
import SwiftUI
import UIKit

// MARK: - BoardPlayView + closed-board late log (Board Edit redesign slice 4)
//
// Split out of `BoardPlayView.swift` (frozen file-size cap — a
// ROADMAP-B6-style extraction, not a cap bump) alongside `+Header.swift` /
// `+EditCommit.swift`. Builds the `LateLogSheetView` for whatever square was
// tapped on a CLOSED board (`lateLogTarget`, routed from `risoPlaySquare`'s
// `onTap`) and wires its actions into `BoardPlayViewModel+LateLog.swift`.
extension BoardPlayView {

    /// D15: whether a CLOSED board's square for `task` routes to the
    /// late-log sheet (NORMAL / plain-or-source COUNTING /
    /// window-stamped-derived COUNTING / COMPOUND) rather than staying
    /// interaction-locked (a hub-linked derived counter / ACHIEVEMENT — OQ2).
    func isLateLogRoutable(task: Task?) -> Bool {
        guard isBoardLocked, let t = task else { return false }
        if t.type == .compound { return true }
        return viewModel.lateLogEventOwningTaskId(for: t) != nil
    }

    /// The three-card stat bar, with the sealed ENDED card (existing) and
    /// D14's ended-not-sealed "still logging" card.
    @ViewBuilder
    var statBarSection: some View {
        if let b = board {
            RisoStatBar(
                completedTasks: b.completedTasks,
                totalTasks: b.totalTasks,
                linesCompleted: b.linesCompleted,
                expiryText: risoExpiryText(board: b),
                endedText: isSealed ? risoEndedText(board: b) : nil,
                endedStillLoggingDate: (isEnded && !isSealed) ? risoEndedText(board: b) : nil
            )
            .padding(.horizontal, Riso.gutter)
            .padding(.top, 14)
            .padding(.bottom, 13)
        }
    }

    /// D14 (ended, not closed) + the closed permanent-record line (OQ6),
    /// below the grid.
    @ViewBuilder
    var endedClosedBanners: some View {
        if let b = board, isEnded, !isSealed {
            RisoEndedBannerView(date: risoEndedText(board: b))
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 8)
        }
        if isBoardLocked {
            Text("Board closed — a permanent record")
                .font(.risoBody(12, .semibold))
                .foregroundStyle(Color.risoRed)
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 8)
        }
    }

    /// D15 tap handler for a CLOSED square: opens the late-log sheet for
    /// `task` when routable, else a silent no-op (a hub-linked derived
    /// counter / ACHIEVEMENT).
    func routeLateLogTap(routable: Bool, boardTask: BoardTask, task: Task?) {
        guard routable, let t = task else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        lateLogErrorMessage = nil
        lateLogTarget = LateLogSheetItem(id: boardTask.id, boardTaskId: boardTask.id, task: t)
    }

    /// "Sep 1 – 30" — the closed board's window label.
    var closedBoardWindowLabel: String {
        guard let b = board else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        guard let start = parseISO8601Date(b.startDate) else { return "" }
        f.dateFormat = "MMM d"
        let startText = f.string(from: start)
        guard let endStr = b.endDate, let end = parseISO8601Date(endStr) else { return startText }
        let cal = Calendar.current
        if cal.isDate(start, equalTo: end, toGranularity: .month) {
            f.dateFormat = "d"
            return "\(startText) – \(f.string(from: end))"
        }
        f.dateFormat = "MMM d"
        return "\(startText) – \(f.string(from: end))"
    }

    /// Builds the late-log sheet's content for `item` (Board Edit redesign
    /// slice 4, D7/D15).
    @ViewBuilder
    func lateLogSheet(for item: LateLogSheetItem) -> some View {
        let task = item.task
        switch task.type {
        case .normal:
            LateLogSheetView(
                windowLabel: closedBoardWindowLabel,
                taskTitle: task.title,
                kind: .normal,
                isUndoable: viewModel.hasClosedBoardLateLog(for: task),
                onMarkDone: { await runLateLogCompletion(taskId: task.id) },
                onUndo: { await runLateLogUndo(task: task) },
                errorMessage: lateLogErrorMessage
            )

        case .counting:
            let current: CountValue = {
                guard task.sharedCounterId != nil else { return viewModel.windowedState(of: task).count }
                return resolveLinkedCounterDisplay(
                    task: task, eventsByTaskId: viewModel.windowEventsByTaskId, sealedAt: board?.sealedAt,
                    window: board.map(LinkedCounterWindow.init(board:))
                ).displayed
            }()
            LateLogSheetView(
                windowLabel: closedBoardWindowLabel,
                taskTitle: task.title,
                kind: .counting(current: current, max: task.maxCount ?? 0, unit: task.unit ?? "", countKind: resolveFamilyCountKind(task, lookup: { viewModel.taskMap[$0] })),
                isUndoable: viewModel.hasClosedBoardLateLog(for: task),
                onUndo: { await runLateLogUndo(task: task) },
                onLogAmount: { amount in await runLateLogIncrement(task: task, delta: amount) },
                errorMessage: lateLogErrorMessage
            )

        case .compound:
            let children = viewModel.compoundChildrenByCompound[task.id] ?? []
            let parts: [LateLogCompoundPart] = children.compactMap { link in
                guard let child = viewModel.taskMap[link.childTaskId], !child.isDeleted else { return nil }
                let isStageable = child.type == .normal || (child.type == .counting && child.sharedCounterId == nil)
                let alreadyDone: Bool = {
                    if child.type == .compound {
                        return CompoundEvaluation.evaluate(
                            compound: child, childrenByCompound: viewModel.compoundChildrenByCompound,
                            taskById: viewModel.taskMap, windowContext: viewModel.compoundWindowContext
                        )
                    }
                    if child.sharedCounterId != nil {
                        return resolveLinkedCounterDisplay(
                            task: child, eventsByTaskId: viewModel.windowEventsByTaskId, sealedAt: board?.sealedAt,
                            window: board.map(LinkedCounterWindow.init(board:))
                        ).isCompleted
                    }
                    return viewModel.windowedState(of: child).isCompleted
                }()
                return LateLogCompoundPart(id: child.id, title: child.title, isStageable: isStageable, alreadyDone: alreadyDone)
            }
            LateLogSheetView(
                windowLabel: closedBoardWindowLabel,
                taskTitle: task.title,
                kind: .compound(parts: parts),
                onCommitCompound: { childIds in await runLateLogCompound(compoundTaskId: task.id, childIds: childIds) },
                canCommitCompound: { staged in
                    viewModel.wouldLateLogCompoundRuleBeMet(compoundTaskId: task.id, childTaskIds: staged)
                },
                errorMessage: lateLogErrorMessage
            )

        case .achievement:
            EmptyView() // never routed here — defensive fallback
        }
    }

    // MARK: - Actions

    // Each action is `async` and awaited by `LateLogSheetView.perform`, which
    // holds the sheet's `isBusy` (all buttons disabled) until it returns.

    private func runLateLogCompletion(taskId: String) async {
        do {
            try await viewModel.commitLateLogCompletion(taskId: taskId)
            lateLogTarget = nil
        } catch {
            lateLogErrorMessage = "Couldn't log it — please try again."
        }
    }

    /// Passes the TAPPED (placed) task — the VM hands the DB the placed id
    /// (F1: the pre-resolved root is never placed → `taskNotPlaced`).
    private func runLateLogIncrement(task: Task, delta: CountValue) async {
        do {
            try await viewModel.commitLateLogIncrement(for: task, delta: delta)
            lateLogErrorMessage = nil
        } catch {
            lateLogErrorMessage = "Couldn't log it — please try again."
        }
    }

    private func runLateLogCompound(compoundTaskId: String, childIds: [String]) async {
        do {
            try await viewModel.commitLateLogCompoundParts(compoundTaskId: compoundTaskId, childTaskIds: childIds)
            lateLogTarget = nil
        } catch let error as LateLogError where error == .ruleNotMet {
            lateLogErrorMessage = "Not all parts are done yet."
        } catch {
            lateLogErrorMessage = "Couldn't log it — please try again."
        }
    }

    /// Undo for a tapped square — the VM resolves the event-owning
    /// id (the ROOT for a window-stamped derived row).
    private func runLateLogUndo(task: Task) async {
        do {
            try await viewModel.undoLateLog(for: task)
            lateLogTarget = nil
        } catch {
            lateLogErrorMessage = "Couldn't undo — please try again."
        }
    }
}
