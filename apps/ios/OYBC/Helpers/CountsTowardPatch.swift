import Foundation

/// A task editor's staged change to what a task counts toward
/// (docs/SHARED_COUNTER_SETTINGS.md §3, PR 4) — carried by
/// `EditTaskSheet.Patch` / `SquareEditTaskSheet.Patch` ONLY when the
/// selection or amount differs from the stored row (nil patch = untouched).
/// `counterId == nil` clears the flag.
struct CountsTowardPatch: Equatable {
    let counterId: String?
    let amount: Int?
}
