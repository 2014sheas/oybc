import SwiftUI

// MARK: - MomentPresentation

/// What the open Bingo / Greenlog moment replays: the kind, the replay kernel
/// output and one end-state face per grid slot, captured when it opens.
struct MomentPresentation: Equatable {
    let kind: MomentTrigger.Kind
    let replay: BoardMomentReplay
    let cells: [MomentCellInput]
}

/// A trigger waiting for the post-write reload to apply (see `MomentGate`).
struct MomentPending: Equatable {
    /// Identifies this pending's poll chain — a stale chain exits.
    let id = UUID()
    var trigger: MomentTrigger
    /// The board the write happened on — a pager swipe must not replay another.
    let boardId: String
    /// `viewModel.applyCount` when the trigger fired.
    let applyCount: Int
    let start: Date
}

// MARK: - BoardPlayView + moment

extension BoardPlayView {

    /// The full-bleed moment overlay (z 20), or nothing while none is open.
    /// "Back to board" is the only way out — the field is opaque and a tap on
    /// it does nothing.
    @ViewBuilder
    var momentOverlayLayer: some View {
        if let m = moment, let b = board {
            RisoMomentOverlay(
                kind: m.kind, replay: m.replay, cells: m.cells,
                boardName: b.name, linesCompleted: b.linesCompleted,
                streak: greenlogStreakCount, timeframe: b.timeframe, isCore: b.isCore,
                onShare: { showShareBoardSheet = true },
                onBack: {
                    withAnimation(.easeOut(duration: 0.25)) { moment = nil }
                },
                onNewBoard: {
                    withAnimation(.easeOut(duration: 0.25)) { moment = nil }
                    MomentIntent.startNewBoard()
                }
            )
            // The field bleeds edge to edge on its own (`field.ignoresSafeArea()`
            // inside); the content keeps the safe-area insets so the kicker
            // clears the status bar. The tab bar steps aside for the moment —
            // its buttons sit above the home indicator, not behind the bar.
            .toolbar(.hidden, for: .tabBar)
            .transition(.opacity)
            .zIndex(20)
        }
    }

    /// The share sheet for the open moment: its kind, the frozen replay's
    /// numbers and end-state cells (`momentPosterCells`) and the kind's own streak.
    @ViewBuilder
    var shareSheetContent: some View {
        if let b = board, let m = moment {
            let inputs = m.cells.map {
                PosterCellInput(idx: $0.idx, label: $0.title, type: $0.taskType, isFree: $0.slot == .free)
            }
            ShareBoardSheet(
                content: BoardShareContent(
                    kind: m.kind, boardName: b.name, completedTasks: m.replay.completedTasks,
                    totalTasks: m.replay.totalTasks, linesCompleted: m.replay.lineClosureBeat.count, boardSize: b.boardSize,
                    streak: m.kind == .bingo ? bingoStreakCount : greenlogStreakCount,
                    timeframe: b.timeframe, isCore: b.isCore
                ),
                cells: momentPosterCells(replay: m.replay, cells: inputs, kind: m.kind),
                boardId: b.id,
                onDismiss: { showShareBoardSheet = false }
            )
            .presentationDetents([.medium, .large])
        }
    }

    /// Queues the moment for a write's `MomentTrigger` (greenlog > bingo, set by
    /// the view model's outcome ladder — never inferred from message text).
    /// It opens once `MomentGate` says the post-write reload applied (or the
    /// timeout passes); triggers arriving meanwhile coalesce, greenlog winning.
    func triggerMoment(_ trigger: MomentTrigger, applyCount: Int) {
        guard let b = board else { return }
        // The streaks (core boards) compute while the gate waits.
        refreshStreaks()
        if let p = momentPending {
            momentPending?.trigger = MomentGate.coalesce(pending: p.trigger, arriving: trigger)
            return
        }
        let pending = MomentPending(trigger: trigger, boardId: b.id, applyCount: applyCount, start: Date())
        momentPending = pending
        pollMoment(chain: pending.id)
    }

    private func pollMoment(chain: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard MomentGate.isLive(chain: chain, pending: momentPending), let p = momentPending else { return }
            let ready = MomentGate.isReady(
                p.trigger, boardId: p.boardId, board: viewModel.board,
                applyCount: viewModel.applyCount, applyCountAtTrigger: p.applyCount
            )
            guard MomentGate.shouldOpen(elapsed: Date().timeIntervalSince(p.start), ready: ready) else {
                pollMoment(chain: chain)
                return
            }
            momentPending = nil
            guard viewModel.board?.id == p.boardId,
                  MomentGate.shouldOpen(whileOpen: moment?.kind),
                  let replay = viewModel.momentReplay() else { return }
            let presentation = MomentPresentation(
                kind: p.trigger.kind, replay: replay, cells: viewModel.momentCellInputs(replay: replay)
            )
            withAnimation(.easeIn(duration: 0.3)) { moment = presentation }
        }
    }
}
