import Foundation
import GRDB

/// Sync-queue ownership helpers for the pull path (docs/GUEST_MODE.md
/// §Collision). Split out of `SyncService.swift`, which is at its
/// `scripts/audit/file-size-allowlist.json` cap.
extension SyncService {

    /// Enqueue the board-stats UPDATE a pull cascade produces, stamped with
    /// the uid the PULL runs for — never the live auth uid, which can flip
    /// mid-pull during the guest-collision switch (an anon snapshot applied
    /// after the switch must stay anon-owned so the real account's push drops
    /// it). Raw SQL, no coalescing — the exact write shape the three pull
    /// cascades (`runPullCascade`, `…ForBoardTask`, `…ForTasks`) always used;
    /// only the `ownerUid` column is new.
    ///
    /// - Parameters:
    ///   - db: The pull's open write transaction.
    ///   - boardId: The recomputed board.
    ///   - payload: The board's JSON-encoded full snapshot.
    ///   - now: ISO8601 enqueue timestamp.
    ///   - ownerUid: The uid the pull is running for.
    /// - Throws: A GRDB error if the insert fails (rolls back the pull).
    static func insertPullCascadeBoardSync(
        db: Database,
        boardId: String,
        payload: String,
        now: String,
        ownerUid: String
    ) throws {
        try db.execute(sql: """
            INSERT INTO sync_queue
                (id, entityType, entityId, operationType, payload, status, retryCount, createdAt, priority, ownerUid)
            VALUES (?, 'boards', ?, 'update', ?, 'pending', 0, ?, 0, ?)
            """, arguments: [UUID().uuidString, boardId, payload, now, ownerUid])
    }
}
