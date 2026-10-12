import Foundation
import SwiftUI

// MARK: - MomentReplayClock

/// The moment overlay's ONE clock: a single `beat` ticking at a fixed cadence
/// (175 ms for a bingo, 120 ms for a greenlog) from 0 up to the replay's
/// final beat, then holding. Beat 0 (the empty board) holds exactly one
/// cadence, like web. Every cell's visual is derived from the beat by
/// `momentCellVisual`, so a SwiftUI re-render never restarts a pop. Runs once
/// per overlay open.
@MainActor
final class MomentReplayClock: ObservableObject {
    /// Seconds per beat for each kind (handoff §Replay cadence).
    static func cadence(for kind: MomentTrigger.Kind) -> TimeInterval {
        kind == .bingo ? 0.175 : 0.120
    }

    @Published private(set) var beat: Int = 0
    private var timer: Timer?
    private var started = false

    /// Starts ticking. A second call is a no-op — the replay runs once per open.
    func start(finalBeat: Int, kind: MomentTrigger.Kind) {
        guard !started, finalBeat > 0 else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: Self.cadence(for: kind), repeats: true) { [weak self] t in
            // Fires on the main run loop.
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                self.beat += 1
                if self.beat >= finalBeat { t.invalidate() }
            }
        }
    }

    /// Stops the clock (the overlay disappeared).
    func stop() { timer?.invalidate() }
}
