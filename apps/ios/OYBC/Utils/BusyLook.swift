import Combine
import Foundation

/// The busy LOOK of a write in flight (owner ruling, TASK_DETAIL_REDESIGN decision 6
/// amended 2026-10-18): controls turn non-interactive the moment a write starts (the
/// re-entrancy guard is unchanged), but the dimmed look (45% opacity, collapsed hard
/// shadow) appears only when the write is still in flight after `delay` — a fast write
/// never flashes the dim. Web twin: `BUSY_LOOK_DELAY_MS` in `hooks/useBusyLook.ts`.
enum BusyLook {
    /// Seconds a write must stay in flight before the dimmed look shows.
    static let delay: TimeInterval = 0.25
}

extension Publisher where Output == Bool, Failure == Never {
    /// `true` only once the source has stayed `true` for `delay`; `false` immediately.
    /// A source that flips back inside the window never emits `true` at all.
    ///
    /// - Parameter delay: Seconds the source must stay `true` (default `BusyLook.delay`).
    func delayedBusyLook(after delay: TimeInterval = BusyLook.delay) -> AnyPublisher<Bool, Never> {
        map { busy -> AnyPublisher<Bool, Never> in
            busy
                ? Just(true).delay(for: .seconds(delay), scheduler: DispatchQueue.main).eraseToAnyPublisher()
                : Just(false).eraseToAnyPublisher()
        }
        .switchToLatest()
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}
