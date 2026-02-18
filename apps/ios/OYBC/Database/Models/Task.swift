import Foundation
import GRDB

/// Task - Reusable task definition
///
/// Matches TypeScript Task interface from @oybc/shared
struct Task: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var userId: String

    // Core fields
    var title: String
    var description: String?
    var type: TaskType

    // Counting task fields
    var action: String?
    var unit: String?
    var maxCount: Int?

    // Task linking (for tasks used as progress steps)
    var parentStepId: String?
    var parentStepIndex: Int?

    // Progress counters
    var progressCounters: [TaskProgressCounter]?

    // Aggregate stats
    var totalCompletions: Int
    var totalInstances: Int

    // Timestamps
    var createdAt: String // ISO8601
    var updatedAt: String // ISO8601

    // Sync metadata
    var lastSyncedAt: String? // ISO8601
    var version: Int
    var isDeleted: Bool
    var deletedAt: String? // ISO8601

    // MARK: - Database Configuration

    static let databaseTableName = "tasks"

    static let steps = hasMany(TaskStep.self)
    static let boardTasks = hasMany(BoardTask.self)

    // MARK: - Memberwise Init

    /// Explicit memberwise initializer (needed since custom Codable init is defined)
    init(
        id: String,
        userId: String,
        title: String,
        description: String? = nil,
        type: TaskType,
        action: String? = nil,
        unit: String? = nil,
        maxCount: Int? = nil,
        parentStepId: String? = nil,
        parentStepIndex: Int? = nil,
        progressCounters: [TaskProgressCounter]? = nil,
        totalCompletions: Int,
        totalInstances: Int,
        createdAt: String,
        updatedAt: String,
        lastSyncedAt: String? = nil,
        version: Int,
        isDeleted: Bool,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.description = description
        self.type = type
        self.action = action
        self.unit = unit
        self.maxCount = maxCount
        self.parentStepId = parentStepId
        self.parentStepIndex = parentStepIndex
        self.progressCounters = progressCounters
        self.totalCompletions = totalCompletions
        self.totalInstances = totalInstances
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
        self.version = version
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, userId, title, description, type
        case action, unit, maxCount
        case parentStepId, parentStepIndex, progressCounters
        case totalCompletions, totalInstances
        case createdAt, updatedAt
        case lastSyncedAt, version, isDeleted, deletedAt
    }

    // Custom decoding for progressCounters (stored as JSON string)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        type = try container.decode(TaskType.self, forKey: .type)
        action = try container.decodeIfPresent(String.self, forKey: .action)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        maxCount = try container.decodeIfPresent(Int.self, forKey: .maxCount)
        parentStepId = try container.decodeIfPresent(String.self, forKey: .parentStepId)
        parentStepIndex = try container.decodeIfPresent(Int.self, forKey: .parentStepIndex)

        // Decode progressCounters from JSON string
        if let jsonString = try container.decodeIfPresent(String.self, forKey: .progressCounters),
           let data = jsonString.data(using: .utf8) {
            progressCounters = try? JSONDecoder().decode([TaskProgressCounter].self, from: data)
        } else {
            progressCounters = nil
        }

        totalCompletions = try container.decode(Int.self, forKey: .totalCompletions)
        totalInstances = try container.decode(Int.self, forKey: .totalInstances)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        lastSyncedAt = try container.decodeIfPresent(String.self, forKey: .lastSyncedAt)
        version = try container.decode(Int.self, forKey: .version)
        isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
        deletedAt = try container.decodeIfPresent(String.self, forKey: .deletedAt)
    }

    // Custom encoding for progressCounters (store as JSON string)
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(unit, forKey: .unit)
        try container.encodeIfPresent(maxCount, forKey: .maxCount)
        try container.encodeIfPresent(parentStepId, forKey: .parentStepId)
        try container.encodeIfPresent(parentStepIndex, forKey: .parentStepIndex)

        // Encode progressCounters as JSON string
        if let progressCounters = progressCounters,
           let data = try? JSONEncoder().encode(progressCounters),
           let jsonString = String(data: data, encoding: .utf8) {
            try container.encode(jsonString, forKey: .progressCounters)
        }

        try container.encode(totalCompletions, forKey: .totalCompletions)
        try container.encode(totalInstances, forKey: .totalInstances)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(version, forKey: .version)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}

// MARK: - TaskStep

/// TaskStep - Step within a progress task
///
/// Matches TypeScript TaskStep interface from @oybc/shared
struct TaskStep: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var taskId: String
    var stepIndex: Int

    // Core fields
    var title: String
    var type: TaskType

    // Counting step fields
    var action: String?
    var unit: String?
    var maxCount: Int?

    // Step linking
    var linkedTaskId: String?

    // Timestamps
    var createdAt: String // ISO8601
    var updatedAt: String // ISO8601

    // Sync metadata
    var lastSyncedAt: String? // ISO8601
    var version: Int
    var isDeleted: Bool
    var deletedAt: String? // ISO8601

    // MARK: - Database Configuration

    static let databaseTableName = "task_steps"

    static let task = belongsTo(Task.self)
}

// MARK: - Supporting Types

enum TaskType: String, Codable, DatabaseValueConvertible {
    case normal
    case counting
    case progress
}

struct TaskProgressCounter: Codable {
    var counterId: String
    var targetValue: Double
    var unit: String?
}
