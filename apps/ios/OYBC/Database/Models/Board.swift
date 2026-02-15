import Foundation
import GRDB

/// Board - Main game board entity
///
/// Matches TypeScript Board interface from @oybc/shared
struct Board: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var userId: String

    // Metadata
    var name: String
    var description: String?

    // Configuration
    var status: BoardStatus
    var boardSize: Int
    var timeframe: Timeframe
    var startDate: String // ISO8601
    var endDate: String // ISO8601
    var centerSquareType: CenterSquareType
    var centerSquareCustomName: String?
    var centerTaskId: String?
    var isRandomized: Bool

    // Denormalized stats
    var totalTasks: Int
    var completedTasks: Int
    var linesCompleted: Int
    var completedLineIds: [String]?

    // Timestamps
    var createdAt: String // ISO8601
    var updatedAt: String // ISO8601
    var completedAt: String? // ISO8601

    // Sync metadata
    var lastSyncedAt: String? // ISO8601
    var version: Int
    var isDeleted: Bool
    var deletedAt: String? // ISO8601

    // MARK: - Database Configuration

    static let databaseTableName = "boards"

    static let tasks = hasMany(BoardTask.self)

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, userId, name, description, status, boardSize, timeframe
        case startDate, endDate, centerSquareType, centerSquareCustomName, centerTaskId, isRandomized
        case totalTasks, completedTasks, linesCompleted, completedLineIds
        case createdAt, updatedAt, completedAt
        case lastSyncedAt, version, isDeleted, deletedAt
    }

    // Custom decoding for completedLineIds (stored as JSON string)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        status = try container.decode(BoardStatus.self, forKey: .status)
        boardSize = try container.decode(Int.self, forKey: .boardSize)
        timeframe = try container.decode(Timeframe.self, forKey: .timeframe)
        startDate = try container.decode(String.self, forKey: .startDate)
        endDate = try container.decode(String.self, forKey: .endDate)
        centerSquareType = try container.decode(CenterSquareType.self, forKey: .centerSquareType)
        centerSquareCustomName = try container.decodeIfPresent(String.self, forKey: .centerSquareCustomName)
        centerTaskId = try container.decodeIfPresent(String.self, forKey: .centerTaskId)
        isRandomized = try container.decode(Bool.self, forKey: .isRandomized)
        totalTasks = try container.decode(Int.self, forKey: .totalTasks)
        completedTasks = try container.decode(Int.self, forKey: .completedTasks)
        linesCompleted = try container.decode(Int.self, forKey: .linesCompleted)

        // Decode completedLineIds from JSON string
        if let jsonString = try container.decodeIfPresent(String.self, forKey: .completedLineIds),
           let data = jsonString.data(using: .utf8) {
            completedLineIds = try? JSONDecoder().decode([String].self, from: data)
        } else {
            completedLineIds = nil
        }

        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        lastSyncedAt = try container.decodeIfPresent(String.self, forKey: .lastSyncedAt)
        version = try container.decode(Int.self, forKey: .version)
        isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
        deletedAt = try container.decodeIfPresent(String.self, forKey: .deletedAt)
    }

    // Custom encoding for completedLineIds (store as JSON string)
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(status, forKey: .status)
        try container.encode(boardSize, forKey: .boardSize)
        try container.encode(timeframe, forKey: .timeframe)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(endDate, forKey: .endDate)
        try container.encode(centerSquareType, forKey: .centerSquareType)
        try container.encodeIfPresent(centerSquareCustomName, forKey: .centerSquareCustomName)
        try container.encodeIfPresent(centerTaskId, forKey: .centerTaskId)
        try container.encode(isRandomized, forKey: .isRandomized)
        try container.encode(totalTasks, forKey: .totalTasks)
        try container.encode(completedTasks, forKey: .completedTasks)
        try container.encode(linesCompleted, forKey: .linesCompleted)

        // Encode completedLineIds as JSON string
        if let completedLineIds = completedLineIds,
           let data = try? JSONEncoder().encode(completedLineIds),
           let jsonString = String(data: data, encoding: .utf8) {
            try container.encode(jsonString, forKey: .completedLineIds)
        }

        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(version, forKey: .version)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}

// MARK: - Enums

enum BoardStatus: String, Codable, DatabaseValueConvertible {
    case draft
    case active
    case completed
    case archived
}

enum Timeframe: String, Codable, DatabaseValueConvertible {
    case daily
    case weekly
    case monthly
    case yearly
    case custom
}

enum CenterSquareType: String, Codable, DatabaseValueConvertible {
    case free
    case customFree = "custom_free"
    case chosen
    case none
}

// MARK: - Computed Properties

extension Board {
    /// Computed completion percentage (not stored)
    var completionPercentage: Double {
        guard totalTasks > 0 else { return 0 }
        return Double(completedTasks) / Double(totalTasks) * 100
    }

    /// Check if board has any completed lines
    var hasBingo: Bool {
        return linesCompleted > 0
    }
}
