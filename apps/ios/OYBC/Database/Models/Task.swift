import Foundation
import GRDB

/// Task - Reusable task definition
///
/// Matches TypeScript Task interface from @oybc/shared.
///
/// Design principles:
///   - Tasks are reusable across multiple boards.
///   - LIFETIME-CACHE completion state lives on Task (`isCompleted`,
///     `completedAt`, `currentCount`) — Windowed Completion
///     (docs/WINDOWED_COMPLETION.md §Task caches) demoted these to caches
///     over the `task_events` log: read them ONLY on library/global
///     surfaces and for the derived shared-counter carve-out. A board
///     renders each task against ITS window (`resolveTaskWindowState` /
///     `DerivationPass.computeBoardGrid`) — reading these fields for
///     anything windowed is the bleed-green bug class (PR #356/#373/#376).
///     Recomputed from events on pull. BoardTask is a pure placement record.
///   - For compound Tasks (`type=.compound`), `isCompleted` is structurally
///     present but never written or read — derive completion via
///     CompoundEvaluation.evaluate (added in Task 3.6).
///   - UUID primary key (offline creation).
struct Task: Codable, FetchableRecord, PersistableRecord, Identifiable {
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
    var maxCount: CountValue?

    // Compound-specific (when type=.compound)
    var operatorType: OperatorType?
    var threshold: Int?

    // Phase 6.3 — Achievement-task cross-board references (only
    // meaningful when type == .achievement). Mutually exclusive; the
    // Zod refinement on shared TaskSchema rejects rows with both set,
    // and derivation has a defensive precedence rule (`referencedBoardId`
    // wins) for bad data that slips through anyway. Setting either
    // field on a non-ACHIEVEMENT task is rejected at the write helper.
    var referencedBoardId: String?
    var referencedTemplateId: String?

    /// Phase 6.3 — Completion trigger for the watched target. Defaults
    /// to `.greenlog` on decode when absent (matches the pre-trigger
    /// shipped behavior + the shared TS twin). Setting this on a
    /// non-ACHIEVEMENT task is rejected at the write helper.
    var achievementTrigger: AchievementTrigger?

    /// Phase 6.3 — Required count of in-window spawns hitting the
    /// trigger (recurring-template mode only). Required positive
    /// integer when `referencedTemplateId` is set; ignored for
    /// specific-board mode and forbidden on non-ACHIEVEMENT.
    var requiredCount: Int?

    // Aggregate stats
    var totalCompletions: Int
    var totalInstances: Int

    // Global completion state
    var isCompleted: Bool
    var completedAt: String? // ISO8601
    var currentCount: CountValue?

    // Timestamps
    var createdAt: String // ISO8601
    var updatedAt: String // ISO8601

    // Sync metadata
    var lastSyncedAt: String? // ISO8601
    var version: Int
    var isDeleted: Bool
    var deletedAt: String? // ISO8601

    // Phase 6.Y — Timeboxed Tasks. All three optional; absent ⇒
    // indefinite (never expired). Wizard-initiated creates inherit
    // from the board being built; standalone quick-add omits them.
    // Tasks existing pre-migration are backfilled from their most-
    // recent BoardTask placement during GRDB v14 upgrade.
    var timeframe: Timeframe?
    var startDate: String? // ISO8601
    var endDate: String? // ISO8601

    // Phase 2 — Shared Counters. Points at the source counting task whose
    // `currentCount` drives this task's displayed value via
    // `deriveDisplayedCount()`. Nil for non-linked tasks. Only meaningful
    // when `type == .counting`. Stored as TEXT; no DB-level FK constraint
    // (soft-delete semantics make hard constraints unworkable).
    var sharedCounterId: String?

    // Phase 2 — Shared Counters. The source task's `currentCount` at the
    // moment this task was linked. Mirrors the TypeScript `Task.baseline`
    // field. Must be non-nil when `sharedCounterId` is non-nil, and nil
    // when `sharedCounterId` is nil.
    //   - "Inherit" mode: baseline = 0 → displayed = source.currentCount.
    //   - "Start from zero" mode: baseline = source.currentCount_at_link_time
    //     → displayed = source.currentCount − baseline.
    var baseline: CountValue?

    // RETIRED (Windowed Completion). Phase 4's shared-counter additive-merge
    // common-ancestor baseline. The additive-merge resolver it fed was retired —
    // counting-task conflicts now resolve by union-of-events, not by merging
    // `currentCount` (docs/WINDOWED_COMPLETION.md §Shared counters interaction).
    // Nothing writes or reads this field anymore (WC PR B stopped stamping it;
    // WC PR D deleted the merge machinery). Kept on the model + as the GRDB v16
    // column for decode compatibility with old rows / pre-WC clients — dropping
    // it would break decode. Inert residue; do not re-wire it.
    var lastSyncedCount: CountValue?

    /// Draft-board provenance. `true` when the task was created inside the
    /// board wizard via the deferred-persist path (Bug #85) — "born from a
    /// board" rather than standalone in the Tasks tab. Library-browse
    /// surfaces hide a task iff `createdInWizard` AND it is placed only on
    /// draft boards, so wizard-born tasks stay out of the library until
    /// their board goes active. Defaults to `false`; standalone + copied +
    /// pre-migration rows are all `false`. Stored as INTEGER (GRDB v17).
    var createdInWizard: Bool

    /// P5 — hub-born counter flag. `true` marks a COUNTING task created from
    /// the Counters Hub as a goal-less accumulator (`maxCount == nil`) — a
    /// running tally with no threshold to complete against, as opposed to a
    /// standard goaled counting task. Defaults to `false`; standalone +
    /// wizard-born + pre-migration rows are all `false`. Stored as INTEGER
    /// (GRDB v23).
    var isCounter: Bool

    /// R2 Counters UX refresh — the counter's last-used log amount
    /// (positive integer), persisted per source counting task so the
    /// Counters Hub "+ Log" pill and Counter Detail's amount-chip row default
    /// to whatever the user logged with most recently. `nil` when never set
    /// (callers fall back to `1`). Only meaningful when `type == .counting`
    /// and `sharedCounterId == nil` (the source, not a linked/derived task).
    /// Additive optional, forward-compat like `isCounter`; stored as
    /// nullable INTEGER (GRDB v26).
    var defaultLogAmount: CountValue?

    /// Counter kinds (docs/COUNTER_KINDS.md §3) — how a counting task's
    /// values are measured. `nil` (every pre-v39 row and pre-feature sync
    /// payload) resolves to `.discrete` via `resolveCountKind`. Additive
    /// optional; stored as nullable TEXT (GRDB v39).
    var countKind: CountKind?

    /// Board-scoped task edits (docs/BOARD_SCOPED_TASK_EDITS.md §3) — set on
    /// a FORK, the per-board copy a Board Edit edit mints when the task is
    /// placed on any other board, to the original task's id. Informational
    /// provenance: a fork is an independent row, never re-forked, never
    /// browsable, never source supply, untouched by the original's
    /// `deleteTaskWithCascade`. Never cleared once set. `nil` on every
    /// non-fork task (and every pre-v41 row / pre-feature payload). Stored as
    /// nullable TEXT (GRDB v41). Mirrors the TS `Task.forkedFromTaskId`.
    var forkedFromTaskId: String?

    /// Shared counter settings (docs/SHARED_COUNTER_SETTINGS.md §1) — set on a
    /// counter ROOT only, by the counter sheet; each `nil` until the user edits
    /// it away from its default (D3 — never backfilled, never written on read),
    /// and cleared back to `nil` when reset (all four are clearable on sync).
    /// `counterName` → the hub / Detail / picker label (`CounterSettings.counterDisplayName`);
    /// the templates carry `#N` for the count (`CounterSettings.renderCounterTitle`);
    /// `timeframeGoals` → default goal per core timeframe. Nullable TEXT
    /// columns (GRDB v42); `timeframeGoals` is a JSON string. Mirrors the TS fields.
    var counterName: String?
    var titleTemplateSingular: String?
    var titleTemplatePlural: String?
    var timeframeGoals: CounterTimeframeGoals?

    /// "Counts toward" (docs/SHARED_COUNTER_SETTINGS.md §3) — set on a
    /// CONTRIBUTING task: when its derived lifetime state becomes complete the
    /// board cascade writes one increment of `countsTowardAmount` (nil = 1) on
    /// this Discrete counter root, id `CountsToward.eventId(contributingTaskId:)`;
    /// when it becomes incomplete again that event is tombstoned
    /// (`AppDatabase+CountsToward.swift`). Never on a counter root, a linked
    /// copy or an Achievement. Clearable on sync (a clear is written by raw SQL —
    /// `encode` nil-skips). Nullable TEXT / INTEGER columns (GRDB v43).
    var countsTowardCounterId: String?
    var countsTowardAmount: Int?

    // MARK: - Database Configuration

    static let databaseTableName = "tasks"

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
        maxCount: CountValue? = nil,
        operatorType: OperatorType? = nil,
        threshold: Int? = nil,
        referencedBoardId: String? = nil,
        referencedTemplateId: String? = nil,
        achievementTrigger: AchievementTrigger? = nil,
        requiredCount: Int? = nil,
        totalCompletions: Int,
        totalInstances: Int,
        isCompleted: Bool = false,
        completedAt: String? = nil,
        currentCount: CountValue? = nil,
        createdAt: String,
        updatedAt: String,
        lastSyncedAt: String? = nil,
        version: Int,
        isDeleted: Bool,
        deletedAt: String? = nil,
        timeframe: Timeframe? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        sharedCounterId: String? = nil,
        baseline: CountValue? = nil,
        lastSyncedCount: CountValue? = nil,
        createdInWizard: Bool = false,
        isCounter: Bool = false,
        defaultLogAmount: CountValue? = nil,
        countKind: CountKind? = nil,
        forkedFromTaskId: String? = nil,
        counterName: String? = nil,
        titleTemplateSingular: String? = nil,
        titleTemplatePlural: String? = nil,
        timeframeGoals: CounterTimeframeGoals? = nil,
        countsTowardCounterId: String? = nil,
        countsTowardAmount: Int? = nil
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.description = description
        self.type = type
        self.action = action
        self.unit = unit
        self.maxCount = maxCount
        self.operatorType = operatorType
        self.threshold = threshold
        self.referencedBoardId = referencedBoardId
        self.referencedTemplateId = referencedTemplateId
        self.achievementTrigger = achievementTrigger
        self.requiredCount = requiredCount
        self.totalCompletions = totalCompletions
        self.totalInstances = totalInstances
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.currentCount = currentCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
        self.version = version
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.timeframe = timeframe
        self.startDate = startDate
        self.endDate = endDate
        self.sharedCounterId = sharedCounterId
        self.baseline = baseline
        self.lastSyncedCount = lastSyncedCount
        self.createdInWizard = createdInWizard
        self.isCounter = isCounter
        self.defaultLogAmount = defaultLogAmount
        self.countKind = countKind
        self.forkedFromTaskId = forkedFromTaskId
        self.counterName = counterName
        self.titleTemplateSingular = titleTemplateSingular
        self.titleTemplatePlural = titleTemplatePlural
        self.timeframeGoals = timeframeGoals
        self.countsTowardCounterId = countsTowardCounterId
        self.countsTowardAmount = countsTowardAmount
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, userId, title, description, type
        case action, unit, maxCount
        case operatorType = "operator"
        case threshold
        case referencedBoardId, referencedTemplateId
        case achievementTrigger, requiredCount
        case totalCompletions, totalInstances
        case isCompleted, completedAt, currentCount
        case createdAt, updatedAt
        case lastSyncedAt, version, isDeleted, deletedAt
        // Phase 6.Y
        case timeframe, startDate, endDate
        // Phase 2 — Shared Counters
        case sharedCounterId, baseline
        // Phase 4 — Shared Counter Sync
        case lastSyncedCount
        // Draft-board provenance (GRDB v17)
        case createdInWizard
        // P5 — hub-born counter flag (GRDB v23)
        case isCounter
        // R2 Counters UX refresh — default log amount (GRDB v26)
        case defaultLogAmount
        // Counter kinds (GRDB v39)
        case countKind
        // Board-scoped task edits — fork provenance (GRDB v41)
        case forkedFromTaskId
        // Shared counter settings (GRDB v42)
        case counterName, titleTemplateSingular, titleTemplatePlural, timeframeGoals
        // Counts toward (GRDB v43)
        case countsTowardCounterId, countsTowardAmount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        type = try container.decode(TaskType.self, forKey: .type)
        action = try container.decodeIfPresent(String.self, forKey: .action)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        maxCount = try container.decodeIfPresent(CountValue.self, forKey: .maxCount)
        operatorType = try container.decodeIfPresent(OperatorType.self, forKey: .operatorType)
        threshold = try container.decodeIfPresent(Int.self, forKey: .threshold)
        referencedBoardId = try container.decodeIfPresent(String.self, forKey: .referencedBoardId)
        referencedTemplateId = try container.decodeIfPresent(String.self, forKey: .referencedTemplateId)
        achievementTrigger = try container.decodeIfPresent(AchievementTrigger.self, forKey: .achievementTrigger)
        requiredCount = try container.decodeIfPresent(Int.self, forKey: .requiredCount)
        totalCompletions = try container.decode(Int.self, forKey: .totalCompletions)
        totalInstances = try container.decode(Int.self, forKey: .totalInstances)
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        currentCount = try container.decodeIfPresent(CountValue.self, forKey: .currentCount)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        lastSyncedAt = try container.decodeIfPresent(String.self, forKey: .lastSyncedAt)
        version = try container.decode(Int.self, forKey: .version)
        isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
        deletedAt = try container.decodeIfPresent(String.self, forKey: .deletedAt)
        // Phase 6.Y — Timeboxed Tasks. Forward-compat: pre-migration
        // local rows + pre-feature sync payloads decode as nil.
        timeframe = try container.decodeIfPresent(Timeframe.self, forKey: .timeframe)
        startDate = try container.decodeIfPresent(String.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(String.self, forKey: .endDate)
        // Phase 2 — Shared Counters. Forward-compat: pre-v15 rows decode as nil.
        sharedCounterId = try container.decodeIfPresent(String.self, forKey: .sharedCounterId)
        baseline = try container.decodeIfPresent(CountValue.self, forKey: .baseline)
        // Phase 4 — Shared Counter Sync. Forward-compat: pre-v16 rows decode as nil.
        lastSyncedCount = try container.decodeIfPresent(CountValue.self, forKey: .lastSyncedCount)
        // Draft-board provenance. Forward-compat: pre-v17 local rows + pre-feature
        // sync payloads (and all standalone/copied tasks) decode as false.
        createdInWizard = try container.decodeIfPresent(Bool.self, forKey: .createdInWizard) ?? false
        // P5 — hub-born counter flag. Forward-compat: pre-v23 local rows +
        // pre-feature sync payloads (and all non-hub-born tasks) decode as false.
        isCounter = try container.decodeIfPresent(Bool.self, forKey: .isCounter) ?? false
        // R2 Counters UX refresh — default log amount. Forward-compat:
        // pre-v26 local rows + pre-feature sync payloads decode as nil.
        defaultLogAmount = try container.decodeIfPresent(CountValue.self, forKey: .defaultLogAmount)
        // Counter kinds. Forward-compat: pre-v39 rows + pre-feature payloads decode as nil.
        countKind = try container.decodeIfPresent(CountKind.self, forKey: .countKind)
        // Board-scoped task edits. Forward-compat: pre-v41 rows + pre-feature payloads decode as nil.
        forkedFromTaskId = try container.decodeIfPresent(String.self, forKey: .forkedFromTaskId)
        // Shared counter settings. Forward-compat: pre-v42 rows + pre-feature payloads decode as nil.
        counterName = try container.decodeIfPresent(String.self, forKey: .counterName)
        titleTemplateSingular = try container.decodeIfPresent(String.self, forKey: .titleTemplateSingular)
        titleTemplatePlural = try container.decodeIfPresent(String.self, forKey: .titleTemplatePlural)
        timeframeGoals = Self.decodeTimeframeGoals(container)
        // Counts toward. Forward-compat: pre-v43 rows + pre-feature payloads decode as nil.
        countsTowardCounterId = try container.decodeIfPresent(String.self, forKey: .countsTowardCounterId)
        countsTowardAmount = try container.decodeIfPresent(Int.self, forKey: .countsTowardAmount)
    }

    /// `timeframeGoals` is a JSON string in GRDB (like `Board.sealedCompletedCells`);
    /// a native object (a JSON payload) decodes too. Malformed / empty → nil.
    private static func decodeTimeframeGoals(_ container: KeyedDecodingContainer<CodingKeys>) -> CounterTimeframeGoals? {
        let goals: CounterTimeframeGoals?
        if let json = try? container.decodeIfPresent(String.self, forKey: .timeframeGoals),
           let data = json.data(using: .utf8) {
            goals = try? JSONDecoder().decode(CounterTimeframeGoals.self, from: data)
        } else {
            goals = try? container.decodeIfPresent(CounterTimeframeGoals.self, forKey: .timeframeGoals)
        }
        return goals?.isEmpty == false ? goals : nil
    }

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
        try container.encodeIfPresent(operatorType, forKey: .operatorType)
        try container.encodeIfPresent(threshold, forKey: .threshold)
        try container.encodeIfPresent(referencedBoardId, forKey: .referencedBoardId)
        try container.encodeIfPresent(referencedTemplateId, forKey: .referencedTemplateId)
        try container.encodeIfPresent(achievementTrigger, forKey: .achievementTrigger)
        try container.encodeIfPresent(requiredCount, forKey: .requiredCount)
        try container.encode(totalCompletions, forKey: .totalCompletions)
        try container.encode(totalInstances, forKey: .totalInstances)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(currentCount, forKey: .currentCount)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(version, forKey: .version)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encodeIfPresent(timeframe, forKey: .timeframe)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        // Phase 2 — Shared Counters
        try container.encodeIfPresent(sharedCounterId, forKey: .sharedCounterId)
        try container.encodeIfPresent(baseline, forKey: .baseline)
        // Phase 4 — Shared Counter Sync
        try container.encodeIfPresent(lastSyncedCount, forKey: .lastSyncedCount)
        // Draft-board provenance — always encoded (like isCompleted) so the
        // field is present in every Firestore doc + GRDB row.
        try container.encode(createdInWizard, forKey: .createdInWizard)
        // P5 — hub-born counter flag — always encoded, same rationale.
        try container.encode(isCounter, forKey: .isCounter)
        // R2 Counters UX refresh — default log amount (additive optional).
        try container.encodeIfPresent(defaultLogAmount, forKey: .defaultLogAmount)
        // Counter kinds (additive optional).
        try container.encodeIfPresent(countKind, forKey: .countKind)
        // Board-scoped task edits — fork provenance (additive optional, nil-skipped).
        try container.encodeIfPresent(forkedFromTaskId, forKey: .forkedFromTaskId)
        // Shared counter settings (additive optional, nil-skipped — a clear is
        // written by `AppDatabase.writeCounterSettingsColumns`, since GRDB's
        // update only SETs encoded keys).
        try container.encodeIfPresent(counterName, forKey: .counterName)
        try container.encodeIfPresent(titleTemplateSingular, forKey: .titleTemplateSingular)
        try container.encodeIfPresent(titleTemplatePlural, forKey: .titleTemplatePlural)
        if let json = Self.timeframeGoalsJSON(timeframeGoals) {
            try container.encode(json, forKey: .timeframeGoals)
        }
        // Counts toward (additive optional, nil-skipped — a clear is written by
        // `AppDatabase.writeCountsTowardColumns`).
        try container.encodeIfPresent(countsTowardCounterId, forKey: .countsTowardCounterId)
        try container.encodeIfPresent(countsTowardAmount, forKey: .countsTowardAmount)
    }

    /// `timeframeGoals` as its stored JSON string (sorted keys; nil when absent / empty).
    static func timeframeGoalsJSON(_ goals: CounterTimeframeGoals?) -> String? {
        guard let goals, !goals.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(goals) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Supporting Types

enum TaskType: String, Codable, DatabaseValueConvertible {
    case normal
    case counting
    case compound
    /// Phase 6.3 — Cross-board watcher (specific board XOR recurring
    /// template). Carries `referencedBoardId` / `referencedTemplateId`
    /// on the Task row; BoardTask remains placement-only.
    case achievement
    // Note: the legacy `.progress` case was removed post-unification. Former
    // Progress tasks are now `.compound` (isOrdered removed; see the
    // in-order-compounds removal). Migration
    // helpers that need to recognise legacy `'progress'` rows in pre-migration
    // storage compare against the literal string directly via
    // `typeStr == "progress"` — there is no enum case for it.
}

/// Phase 6.3 — Achievement-task completion trigger. Mirrors the TS
/// `AchievementTrigger` enum from `@oybc/shared`. Stored as the raw
/// string `"bingo"` / `"greenlog"` to match the wire format.
enum AchievementTrigger: String, Codable, DatabaseValueConvertible {
    case bingo
    case greenlog
}

/// Counter kinds — stored as the raw string (`"discrete"` / `"continuous"` /
/// `"duration"`), matching the wire format.
extension CountKind: DatabaseValueConvertible {}
