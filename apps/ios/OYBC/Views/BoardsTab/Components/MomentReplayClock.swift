import Foundation
import SwiftUI

// MARK: - MomentReplayClock

/// The moment overlay's ONE clock: a single `beat` ticking at a fixed cadence
/// (175 ms for a bingo, 120 ms for a greenlog) from 0 up to the replay's
/// final beat, then holding. Every cell's visual is derived from the beat by
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

    /// Starts ticking after `startDelay` (the empty board holds first).
    /// A second call is a no-op — the replay runs once per open.
    func start(finalBeat: Int, kind: MomentTrigger.Kind, startDelay: TimeInterval = 0.45) {
        guard !started, finalBeat > 0 else { return }
        started = true
        let interval = Self.cadence(for: kind)
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay) { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
                _Concurrency.Task { @MainActor in
                    guard let self else { t.invalidate(); return }
                    self.beat += 1
                    if self.beat >= finalBeat { t.invalidate() }
                }
            }
        }
    }

    deinit { timer?.invalidate() }
}
