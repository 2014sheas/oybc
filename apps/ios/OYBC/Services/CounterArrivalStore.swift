import Foundation

/// Device-local last-seen snapshot store for the Shared Counters P3 arrival
/// banner.
///
/// Persists a per-board `taskId → displayed` map in `UserDefaults`. This is
/// deliberately NOT synced schema — the arrival banner is a "since you last
/// looked at THIS board on THIS device" signal, so it lives outside the
/// board/task records that round-trip through Firestore. Mirrors the web
/// `counterArrivalStore.ts` (`localStorage`); both platforms key the entry by
/// the board id.
///
/// House style follows `TutorialProgressStore` — `UserDefaults`-backed with an
/// injectable `defaults` so unit tests can pass an isolated suite. Unlike that
/// store this is a plain value-less service (no `@Published`): the arrival VM
/// reads/writes it directly, nothing observes it.
final class CounterArrivalStore {

    private let defaults: UserDefaults

    /// - Parameter defaults: Injected for tests; defaults to `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(boardId: String) -> String {
        "counterArrivals.lastSeen.\(boardId)"
    }

    /// The last-seen snapshot for a board.
    ///
    /// - Parameter boardId: The board whose snapshot to read.
    /// - Returns: `taskId → displayed` map; `[:]` when absent or malformed (an
    ///   absent entry is a first view — never an arrival).
    func lastSeen(boardId: String) -> [String: Int] {
        guard let data = defaults.data(forKey: key(boardId: boardId)),
              let map = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return map
    }

    /// Persist the last-seen snapshot for a board.
    ///
    /// - Parameters:
    ///   - boardId: The board whose snapshot to write.
    ///   - snapshot: `taskId → displayed` map (from `snapshotCounterSquares`).
    func save(boardId: String, snapshot: [String: Int]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key(boardId: boardId))
    }
}
