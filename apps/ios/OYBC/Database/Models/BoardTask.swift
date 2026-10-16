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
    /// Board Edit redesign slice 1 (docs/BOARD_EDIT_REDESIGN.md) — a locked
    /// placement never changes position (Shuffle and every move skip it; it
    /// is not a drop target) but stays completable. Absent in pre-feature
    /// rows / peer payloads ⇒ `false` (GRDB migration v34 backfills 0).
    var isLocked: Bool = false

    // ── Per-placement parameters (docs/TASK_WINDOW_REWORK.md, slice 1) ──
    // All optional, absent on every pre-rework row (GRDB v45 adds nullable
    // columns). INERT in slice 1: no reader (slice 2), no writer (slice 3).
    // Mirrors the TS `BoardTask` fields; `childTargets` is stored as a
    // sorted-keys JSON string (like `Board.sealedCompletedCells`) and
    // expanded to a native array on push (`SyncWirePayload`).
    /// A counting placement's goal for THIS board (frozen; ruling 1). Absent ⇒ the task's own `maxCount`.
    var targetOverride: CountValue?
    /// The kind `targetOverride` is expressed in; kept only alongside an override (ruling 5).
    var targetKind: CountKind?
    /// A compound placement's per-child goals, keyed by the compound's DIRECT child ids; sorted, unique.
    var childTargets: [PlacementChildTarget]?
    /// A per-board title for a counter square (ruling 4: a rename never forks).
    var titleOverride: String?

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
        isLocked: Bool = false,
        targetOverride: CountValue? = nil,
        targetKind: CountKind? = nil,
        childTargets: [PlacementChildTarget]? = nil,
        titleOverride: String? = nil,
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
        self.isLocked = isLocked
        let norm = Self.normalizedPlacementFields(
            targetOverride: targetOverride, targetKind: targetKind, childTargets: childTargets, titleOverride: titleOverride
        )
        self.targetOverride = norm.targetOverride
        self.targetKind = norm.targetKind
        self.childTargets = norm.childTargets
        self.titleOverride = norm.titleOverride
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
        self.version = version
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, boardId, taskId, row, col, isCenter, isLocked
        case targetOverride, targetKind, childTargets, titleOverride
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
        // Slice 1 lock — same forward-compat posture as `isDeleted` below
        // (v34 adds the column; pre-feature payloads carry no key).
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        // Slice 1 placement parameters — each decoded leniently (a bad value
        // ⇒ absent, never a thrown decode that drops the placement), then the
        // cross-field rules of `normalizedPlacementFields` (twin of the TS
        // `normalizePlacementFields`).
        let rawTarget = (try? container.decodeIfPresent(CountValue.self, forKey: .targetOverride)) ?? nil
        let rawKind = (try? container.decodeIfPresent(CountKind.self, forKey: .targetKind)) ?? nil
        let rawChildren = Self.decodeChildTargets(container)
        let rawTitle = (try? container.decodeIfPresent(String.self, forKey: .titleOverride)) ?? nil
        let norm = Self.normalizedPlacementFields(
            targetOverride: rawTarget, targetKind: rawKind, childTargets: rawChildren, titleOverride: rawTitle
        )
        targetOverride = norm.targetOverride
        targetKind = norm.targetKind
        childTargets = norm.childTargets
        titleOverride = norm.titleOverride
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
        try container.encode(isLocked, forKey: .isLocked)
        // Key-skipped when nil (NOT `encodeIfPresent`, which GRDB writes as a
        // NULL column — a pre-v45 schema must still accept the row, see
        // `MigrationV40DataSurvivalTests`): an absent parameter is the default,
        // and on the wire an absent key is what the clearable-field delete
        // (`clearableFieldsByCollection["boardTasks"]`) keys on. The flip side,
        // as with `Task.counterName` et al.: `save()` never NULLs a column a
        // value was removed from — a slice-3 writer that CLEARS a parameter
        // must write the NULL explicitly (`writePlacementFieldColumns`, to come).
        if let t = targetOverride { try container.encode(t, forKey: .targetOverride) }
        if let k = targetKind { try container.encode(k, forKey: .targetKind) }
        if let json = Self.childTargetsJSON(childTargets) {
            try container.encode(json, forKey: .childTargets)
        }
        if let title = titleOverride { try container.encode(title, forKey: .titleOverride) }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(version, forKey: .version)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}

/// One entry of `BoardTask.childTargets` (TS twin `PlacementChildTarget`).
struct PlacementChildTarget: Codable, Equatable {
    /// The compound's direct child task id.
    let childId: String
    /// That child's goal on this board; positive, quantized to the child's kind.
    let target: CountValue
}

extension BoardTask {
    /// The canonical placement parameters (docs/TASK_WINDOW_REWORK.md slice 1).
    struct PlacementFields: Equatable {
        var targetOverride: CountValue?
        var targetKind: CountKind?
        var childTargets: [PlacementChildTarget]?
        var titleOverride: String?
    }

    /// Upper bound on a per-board title, matching the task title limit.
    static let titleOverrideMax = 200

    /// Normalise the placement parameters to their canonical stored shape —
    /// the one rule both platforms apply on decode (TS twin
    /// `normalizePlacementFields`, vector-pinned by `placementFieldsVectors.json`):
    ///
    /// - `targetOverride` must be finite, `> 0` and 2-dp quantized; for a whole
    ///   `targetKind` it must also be whole. Otherwise override AND kind drop.
    /// - `targetKind` is kept only alongside a kept override.
    /// - `childTargets`: non-empty `childId`, positive quantized `target`,
    ///   first entry per `childId` wins, sorted by `childId`; empty ⇒ nil.
    /// - `titleOverride`: trimmed; empty or over `titleOverrideMax` ⇒ nil.
    static func normalizedPlacementFields(
        targetOverride: CountValue?, targetKind: CountKind?, childTargets: [PlacementChildTarget]?, titleOverride: String?
    ) -> PlacementFields {
        var out = PlacementFields()
        if let t = targetOverride, t.isFinite, t > 0, isQuantizedCount(t),
           !(targetKind.map { isWholeCountKind($0) && t.rounded() != t } ?? false) {
            out.targetOverride = t
            out.targetKind = targetKind
        }
        if let entries = childTargets {
            var seen = Set<String>()
            var kept: [PlacementChildTarget] = []
            for e in entries {
                guard !e.childId.isEmpty, !seen.contains(e.childId), e.target.isFinite, e.target > 0, isQuantizedCount(e.target) else { continue }
                seen.insert(e.childId)
                kept.append(e)
            }
            kept.sort { $0.childId < $1.childId }
            if !kept.isEmpty { out.childTargets = kept }
        }
        if let raw = titleOverride {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // UTF-16 code units, the unit JS `.length` / Zod `.max` count in (a
            // grapheme count would keep a 150-emoji title web drops).
            if !title.isEmpty, title.utf16.count <= titleOverrideMax { out.titleOverride = title }
        }
        return out
    }

    /// `childTargets` from a GRDB JSON string OR a native array (a pulled
    /// payload); entries that fail to decode drop the whole value (⇒ absent).
    private static func decodeChildTargets(_ container: KeyedDecodingContainer<CodingKeys>) -> [PlacementChildTarget]? {
        if let json = try? container.decodeIfPresent(String.self, forKey: .childTargets) {
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([PlacementChildTarget].self, from: data)
        }
        return (try? container.decodeIfPresent([PlacementChildTarget].self, forKey: .childTargets)) ?? nil
    }

    /// `childTargets` as its stored JSON string (sorted keys; nil when absent / empty).
    static func childTargetsJSON(_ targets: [PlacementChildTarget]?) -> String? {
        guard let targets, !targets.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(targets) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension BoardTask {
    /// Canonicalise the placement parameters of a PULLED `boardTasks` doc in
    /// place, before `upsertPulledRecord` writes its raw columns — the pull
    /// path never decodes the model, so without this the stored row would not
    /// be the canonical one `init(from:)` / web's pull parse produce (orphan
    /// kind, untrimmed title, unsorted `childTargets`). A dropped field is
    /// REMOVED from the dict so the clearable-field NULL applies.
    static func normalizePulledPlacementFields(_ data: inout [String: Any]) {
        let rawTarget: CountValue? = (data["targetOverride"] as? NSNumber)?.doubleValue
        let rawKind = (data["targetKind"] as? String).flatMap(CountKind.init(rawValue:))
        var rawChildren: [PlacementChildTarget]?
        if let entries = data["childTargets"] as? [Any] {
            rawChildren = entries.compactMap { e in
                guard let d = e as? [String: Any], let id = d["childId"] as? String,
                      let t = (d["target"] as? NSNumber)?.doubleValue else { return nil }
                return PlacementChildTarget(childId: id, target: t)
            }
        } else if let json = data["childTargets"] as? String, let bytes = json.data(using: .utf8) {
            rawChildren = try? JSONDecoder().decode([PlacementChildTarget].self, from: bytes)
        }
        let rawTitle = data["titleOverride"] as? String
        let norm = normalizedPlacementFields(
            targetOverride: rawTarget, targetKind: rawKind, childTargets: rawChildren, titleOverride: rawTitle
        )
        if let t = norm.targetOverride { data["targetOverride"] = t } else { data.removeValue(forKey: "targetOverride") }
        if let k = norm.targetKind { data["targetKind"] = k.rawValue } else { data.removeValue(forKey: "targetKind") }
        if let json = childTargetsJSON(norm.childTargets) { data["childTargets"] = json } else { data.removeValue(forKey: "childTargets") }
        if let title = norm.titleOverride { data["titleOverride"] = title } else { data.removeValue(forKey: "titleOverride") }
    }
}
