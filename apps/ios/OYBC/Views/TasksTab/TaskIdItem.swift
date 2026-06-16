import Foundation

/// `TaskIdItem` — lightweight `Identifiable` + `Hashable` wrapper for a task
/// ID string. Used wherever `.sheet(item:)` or `navigationDestination(item:)`
/// needs an `Identifiable` trigger but the caller only has a plain `String`.
///
/// Shared across tabs (Boards play, Create wizard, Tasks detail). Extracted to
/// its own file when the legacy `TaskDetailContentView` was retired.
struct TaskIdItem: Identifiable, Hashable {
    let id: String
}
