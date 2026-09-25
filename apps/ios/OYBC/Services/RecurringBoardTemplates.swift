import Foundation

// MARK: - Recurring board templates — Phase 6.2 (Preset-pool)
//
// Pure functions over `RecurringBoardTemplate[]` + `Board[]` + `Task[]`
// that mirror `packages/shared/src/algorithms/recurringBoardTemplates.ts`.
// No persistence, no platform-specific code beyond Foundation. Both
// platforms must keep these in lockstep — when the TS version changes,
// mirror it here in the same PR.
//
// Canonical design: docs/ARCHITECTURE.md §Phase 6.2.

/// One pending template + the window it's pending for. Consumed by the
/// platform spawn driver.
struct PendingTemplateSpawn {
    let template: RecurringBoardTemplate
    /// Local ISO8601 from `wizardLocalISOString(window.start)`.
    let windowStart: String
    /// Local ISO8601 from `wizardLocalISOString(window.end)`.
    let windowEnd: String
    /// Default name for the spawned board: "<template name> — <window label>".
    let suggestedName: String
}

/// Outcome of `validateSpawnPool`. Mirrors the TS-side `SpawnPoolValidation`.
enum SpawnPoolValidation: Equatable {
    case ok
    case failure(SpawnPoolFailureReason)
}

/// Pure-validation failure reasons returned by `validateSpawnPool`.
/// Strict mirror of TS `SpawnPoolFailureReason` in
/// `packages/shared/src/algorithms/recurringBoardTemplates.ts`.
///
/// Driver-only outcomes (`noPoolTasksResolved`, `spawnFailed`) live on
/// `SpawnAttentionReason` instead — keeping this enum a strict mirror
/// of the shared contract means a future cross-platform schema check
/// can compare the two enums as sets without filtering out platform
/// drift.
enum SpawnPoolFailureReason: String, Equatable {
    case poolTooSmall = "pool_too_small"
    case hasDeletedTasks = "has_deleted_tasks"
    case unsupportedTimeframe = "unsupported_timeframe"
    case unsupportedCenter = "unsupported_center"
}

/// Attention reason surfaced on a template row when the spawn driver
/// skipped or failed for a particular template. Superset of
/// `SpawnPoolFailureReason` plus the two driver-only outcomes:
/// `noPoolTasksResolved` (the resolved pool was empty — every seed
/// task got soft-deleted) and `spawnFailed` (the txn threw
/// unexpectedly).
///
/// Mirrors the TS-side union
/// `SpawnPoolFailureReason | 'no_pool_tasks_resolved' | 'spawn_failed'`
/// used in `useRecurringBoardSpawn.ts`'s `RecurringSpawnDigest`.
enum SpawnAttentionReason: String, Equatable {
    case poolTooSmall = "pool_too_small"
    case hasDeletedTasks = "has_deleted_tasks"
    case unsupportedTimeframe = "unsupported_timeframe"
    case unsupportedCenter = "unsupported_center"
    case noPoolTasksResolved = "no_pool_tasks_resolved"
    case spawnFailed = "spawn_failed"
    /// Board Sources P3 — a pulled board-kind source's board is deleted
    /// or archived. Unlike an EMPTY source (contributes nothing, never
    /// blocks), this blocks the window and the Boards tab ASKS the user
    /// (docs/BOARD_SOURCES.md §Boards as sources).
    case sourceBoardMissing = "source_board_missing"
}

extension SpawnAttentionReason {
    /// Lifts a pure validation failure into the wider attention enum.
    /// The wider enum is a strict superset, so the rawValue lookup is
    /// non-failable in practice; the `!` is documenting that invariant.
    init(_ failure: SpawnPoolFailureReason) {
        self = SpawnAttentionReason(rawValue: failure.rawValue)!
    }
}

/// Counts the cells that need a Task placement for a given board configuration.
/// Even-sized boards have no center; odd-sized boards with a FREE
/// center reserve one cell for the auto-completed free space; otherwise the
/// center cell gets a regular task.
func recurringTemplateFillableCellCount(
    boardSize: Int,
    centerSquareType: CenterSquareType
) -> Int {
    let total = boardSize * boardSize
    let hasCenter = boardSize % 2 == 1
    let centerOmitsTask = hasCenter && centerSquareType == .free
    return total - (centerOmitsTask ? 1 : 0)
}

/// Detects templates pending a spawn for the current window.
///
/// A template is pending when ALL of the following hold:
///   - `!isDeleted` AND `isActive`.
///   - `timeframe` is one of daily/weekly/monthly/yearly (custom excluded).
///   - The current window's `startDate` differs from `lastSpawnedWindowKey`.
///   - **Idempotency belt**: there is no existing non-deleted Board with
///     matching `spawnedFromTemplateId + startDate`.
///
/// Output ordering is the SPAWN order the caller must iterate: parents first
/// (yearly → monthly → weekly → daily, stable within a tier), then
/// dependency-ordered so a template spawns after every pending template whose
/// series it pulls from (cycles fall back to parents-first).
///
/// - Parameters:
///   - templates: All non-deleted templates for the active user.
///   - boards: All boards for the active user (the idempotency belt, and
///     resolving board sources to their series for the dependency order).
///   - weekStartDay: Controls weekly window boundaries (`"monday"` / `"sunday"`).
///   - now: Reference date for window computation.
func findTemplatesPendingSpawn(
    templates: [RecurringBoardTemplate],
    boards: [Board],
    weekStartDay: String,
    now: Date
) -> [PendingTemplateSpawn] {
    var pending: [PendingTemplateSpawn] = []

    for template in templates {
        if template.isDeleted { continue }
        if !template.isActive { continue }
        if template.timeframe == .custom { continue }

        guard let window = computeTimeframeBoundaries(
            timeframe: template.timeframe,
            referenceDate: now,
            weekStartDay: weekStartDay
        ) else { continue } // .custom — already filtered above, defensive

        let startISO = wizardLocalISOString(window.start)
        let endISO = wizardLocalISOString(window.end)

        if template.lastSpawnedWindowKey == startISO { continue }

        // Idempotency belt — see header doc.
        let alreadySpawned = boards.contains { board in
            !board.isDeleted &&
            board.spawnedFromTemplateId == template.id &&
            board.startDate == startISO
        }
        if alreadySpawned { continue }

        pending.append(PendingTemplateSpawn(
            template: template,
            windowStart: startISO,
            windowEnd: endISO,
            suggestedName: deriveSpawnedBoardName(template: template, windowStart: startISO)
        ))
    }

    // Series binding (loose-ends sweep 2026-09-09) — PARENTS SPAWN FIRST
    // (yearly → monthly → weekly → daily; stable within a tier) as the BASE
    // order, then DEPENDENCY-ORDERED (final-review F3): a template spawns
    // after every pending template whose series it pulls from, so its board
    // source binds to the series' instance open NOW — the one this pass just
    // spawned — instead of resolving `.noWindow`. TS twin:
    // `findTemplatesPendingSpawn`'s tail sort + `orderBySourceDependency`.
    func tier(_ timeframe: Timeframe) -> Int {
        switch timeframe {
        case .yearly: return 0
        case .monthly: return 1
        case .weekly: return 2
        case .daily: return 3
        default: return 4
        }
    }
    let parentsFirst = pending.enumerated().sorted { a, b in
        let ta = tier(a.element.template.timeframe)
        let tb = tier(b.element.template.timeframe)
        if ta != tb { return ta < tb }
        return a.offset < b.offset
    }.map { $0.element }
    return orderBySourceDependency(parentsFirst, boards: boards)
}

/// Stable topological order over board-source → series edges between the
/// pending spawns (final-review F3). An edge `S → T` exists when pending
/// template `T` has a `.board` source whose stored board belongs to pending
/// template `S`'s series (`spawnedFromTemplateId == S.id`). A self-edge (a
/// template pulling its own series) is ignored; a one-off source (no
/// `spawnedFromTemplateId`) or a series not pending in this pass adds no edge.
///
/// Kahn-style and stable: each step emits the FIRST entry in `base` order
/// whose dependencies are all emitted. When none is ready (a cycle), the
/// first remaining entry in `base` order is emitted — the cycle falls back to
/// the parents-first order, never traps. Mirrors the TS
/// `orderBySourceDependency`.
///
/// - Parameters:
///   - base: Pending spawns in parents-first order.
///   - boards: The user's boards (resolve a stored source id to its series).
/// - Returns: The same entries, dependency-ordered.
private func orderBySourceDependency(
    _ base: [PendingTemplateSpawn],
    boards: [Board]
) -> [PendingTemplateSpawn] {
    let pendingIds = Set(base.map { $0.template.id })
    var seriesByBoardId: [String: String] = [:]
    for b in boards {
        if let series = b.spawnedFromTemplateId, !series.isEmpty { seriesByBoardId[b.id] = series }
    }
    var deps: [String: Set<String>] = [:]
    for p in base {
        var own = Set<String>()
        for source in p.template.sources ?? [] where source.kind == .board {
            if let series = seriesByBoardId[source.sourceId],
               series != p.template.id, pendingIds.contains(series) {
                own.insert(series)
            }
        }
        deps[p.template.id] = own
    }
    var remaining = base
    var emitted = Set<String>()
    var ordered: [PendingTemplateSpawn] = []
    while !remaining.isEmpty {
        let pick = remaining.firstIndex { p in
            (deps[p.template.id] ?? []).allSatisfy { emitted.contains($0) }
        } ?? 0 // cycle → parents-first fallback
        let next = remaining.remove(at: pick)
        emitted.insert(next.template.id)
        ordered.append(next)
    }
    return ordered
}

/// "<template name> — <window label>" helper.
///
/// Takes the local ISO8601 string for parity with the TS counterpart
/// (`packages/shared/src/algorithms/recurringBoardTemplates.ts`'s
/// `deriveSpawnedBoardName(template, windowStart: string)`). Both
/// platforms now consume the same wire shape — a future change to
/// either side's date format won't silently desync the other.
func deriveSpawnedBoardName(template: RecurringBoardTemplate, windowStart: String) -> String {
    let trimmed = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let startDate = parseISO8601Date(windowStart) else {
        return trimmed.isEmpty ? "" : trimmed
    }
    // Absolute, not relative: this string is PERSISTED as the board's name.
    let label = formatWindowLabel(timeframe: template.timeframe, startDate: startDate)
    if trimmed.isEmpty { return label }
    return "\(trimmed) — \(label)"
}

/// Validates a template's pool. Mirrors the TS-side `validateSpawnPool`.
///
/// Pool semantics: `poolTasks.count >= required`. The spawn shuffles +
/// slices, so any extras become the random subset. The earlier
/// strict-fit `.all` strategy was dropped during the Phase 6.2 UX
/// rework — it was a special case of loose-fit where the user picked
/// exactly `required`.
func validateSpawnPool(
    template: RecurringBoardTemplate,
    poolTasks: [Task]
) -> SpawnPoolValidation {
    if template.timeframe == .custom {
        return .failure(.unsupportedTimeframe)
    }
    if template.centerSquareType == .chosen {
        return .failure(.unsupportedCenter)
    }
    if poolTasks.contains(where: { $0.isDeleted }) {
        return .failure(.hasDeletedTasks)
    }

    // Reject duplicate task ids in the resolved pool. Mirrors the
    // TS-side validateSpawnPool dedupe check. See its rationale.
    let uniqueIds = Set(poolTasks.map { $0.id })
    if uniqueIds.count != poolTasks.count {
        return .failure(.poolTooSmall)
    }

    let required = recurringTemplateFillableCellCount(
        boardSize: template.boardSize,
        centerSquareType: template.centerSquareType
    )
    if poolTasks.count < required { return .failure(.poolTooSmall) }
    return .ok
}

/// Builds the cell-by-cell placement for a spawn. Returns an array of
/// length `boardSize²` where each entry is a Task to place on that cell,
/// or `nil` for the auto-completed FREE center on odd-sized
/// boards.
///
/// Thin wrapper over the shared `BoardPlacement.placeBoard` core — mirrors
/// the TS-side `buildSpawnPlacement` (which now delegates to bingo-core's
/// `placeBoard`). Resolves the template's geometry / randomization / pool,
/// then delegates the cell walk. The spawn path never pins a CHOSEN center
/// (`validateSpawnPool` rejects CHOSEN templates), so no `chosenCenterId`
/// is passed — a CHOSEN center that slipped through is treated as ordinary,
/// exactly as the old hand-rolled loop did.
///
/// Optional `rng` parameter for deterministic test placement; passing a
/// seeded closure produces a stable order.
///
/// `validateSpawnPool` MUST be called first — this function's behavior is
/// undefined for a pool that fails validation.
func buildSpawnPlacement(
    template: RecurringBoardTemplate,
    poolTasks: [Task],
    rng: @escaping () -> Double = { Double.random(in: 0..<1) }
) -> [Task?] {
    BoardPlacement.placeBoard(
        items: poolTasks,
        gridSize: template.boardSize,
        centerType: template.centerSquareType,
        randomize: template.isRandomized,
        rng: rng
    )
}

// MARK: - "Repeat this board…" (Task Pools + Recurring Boards Rework, P6)
//
// docs/POOLS_RECURRING.md §Surfaces item 7 — a one-off board's Board screen
// offers `↻ Repeat this board…`, which mints a NEW spawn record from the
// board's current live tasks (as `manualTaskIds`, an own-mix repeating
// board with zero pools) and back-stamps the board's
// `spawnedFromTemplateId`. Unlike Phase 6.2's fresh-create spawn path, this
// does NOT spawn a new board immediately — the board being repeated IS this
// window's board, so an immediate spawn would double it up.

/// The fields needed to construct a new `RecurringBoardTemplate` from an
/// existing one-off board. Pure value object — `AppDatabase.repeatBoardAsTemplate`
/// is responsible for minting the id/timestamps and performing the write.
struct RepeatBoardTemplateInput {
    let name: String
    /// The CHOSEN cadence, NOT `board.timeframe` — a repeating board's
    /// cadence becomes its timeframe going forward.
    let timeframe: Timeframe
    let boardSize: Int
    let centerSquareType: CenterSquareType
    let isRandomized: Bool
    let manualTaskIds: [String]
    /// Always `true` — a freshly-repeated board starts active.
    let isActive: Bool
    let lastSpawnedWindowKey: String
    /// Decode-compat snapshot, mirrors `manualTaskIds` verbatim (see
    /// `RecurringBoardTemplate`'s `seedTaskIds` doc — never read live).
    let seedTaskIds: [String]
    /// Always empty — an own-mix repeating board pulls no pools.
    let poolIds: [String]
    /// Always empty — nothing to remove from an empty pool union.
    let removedTaskIds: [String]
}

/// Builds the `RepeatBoardTemplateInput` for "Repeat this board…".
///
/// `lastSpawnedWindowKey` is computed against the CADENCE's window
/// (`computeTimeframeBoundaries(timeframe: cadence, ...)`), never the
/// board's own `timeframe` — a one-off Tuesday `.daily` board repeated
/// `.weekly` must key off that Tuesday's WEEK window, not the day. Getting
/// this wrong silently double-spawns mid-window on the next Boards-tab
/// open (`findTemplatesPendingSpawn` would see a stale key and fire).
///
/// - Parameters:
///   - boardName: The source board's name — carried forward as the
///     template's name.
///   - boardSize: The source board's grid size.
///   - centerSquareType: The source board's center type.
///   - isRandomized: The source board's shuffle setting.
///   - boardStartDate: The source board's `startDate` (ISO8601) — the
///     anchor for locating the cadence window that contains it.
///   - boardTaskIds: Caller-resolved distinct, non-deleted, non-FREE-center
///     task ids currently placed on the board, in placement order.
///   - cadence: The user-chosen repeat cadence (Daily/Weekly/Monthly/Yearly
///     — `.custom`/`.indefinite` never reach here; the picker doesn't offer
///     them).
///   - weekStartDay: `"monday"` / `"sunday"` — only affects `.weekly`.
/// - Returns: `nil` only on an unparseable `boardStartDate` (should never
///   happen for a live board).
func buildRepeatBoardTemplateInput(
    boardName: String,
    boardSize: Int,
    centerSquareType: CenterSquareType,
    isRandomized: Bool,
    boardStartDate: String,
    boardTaskIds: [String],
    cadence: Timeframe,
    weekStartDay: String
) -> RepeatBoardTemplateInput? {
    guard let anchor = parseISO8601Date(boardStartDate) else { return nil }
    guard let window = computeTimeframeBoundaries(
        timeframe: cadence,
        referenceDate: anchor,
        weekStartDay: weekStartDay
    ) else { return nil } // cadence is never .custom/.indefinite in practice — defensive

    let windowKey = wizardLocalISOString(window.start)

    return RepeatBoardTemplateInput(
        name: boardName,
        timeframe: cadence,
        boardSize: boardSize,
        centerSquareType: centerSquareType,
        isRandomized: isRandomized,
        manualTaskIds: boardTaskIds,
        isActive: true,
        lastSpawnedWindowKey: windowKey,
        seedTaskIds: boardTaskIds,
        poolIds: [],
        removedTaskIds: []
    )
}
