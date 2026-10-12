import SwiftUI

// MARK: - MomentPresentation

/// What the open Bingo / Greenlog moment replays: the kind, the replay kernel
/// output and one end-state face per grid slot, captured when it opens.
struct MomentPresentation: Equatable {
    let kind: MomentTrigger.Kind
    let replay: BoardMomentReplay
    let cells: [MomentCellInput]
}

// MARK: - Start-a-new-board intent

extension Notification.Name {
    /// Posted by the greenlog moment's "Start a new board"; `MainTabView`
    /// flips to the Create tab (web twin: navigate to `/create`).
    static let momentStartNewBoard = Notification.Name("oybc.moment.startNewBoard")
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
                    NotificationCenter.default.post(name: .momentStartNewBoard, object: nil)
                }
            )
            .ignoresSafeArea()
            .transition(.opacity)
            .zIndex(20)
        }
    }

    /// Opens the moment for a write's `MomentTrigger` (greenlog > bingo, set by
    /// the view model's outcome ladder — never inferred from message text).
    /// Waits ~0.52 s so the cell pop finishes first, and reads the replay AFTER
    /// the write's reload has landed. A moment already open is left alone.
    func triggerMoment(_ trigger: MomentTrigger) {
        // The greenlog streak (core boards) computes while the delay elapses.
        if trigger.kind == .greenlog { refreshGreenlogStreak() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
            guard moment == nil, let replay = viewModel.momentReplay() else { return }
            let presentation = MomentPresentation(
                kind: trigger.kind, replay: replay, cells: viewModel.momentCellInputs(replay: replay)
            )
            withAnimation(.easeIn(duration: 0.3)) { moment = presentation }
        }
    }
}
