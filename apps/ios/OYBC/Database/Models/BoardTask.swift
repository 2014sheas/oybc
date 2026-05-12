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
        version: Int
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
    }
}
