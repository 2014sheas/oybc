import Foundation
import GRDB

/// BoardTask - Placement record linking a board to a task at a grid position.
///
/// Matches TypeScript BoardTask interface from @oybc/shared.
///
/// Under the unified compound model + Phase 6.3 refactor, BoardTask is
/// a PURE placement record. No completion state — that lives globally on
/// Task. No achievement-square config — Phase 6.3 moved those fields onto
/// `Task` as `TaskType.achievement` with `referencedBoardId` /
/// `referencedTemplateId`. BoardTask just records where a task sits in a
/// board's grid.
///
/// Board-integrity PR-1 (tombstones, docs/BOARD_INTEGRITY.md): `isDeleted` /
/// `deletedAt` were added so placement removal is a SOFT delete, matching
/// every other synced collection (Board, Task, CompoundChild, …). Previously
/// BoardTask was the only synced collection without a tombstone — deletion
/// was represented by a literal SQL DELETE, which the sync layer can't
/// express as a Firestore write (deletes are always "push a doc with
/// isDeleted:true", never `deleteDoc`). A hard-deleted local row leaves
/// nothing for the push loop to diff a higher version against, so an
/// already-synced remote row could win the next pull and resurrect the
/// placement. See `AppDatabase+BoardTasks.removeBoardTaskFromBoard` for the
/// write-side fix.
struct BoardTask: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var boardId: String
    var taskId: String

    // Grid position
    var row: Int
    var col: Int
    var isCenter: Bool

    // Timestamps
    var createdAt: String // ISO8601
    var updatedAt: String // ISO8601

    // Sync metadata
    var lastSyncedAt: String? // ISO8601
    var version: Int
    var isDeleted: Bool
    var deletedAt: String? // ISO8601

    // MARK: - Database Configuration

    static let databaseTableName = "board_tasks"

    static let board = belongsTo(Board.self)
    static let task = belongsTo(Task.self)

    // MARK: - Memberwise init
    //
    // Swift would normally synthesise this for free; declaring it
    // explicitly so callers can construct a `BoardTask` directly without
    // a JSON round-trip + force-try (see BoardCreatorPanelView.makeBoardTask).
    init(
        id: String,
        boardId: String,
        taskId: String,
        row: Int,
        col: Int,
        isCenter: Bool,
        createdAt: String,
        updatedAt: String,
        lastSyncedAt: String? = nil,
        version: Int,
        isDeleted: Bool = false,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.boardId = boardId
        self.taskId = taskId
        self.row = row
        self.col = col
        self.isCenter = isCenter
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
        self.version = version
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, boardId, taskId, row, col, isCenter
        case createdAt, updatedAt
        case lastSyncedAt, version, isDeleted, deletedAt
    }

    /// Custom decode for forward-compat on `isDeleted`/`deletedAt` (Board-
    /// integrity PR-1). Unlike `Task`/`Board`/`CompoundChild` — which were
    /// born with `isDeleted` already in their schema — `board_tasks` predates
    /// the column. `MigrationV7Helpers.run(db)` (GRDB migration "v7") decodes
    /// `BoardTask.fetchAll(db)` against the table AS IT EXISTED AT v7, which
    /// is BEFORE the "v27" migration that adds `isDeleted`/`deletedAt` runs —
    /// so a strict `decode(Bool.self, ...)` would throw a missing-column
    /// error on every fresh install / upgrading device. `decodeIfPresent`
    /// mirrors the `createdInWizard` / `isCounter` pattern on `Task` and
    /// keeps that migration decoding fine: absent ⇒ `false`/`nil`. Also
    /// covers pre-feature Firestore payloads from a peer device that hasn't
    /// upgraded yet.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        boardId = try container.decode(String.self, forKey: .boardId)
        taskId = try container.decode(String.self, forKey: .taskId)
        row = try container.decode(Int.self, forKey: .row)
        col = try container.decode(Int.self, forKey: .col)
        isCenter = try container.decode(Bool.self, forKey: .isCenter)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        lastSyncedAt = try container.decodeIfPresent(String.self, forKey: .lastSyncedAt)
        version = try container.decode(Int.self, forKey: .version)
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        deletedAt = try container.decodeIfPresent(String.self, forKey: .deletedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(boardId, forKey: .boardId)
        try container.encode(taskId, forKey: .taskId)
        try container.encode(row, forKey: .row)
        try container.encode(col, forKey: .col)
        try container.encode(isCenter, forKey: .isCenter)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(version, forKey: .version)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}
