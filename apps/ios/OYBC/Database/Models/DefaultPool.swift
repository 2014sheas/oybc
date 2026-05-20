import Foundation
import GRDB

/// DefaultPool — Phase 6.X (Default Pools).
///
/// User-curated task pool for a recurring timeframe. iOS twin of
/// TypeScript `DefaultPool` in `@oybc/shared`.
///
/// Unlike `RecurringBoardTemplate` (Phase 6.2), DefaultPool does NOT
/// auto-spawn. It's a pure pool definition consumed by:
///   - The recurring-banner wizard prefill path
///     (`BoardWizardViewModel` hydrates `selectedTaskIds` from
///     `pool.taskIds` when banner-launched).
///   - The pre-spawn flow (future Phase B), pulling tasks for a
///     user-picked future window.
///
/// `taskIds` is stored as a JSON-string TEXT column (same pattern as
/// `RecurringBoardTemplate.seedTaskIds` and `Board.completedLineIds`).
///
/// One pool per `(userId, timeframe)` — uniqueness enforced at the
/// application layer (no DB constraint); `AppDatabase` exposes
/// `upsertDefaultPool` which queries by `(userId, timeframe)` and
/// creates-or-updates accordingly.
struct DefaultPool: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var userId: String

    // Configuration
    var timeframe: Timeframe
    var taskIds: [String]

    // Timestamps
    var createdAt: String
    var updatedAt: String

    // Sync metadata
    var lastSyncedAt: String?
    var version: Int
    var isDeleted: Bool
    var deletedAt: String?

    // MARK: - Database Configuration

    static let databaseTableName = "default_pools"

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, userId, timeframe, taskIds
        case createdAt, updatedAt
        case lastSyncedAt, version, isDeleted, deletedAt
    }

    init(
        id: String,
        userId: String,
        timeframe: Timeframe,
        taskIds: [String],
        createdAt: String,
        updatedAt: String,
        lastSyncedAt: String? = nil,
        version: Int = 1,
        isDeleted: Bool = false,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.timeframe = timeframe
        self.taskIds = taskIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
        self.version = version
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        timeframe = try container.decode(Timeframe.self, forKey: .timeframe)

        // Decode taskIds from JSON-string TEXT column (mirror of
        // RecurringBoardTemplate.seedTaskIds and Board.completedLineIds).
        if let jsonString = try container.decodeIfPresent(String.self, forKey: .taskIds),
           let data = jsonString.data(using: .utf8) {
            taskIds = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            taskIds = []
        }

        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        lastSyncedAt = try container.decodeIfPresent(String.self, forKey: .lastSyncedAt)
        version = try container.decode(Int.self, forKey: .version)
        isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
        deletedAt = try container.decodeIfPresent(String.self, forKey: .deletedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encode(timeframe, forKey: .timeframe)

        // Encode taskIds as JSON-string TEXT column.
        if let data = try? JSONEncoder().encode(taskIds),
           let jsonString = String(data: data, encoding: .utf8) {
            try container.encode(jsonString, forKey: .taskIds)
        } else {
            try container.encode("[]", forKey: .taskIds)
        }

        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(version, forKey: .version)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}
