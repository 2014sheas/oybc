import Foundation
import GRDB

/// BoardTask - Placement record linking a board to a task at a grid position.
///
/// Matches TypeScript BoardTask interface from @oybc/shared.
///
/// Under the unified compound model, BoardTask carries NO completion state —
/// `isCompleted` / `currentCount` / `completedAt` all live globally on Task.
/// BoardTask just records where a task sits in a board's grid, plus the
/// achievement-square cross-board-rollup fields (which remain per-board
/// because they track board-specific progress toward a cross-board goal).
struct BoardTask: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var boardId: String
    var taskId: String

    // Grid position
    var row: Int
    var col: Int
    var isCenter: Bool

    // Achievement square data
    var isAchievementSquare: Bool?
    var achievementType: AchievementType?
    var achievementCount: Int?
    var achievementTimeframe: Timeframe?
    var achievementProgress: Int?

    /// Phase 6.3 — Specific-board mode. When set, the achievement
    /// square watches this single named board and completes when the
    /// referenced board's `status == .completed` (greenlog) and is
    /// non-deleted. Mutually exclusive with `referencedTemplateId`;
    /// Zod refinement on the wire schema rejects rows that set both,
    /// and the shared `derivationPass` has a defensive precedence
    /// rule (`referencedBoardId` wins) for the case where bad data
    /// slips through anyway.
    var referencedBoardId: String?

    /// Phase 6.3 — Recurring-template mode. When set, the achievement
    /// square watches all spawns of this template whose `startDate`
    /// falls within the parent board's `[startDate, endDate]` window.
    /// Completes when the in-window non-deleted spawn set is non-empty
    /// AND every member is `.completed`. Mutually exclusive with
    /// `referencedBoardId`.
    var referencedTemplateId: String?

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
    // Swift would normally synthesise this for free, but the custom
    // `init(from decoder:)` below suppresses synthesis. We declare it
    // explicitly so callers can construct a `BoardTask` directly without
    // a JSON round-trip + force-try (see BoardCreatorPanelView.makeBoardTask).
    init(
        id: String,
        boardId: String,
        taskId: String,
        row: Int,
        col: Int,
        isCenter: Bool,
        isAchievementSquare: Bool? = nil,
        achievementType: AchievementType? = nil,
        achievementCount: Int? = nil,
        achievementTimeframe: Timeframe? = nil,
        achievementProgress: Int? = nil,
        referencedBoardId: String? = nil,
        referencedTemplateId: String? = nil,
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
        self.isAchievementSquare = isAchievementSquare
        self.achievementType = achievementType
        self.achievementCount = achievementCount
        self.achievementTimeframe = achievementTimeframe
        self.achievementProgress = achievementProgress
        self.referencedBoardId = referencedBoardId
        self.referencedTemplateId = referencedTemplateId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
        self.version = version
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, boardId, taskId
        case row, col, isCenter
        case isAchievementSquare, achievementType, achievementCount
        case achievementTimeframe, achievementProgress
        case referencedBoardId, referencedTemplateId
        case createdAt, updatedAt
        case lastSyncedAt, version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        boardId = try container.decode(String.self, forKey: .boardId)
        taskId = try container.decode(String.self, forKey: .taskId)
        row = try container.decode(Int.self, forKey: .row)
        col = try container.decode(Int.self, forKey: .col)
        isCenter = try container.decode(Bool.self, forKey: .isCenter)

        isAchievementSquare = try container.decodeIfPresent(Bool.self, forKey: .isAchievementSquare)
        achievementType = try container.decodeIfPresent(AchievementType.self, forKey: .achievementType)
        achievementCount = try container.decodeIfPresent(Int.self, forKey: .achievementCount)
        achievementTimeframe = try container.decodeIfPresent(Timeframe.self, forKey: .achievementTimeframe)
        achievementProgress = try container.decodeIfPresent(Int.self, forKey: .achievementProgress)
        referencedBoardId = try container.decodeIfPresent(String.self, forKey: .referencedBoardId)
        referencedTemplateId = try container.decodeIfPresent(String.self, forKey: .referencedTemplateId)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        lastSyncedAt = try container.decodeIfPresent(String.self, forKey: .lastSyncedAt)
        version = try container.decode(Int.self, forKey: .version)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(boardId, forKey: .boardId)
        try container.encode(taskId, forKey: .taskId)
        try container.encode(row, forKey: .row)
        try container.encode(col, forKey: .col)
        try container.encode(isCenter, forKey: .isCenter)

        try container.encodeIfPresent(isAchievementSquare, forKey: .isAchievementSquare)
        try container.encodeIfPresent(achievementType, forKey: .achievementType)
        try container.encodeIfPresent(achievementCount, forKey: .achievementCount)
        try container.encodeIfPresent(achievementTimeframe, forKey: .achievementTimeframe)
        try container.encodeIfPresent(achievementProgress, forKey: .achievementProgress)
        try container.encodeIfPresent(referencedBoardId, forKey: .referencedBoardId)
        try container.encodeIfPresent(referencedTemplateId, forKey: .referencedTemplateId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(version, forKey: .version)
    }
}

// MARK: - Enums

enum AchievementType: String, Codable, DatabaseValueConvertible {
    case bingo
    case fullCompletion = "full_completion"
}
