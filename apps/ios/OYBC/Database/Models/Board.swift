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
    var startDate: String // ISO8601 (creation anchor for indefinite boards)
    // Absent (nil) for INDEFINITE boards — they never expire. Treat a nil
    // endDate as an unbounded window [startDate, ∞). See `isIndefinite`.
    var endDate: String? // ISO8601
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

    // Phase 6.2 provenance — additive, optional. Set on insert by the
    // template-spawn path; remains nil for manually-created boards.
    // Forward-compatible: pre-6.2 peers without this column on disk
    // get a NULL via the v8 ALTER TABLE.
    var spawnedFromTemplateId: String?

    // Phase 6.1 core-board marker. True iff this board was created from
    // the recurring banner (Phase 6.1) OR auto-spawned from a
    // RecurringBoardTemplate (Phase 6.2). The recurring-banner detector
    // (`findPendingRecurringBoards`) suppresses the banner only when an
    // isCore board exists for the active window — manual ad-hoc boards
    // for the same window do not dismiss the suggestion. Defaults to
    // false; forward-compatible decode (missing column → false via
    // `decodeIfPresent ?? false`).
    var isCore: Bool = false

    // ── Windowed Completion — board sealing (docs §Sealing → Board schema
    //    delta). Swift twin of the three additive TS Board fields ──────────
    //
    // `sealedAt` — set ONCE when the window is closed out (user Seal / auto-seal
    // backstop / migration of an already-expired board). Never cleared; no
    // unseal gesture. A non-nil `sealedAt` makes the board a permanent record:
    // it drops out of the live derivation fan-out, renders read-only from
    // `sealedCompletedCells`, and is Board-Edit-ineligible. `status` is
    // untouched — sealing is orthogonal to draft/active/completed/archived.
    var sealedAt: String? // ISO8601

    // `sealedCompletedCells` — the green cell indexes (row*size+col) frozen at
    // seal time by `computeSealedCompletedCells` from the converged in-window
    // event union. A pure function of that union, so it re-derives
    // deterministically when late pre-seal events arrive. Stored as a JSON
    // string in SQLite (same pattern as `completedLineIds`).
    var sealedCompletedCells: [Int]?

    // `activatedAt` — when the board transitioned out of DRAFT (or, for a board
    // created active, its creation). The auto-seal backstop keys its deadline
    // off `max(endDate, activatedAt)` so a DRAFT activated AFTER its window
    // already expired gets one full prompt cycle before any silent seal.
    var activatedAt: String? // ISO8601

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
        case spawnedFromTemplateId
        case isCore
        case sealedAt, sealedCompletedCells, activatedAt
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
        // nil endDate = indefinite board (or a pre-migration row / sync doc
        // that omits the key). decodeIfPresent keeps both cases nil-safe.
        endDate = try container.decodeIfPresent(String.self, forKey: .endDate)
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
        spawnedFromTemplateId = try container.decodeIfPresent(String.self, forKey: .spawnedFromTemplateId)
        // Forward-compatible: missing column / missing key (pre-migration
        // local rows or pre-Phase-6.1 sync docs) decode as false.
        isCore = try container.decodeIfPresent(Bool.self, forKey: .isCore) ?? false

        // Windowed Completion sealing — all optional/forward-compatible.
        sealedAt = try container.decodeIfPresent(String.self, forKey: .sealedAt)
        activatedAt = try container.decodeIfPresent(String.self, forKey: .activatedAt)
        // sealedCompletedCells stored as a JSON string (like completedLineIds).
        if let jsonString = try container.decodeIfPresent(String.self, forKey: .sealedCompletedCells),
           let data = jsonString.data(using: .utf8) {
            sealedCompletedCells = try? JSONDecoder().decode([Int].self, from: data)
        } else {
            sealedCompletedCells = nil
        }
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
        // Omit the key entirely for indefinite boards (nil endDate) so the
        // row / Firestore doc carries no endDate at all.
        try container.encodeIfPresent(endDate, forKey: .endDate)
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
        try container.encodeIfPresent(spawnedFromTemplateId, forKey: .spawnedFromTemplateId)
        try container.encode(isCore, forKey: .isCore)

        // Windowed Completion sealing.
        try container.encodeIfPresent(sealedAt, forKey: .sealedAt)
        try container.encodeIfPresent(activatedAt, forKey: .activatedAt)
        // Encode sealedCompletedCells as a JSON string (like completedLineIds).
        if let sealedCompletedCells = sealedCompletedCells,
           let data = try? JSONEncoder().encode(sealedCompletedCells),
           let jsonString = String(data: data, encoding: .utf8) {
            try container.encode(jsonString, forKey: .sealedCompletedCells)
        }
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
    case indefinite   // No end date — ongoing board that never expires
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

    /// Whether this is an "indefinite" board — an ongoing board with no end
    /// date that never expires, is excluded from recurrence/streaks/the
    /// core-board pager, but still plays normally and can host achievement
    /// tasks (its window is treated as `[startDate, ∞)`).
    ///
    /// Mirror of the shared `isBoardIndefinite()` predicate. The OR keeps
    /// consumers robust to a sync row whose `endDate` is absent even if its
    /// `timeframe` is stale. Use this everywhere instead of ad-hoc
    /// `timeframe == .indefinite` / `endDate == nil` checks.
    var isIndefinite: Bool {
        return timeframe == .indefinite || endDate == nil
    }
}
