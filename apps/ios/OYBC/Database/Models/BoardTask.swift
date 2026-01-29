import Foundation
import GRDB

/// BoardTask - Junction table linking boards and tasks
///
/// Matches TypeScript BoardTask interface from @oybc/shared
struct BoardTask: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var boardId: String
    var taskId: String

    // Grid position
    var row: Int
    var col: Int
    var isCenter: Bool

    // Per-board completion state
    var isCompleted: Bool
    var completedAt: String? // ISO8601

    // Task type-specific data
    var currentCount: Int?
    var completedStepIds: [String]?

    // Achievement square data
    var isAchievementSquare: Bool?
    var achievementType: AchievementType?
    var achievementCount: Int?
    var achievementTimeframe: Timeframe?
    var achievementProgress: Int?

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

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, boardId, taskId
        case row, col, isCenter
        case isCompleted, completedAt
        case currentCount, completedStepIds
        case isAchievementSquare, achievementType, achievementCount
        case achievementTimeframe, achievementProgress
        case createdAt, updatedAt
        case lastSyncedAt, version
    }

    // Custom decoding for completedStepIds (stored as JSON string)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        boardId = try container.decode(String.self, forKey: .boardId)
        taskId = try container.decode(String.self, forKey: .taskId)
        row = try container.decode(Int.self, forKey: .row)
        col = try container.decode(Int.self, forKey: .col)
        isCenter = try container.decode(Bool.self, forKey: .isCenter)
        isCompleted = try container.decode(Bool.self, forKey: .isCompleted)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        currentCount = try container.decodeIfPresent(Int.self, forKey: .currentCount)

        // Decode completedStepIds from JSON string
        if let jsonString = try container.decodeIfPresent(String.self, forKey: .completedStepIds),
           let data = jsonString.data(using: .utf8) {
            completedStepIds = try? JSONDecoder().decode([String].self, from: data)
        } else {
            completedStepIds = nil
        }

        isAchievementSquare = try container.decodeIfPresent(Bool.self, forKey: .isAchievementSquare)
        achievementType = try container.decodeIfPresent(AchievementType.self, forKey: .achievementType)
        achievementCount = try container.decodeIfPresent(Int.self, forKey: .achievementCount)
        achievementTimeframe = try container.decodeIfPresent(Timeframe.self, forKey: .achievementTimeframe)
        achievementProgress = try container.decodeIfPresent(Int.self, forKey: .achievementProgress)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        lastSyncedAt = try container.decodeIfPresent(String.self, forKey: .lastSyncedAt)
        version = try container.decode(Int.self, forKey: .version)
    }

    // Custom encoding for completedStepIds (store as JSON string)
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(boardId, forKey: .boardId)
        try container.encode(taskId, forKey: .taskId)
        try container.encode(row, forKey: .row)
        try container.encode(col, forKey: .col)
        try container.encode(isCenter, forKey: .isCenter)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(currentCount, forKey: .currentCount)

        // Encode completedStepIds as JSON string
        if let completedStepIds = completedStepIds,
           let data = try? JSONEncoder().encode(completedStepIds),
           let jsonString = String(data: data, encoding: .utf8) {
            try container.encode(jsonString, forKey: .completedStepIds)
        }

        try container.encodeIfPresent(isAchievementSquare, forKey: .isAchievementSquare)
        try container.encodeIfPresent(achievementType, forKey: .achievementType)
        try container.encodeIfPresent(achievementCount, forKey: .achievementCount)
        try container.encodeIfPresent(achievementTimeframe, forKey: .achievementTimeframe)
        try container.encodeIfPresent(achievementProgress, forKey: .achievementProgress)
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
