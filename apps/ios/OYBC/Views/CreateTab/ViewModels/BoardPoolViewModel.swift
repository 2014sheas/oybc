import Foundation
import Observation

/// An entry in the Create-tab board-task pool. Mirrors the web
/// `PoolEntry` shape (`{ taskId, title, type }`) so cross-platform
/// logic stays aligned.
struct BoardPoolEntry: Equatable, Hashable {
    let taskId: String
    let title: String
    let type: String
}

/// Owns the board-task pool for the Create tab: the ordered list of
/// tasks queued for board creation plus add/remove/membership helpers.
///
/// Duplicate adds are silently ignored (by `taskId`) so rapid taps on
/// the add button don't produce duplicate rows. Mirrors web's
/// `useBoardPool` hook.
///
/// Uses `@Observable` (iOS 17+, Observation framework) so SwiftUI
/// views can bind to `pool` without the `ObservableObject` +
/// `@Published` boilerplate.
@Observable
final class BoardPoolViewModel {
    /// The ordered pool of tasks queued for board creation.
    var pool: [BoardPoolEntry] = []

    /// Inserts `entry` if a task with the same `taskId` isn't already
    /// present. Returns silently otherwise.
    func addToPool(taskId: String, title: String, type: String) {
        guard !pool.contains(where: { $0.taskId == taskId }) else { return }
        pool.append(BoardPoolEntry(taskId: taskId, title: title, type: type))
    }

    /// Removes every entry matching `taskId`. Safe to call when absent.
    func removeFromPool(taskId: String) {
        pool.removeAll { $0.taskId == taskId }
    }

    /// Returns `true` if a task with the given id is currently in the pool.
    func isInPool(taskId: String) -> Bool {
        pool.contains(where: { $0.taskId == taskId })
    }

    /// Empties the pool. Used by the "Clear Pool" button.
    func clearPool() {
        pool.removeAll()
    }
}
