import Foundation
import Observation

/// Drives Phase 6.2 spawn detection + execution. Mounted by
/// `BoardListView`; runs on the Boards tab's `.onAppear` alongside
/// `PendingRecurringBoardsViewModel`. Mirror of the web
/// `useRecurringBoardSpawn` hook.
///
/// Spawning is structurally idempotent — `findTemplatesPendingSpawn`
/// filters out templates whose `lastSpawnedWindowKey` matches the
/// current window AND whose existing-board lookup hits. Repeated tab
/// appears after the first spawn are no-ops.
///
/// `attentionByTemplateId` is exposed for potential surfacing on
/// the Boards-tab UI; currently only the Create-tab template list
/// consumes its own synchronous validation against the library, so
/// this VM's failure map is mostly diagnostic.
@Observable
final class RecurringBoardSpawnViewModel {

    // MARK: - State

    /// Templates that successfully spawned a board in the most recent pass.
    var succeededTemplateIds: [String] = []

    /// Templates whose spawn was skipped, keyed by template id.
    var attentionByTemplateId: [String: SpawnPoolFailureReason] = [:]

    /// Most recent unhandled error during the spawn pass. Logged via
    /// `print` in `runSpawnPass` and surfaced here for completeness.
    var loadError: String?

    // MARK: - Race-condition guard

    @ObservationIgnored private var latestSeq: UInt64 = 0
    @ObservationIgnored private var inFlight: Bool = false

    // MARK: - Pass

    /// Runs one spawn pass. Reads the user's templates + boards + prefs,
    /// computes pending spawns via `findTemplatesPendingSpawn`, then
    /// executes each via `RecurringBoardSpawn.spawnTemplateBoard`.
    func runSpawnPass(userId: String, weekStartDay: WeekStartDay) async {
        let mySeq = await MainActor.run { () -> UInt64 in
            latestSeq &+= 1
            return latestSeq
        }

        // Re-entrancy guard: skip if a previous pass is still mid-flight.
        let alreadyRunning = await MainActor.run { () -> Bool in
            if inFlight { return true }
            inFlight = true
            return false
        }
        if alreadyRunning { return }
        defer {
            _Concurrency.Task { @MainActor in inFlight = false }
        }

        do {
            let templates = try AppDatabase.shared.fetchRecurringBoardTemplates(userId: userId)
            let boards = try AppDatabase.shared.fetchBoards(userId: userId)

            let pending = findTemplatesPendingSpawn(
                templates: templates,
                boards: boards,
                weekStartDay: weekStartDay.rawValue,
                now: Date()
            )

            if pending.isEmpty {
                await MainActor.run {
                    guard mySeq == latestSeq else { return }
                    succeededTemplateIds = []
                    attentionByTemplateId = [:]
                    loadError = nil
                }
                return
            }

            var succeeded: [String] = []
            var attention: [String: SpawnPoolFailureReason] = [:]
            for spawn in pending {
                do {
                    let outcome = try RecurringBoardSpawn.spawnTemplateBoard(spawn)
                    switch outcome {
                    case .spawned(_, let templateId, _):
                        succeeded.append(templateId)
                    case .skipped(let templateId, let reason):
                        attention[templateId] = reason
                    }
                } catch {
                    print("[recurring-spawn] failed for template \(spawn.template.id): \(error)")
                    attention[spawn.template.id] = .spawnFailed
                }
            }

            await MainActor.run {
                guard mySeq == latestSeq else { return }
                succeededTemplateIds = succeeded
                attentionByTemplateId = attention
                loadError = nil
            }
        } catch {
            await MainActor.run {
                guard mySeq == latestSeq else { return }
                loadError = "Spawn pass failed: \(error.localizedDescription)"
            }
        }
    }

    /// Sync shim for view-side fire-and-forget callers (`.onAppear`).
    func runSpawnPassAsync(userId: String, weekStartDay: WeekStartDay) {
        _Concurrency.Task { await runSpawnPass(userId: userId, weekStartDay: weekStartDay) }
    }
}
