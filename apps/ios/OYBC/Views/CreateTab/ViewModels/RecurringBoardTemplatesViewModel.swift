import Foundation
import Observation

/// Owns the user's non-deleted recurring board templates. iOS twin of
/// the web `useRecurringBoardTemplates` hook (Phase 6.2b).
///
/// Loading is imperative — the view calls `reloadAsync(userId:)` on
/// appear and after any save/delete from the form. Mirrors the pattern
/// used by `ParentBoardTasksViewModel`.
@Observable
final class RecurringBoardTemplatesViewModel {

    // MARK: - State

    var templates: [RecurringBoardTemplate] = []
    var loadError: String?

    // MARK: - Race-condition guard
    //
    // Mirrors `ParentBoardTasksViewModel`: increments on every reload,
    // commits only if no newer reload has started in the meantime.
    @ObservationIgnored private var latestSeq: UInt64 = 0

    // MARK: - DB injection

    /// Injected for tests; defaults to the production singleton.
    @ObservationIgnored private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Loading

    func reload(userId: String) async {
        let mySeq = await MainActor.run { () -> UInt64 in
            latestSeq &+= 1
            return latestSeq
        }

        do {
            let result = try database.fetchRecurringBoardTemplates(userId: userId)
            await MainActor.run {
                guard mySeq == latestSeq else { return }
                self.templates = result
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                guard mySeq == latestSeq else { return }
                self.loadError = "Failed to load recurring templates: \(error.localizedDescription)"
                self.templates = []
            }
        }
    }

    func reloadAsync(userId: String) {
        _Concurrency.Task { await reload(userId: userId) }
    }
}
