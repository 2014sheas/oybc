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

    /// Per-template "needs attention" reason, keyed by template id.
    /// Recomputed on every reload by resolving each template's
    /// `seedTaskIds` against the user's live task library and running
    /// `validateSpawnPool`. iOS twin of web's `attentionByTemplateId`
    /// (`RecurringTemplatesPage.tsx`): a seed id that no longer resolves
    /// in the library is treated as `hasDeletedTasks` (soft-delete is the
    /// only realistic cause, since the form can't add unknown ids),
    /// otherwise the validation failure reason is surfaced. Absent key ⇒
    /// healthy, no badge.
    var attentionByTemplateId: [String: SpawnPoolFailureReason] = [:]

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
            // Resolve pools against the live library (non-deleted tasks
            // only) to compute per-template attention state — see the
            // `attentionByTemplateId` doc.
            let liveTasks = try database.fetchTasks(userId: userId)
            let attention = Self.computeAttention(templates: result, liveTasks: liveTasks)
            await MainActor.run {
                guard mySeq == latestSeq else { return }
                self.templates = result
                self.attentionByTemplateId = attention
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                guard mySeq == latestSeq else { return }
                self.loadError = "Failed to load recurring templates: \(error.localizedDescription)"
                self.templates = []
                self.attentionByTemplateId = [:]
            }
        }
    }

    /// Pure attention-map computation. Extracted (and `static`) so unit
    /// tests can exercise it directly without a database. Strict mirror
    /// of web's `attentionByTemplateId` memo in `RecurringTemplatesPage`.
    ///
    /// - Parameters:
    ///   - templates: The user's non-deleted templates.
    ///   - liveTasks: The user's non-deleted task library.
    /// - Returns: template id → failure reason (absent ⇒ healthy).
    static func computeAttention(
        templates: [RecurringBoardTemplate],
        liveTasks: [Task]
    ) -> [String: SpawnPoolFailureReason] {
        let taskMap = Dictionary(liveTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [String: SpawnPoolFailureReason] = [:]
        for template in templates {
            var pool: [Task] = []
            var hasMissingFromLibrary = false
            for id in template.seedTaskIds {
                if let found = taskMap[id] { pool.append(found) } else { hasMissingFromLibrary = true }
            }
            if hasMissingFromLibrary {
                out[template.id] = .hasDeletedTasks
                continue
            }
            if case .failure(let reason) = validateSpawnPool(template: template, poolTasks: pool) {
                out[template.id] = reason
            }
        }
        return out
    }

    func reloadAsync(userId: String) {
        _Concurrency.Task { await reload(userId: userId) }
    }
}
