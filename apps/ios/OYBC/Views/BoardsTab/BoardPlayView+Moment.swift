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
            .id(m.kind == .bingo ? 0 : 1) // an upgrade to greenlog restarts the replay
            .ignoresSafeArea()
            .transition(.opacity)
            .zIndex(20)
        }
    }

    /// Queues the moment for a write's `MomentTrigger` (greenlog > bingo, set by
    /// the view model's outcome ladder — never inferred from message text).
    /// It opens once `MomentGate` says the post-write reload applied (or the
    /// timeout passes); triggers arriving meanwhile coalesce, greenlog winning.
    func triggerMoment(_ trigger: MomentTrigger) {
        guard let b = board else { return }
        // The greenlog streak (core boards) computes while the gate waits.
        if trigger.kind == .greenlog { refreshGreenlogStreak() }
        if let p = momentPending {
            momentPending?.trigger = MomentGate.coalesce(p.trigger, trigger)
            return
        }
        momentPending = MomentPending(trigger: trigger, boardId: b.id, applyCount: viewModel.applyCount, start: Date())
        pollMoment()
    }

    private func pollMoment() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let p = momentPending else { return }
            let ready = MomentGate.isReady(
                p.trigger, boardId: p.boardId, board: viewModel.board,
                applyCount: viewModel.applyCount, applyCountAtTrigger: p.applyCount
            )
            guard MomentGate.shouldOpen(elapsed: Date().timeIntervalSince(p.start), ready: ready) else {
                pollMoment()
                return
            }
            momentPending = nil
            guard viewModel.board?.id == p.boardId,
                  MomentGate.shouldReplace(open: moment?.kind, new: p.trigger.kind),
                  let replay = viewModel.momentReplay() else { return }
            let presentation = MomentPresentation(
                kind: p.trigger.kind, replay: replay, cells: viewModel.momentCellInputs(replay: replay)
            )
            withAnimation(.easeIn(duration: 0.3)) { moment = presentation }
        }
    }
}
