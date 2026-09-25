import Foundation
import GRDB

// MARK: - Recurring board spawn — Phase 6.2 orchestration
//
// Atomically creates a Board + BoardTasks from a `PendingTemplateSpawn`
// and updates the template's `lastSpawnedWindowKey` in the same GRDB
// transaction. If the multi-step write fails partway, the entire
// transaction rolls back — the next Boards-tab open will retry.
//
// Mirrors the wizard's `BoardWizardPersist.swift` JSON-dict construction
// pattern (Board has no memberwise init, so we round-trip through
// JSONDecoder). Web twin: `apps/web/src/db/operations/recurringBoardSpawn.ts`.

/// Single-spawn outcome. `reason` is `SpawnAttentionReason` (the wider
/// driver-level union) so it can carry the driver-only outcomes
/// (`noPoolTasksResolved`, `spawnFailed`) that are not part of the
/// pure-validation `SpawnPoolFailureReason` contract.
enum RecurringSpawnOutcome {
    /// `noBoardForWindowSourceIds`: board-kind sources that resolved to NO
    /// board for this window (owner ruling 2026-09-24 — a series with no
    /// instance open now, or an ended/sealed one-off).
    /// They dealt nothing; the board's spawn-provenance note says
    /// "No board for this window yet". Web twin: the same field on
    /// `SpawnResult`.
    case spawned(
        boardId: String,
        templateId: String,
        windowStart: String,
        noBoardForWindowSourceIds: [String] = []
    )
    case skipped(templateId: String, reason: SpawnAttentionReason)
}

enum RecurringBoardSpawn {

    /// Spawn a single board from the pending-spawn descriptor. Returns
    /// `.spawned(...)` on success or `.skipped(...)` with a failure reason
    /// to surface as a "needs attention" indicator on the template row.
    ///
    /// Throws on infrastructure errors (GRDB exceptions, JSON encoding
    /// failures); validation failures are non-throwing skip outcomes.
    ///
    /// The atomic write transaction — task resolution, pool validation,
    /// placement, and the Board + BoardTask + template writes (all
    /// sync-enqueued) — is owned by `AppDatabase.spawnRecurringBoard`. Folding
    /// the read inside that write block closes the soft-delete race. This
    /// service only mints the `boardId` / `now` and delegates.
    ///
    /// - Parameters:
    ///   - database: the database to spawn into (defaults to `.shared`; the
    ///     wizard persist path passes its injected database).
    ///   - sourceClock: the instant a board source's "has this board ended"
    ///     is judged against (owner ruling 2026-09-24). Defaults to now.
    static func spawnTemplateBoard(
        _ spawn: PendingTemplateSpawn,
        database: AppDatabase = .shared,
        sourceClock: Date = AppDatabase.sourceClock()
    ) throws -> RecurringSpawnOutcome {
        let boardId = AppDatabase.generateUUID()
        let now = AppDatabase.currentTimestamp()
        return try database.spawnRecurringBoard(
            spawn, boardId: boardId, now: now, sourceClock: sourceClock
        )
    }
}
