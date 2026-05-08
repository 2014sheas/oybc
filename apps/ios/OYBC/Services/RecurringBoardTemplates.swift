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

enum SpawnPoolFailureReason: String, Equatable {
    case poolTooSmall = "pool_too_small"
    case poolWrongSize = "pool_wrong_size"
    case hasDeletedTasks = "has_deleted_tasks"
    case invalidStrategy = "invalid_strategy"
    case unsupportedTimeframe = "unsupported_timeframe"
    case unsupportedCenter = "unsupported_center"
    case noPoolTasksResolved = "no_pool_tasks_resolved"
}

/// Counts the cells that need a Task placement for a given board configuration.
/// Even-sized boards have no center; odd-sized boards with FREE/CUSTOM_FREE
/// centers reserve one cell for the auto-completed free space; otherwise the
/// center cell gets a regular task.
func recurringTemplateFillableCellCount(
    boardSize: Int,
    centerSquareType: CenterSquareType
) -> Int {
    let total = boardSize * boardSize
    let hasCenter = boardSize % 2 == 1
    let centerOmitsTask = hasCenter && (centerSquareType == .free || centerSquareType == .customFree)
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
/// - Parameters:
///   - templates: All non-deleted templates for the active user.
///   - boards: All boards for the active user (for the idempotency belt).
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
            suggestedName: deriveSpawnedBoardName(template: template, windowStart: window.start)
        ))
    }

    return pending
}

/// "<template name> — <window label>" helper.
func deriveSpawnedBoardName(template: RecurringBoardTemplate, windowStart: Date) -> String {
    let trimmed = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let label = playgroundTimeframeLabel(timeframe: template.timeframe, startDate: windowStart)
    if trimmed.isEmpty { return label }
    return "\(trimmed) — \(label)"
}

/// Validates a template's pool against its `poolStrategy`.
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

    switch template.poolStrategy {
    case .all:
        if poolTasks.count < required { return .failure(.poolTooSmall) }
        if poolTasks.count > required { return .failure(.poolWrongSize) }
        return .ok
    case .randomSubset:
        if poolTasks.count < required { return .failure(.poolTooSmall) }
        return .ok
    }
}

/// Builds the cell-by-cell placement for a spawn. Returns an array of
/// length `boardSize²` where each entry is a Task to place on that cell,
/// or `nil` for the auto-completed FREE / CUSTOM_FREE center on odd-sized
/// boards.
///
/// Mirrors the TS-side `buildSpawnPlacement`. Optional `rng` parameter
/// (default uses Foundation's `Int.random`) for deterministic test
/// placement; passing a closure that returns the same value each call
/// produces a stable order.
///
/// `validateSpawnPool` MUST be called first — this function's behavior is
/// undefined for a pool that fails validation.
func buildSpawnPlacement(
    template: RecurringBoardTemplate,
    poolTasks: [Task],
    rng: @escaping () -> Double = { Double.random(in: 0..<1) }
) -> [Task?] {
    let total = template.boardSize * template.boardSize
    let centerIdx = template.boardSize % 2 == 1
        ? (template.boardSize * template.boardSize) / 2
        : -1
    let hasCenter = centerIdx >= 0
    let centerOmitsTask = hasCenter &&
        (template.centerSquareType == .free || template.centerSquareType == .customFree)

    let fillCount = recurringTemplateFillableCellCount(
        boardSize: template.boardSize,
        centerSquareType: template.centerSquareType
    )

    let placed: [Task]
    switch template.poolStrategy {
    case .randomSubset:
        // Always shuffle for random_subset — otherwise the slice would always
        // pick the first N, defeating the random semantics.
        placed = Array(fisherYatesShuffle(poolTasks, rng: rng).prefix(fillCount))
    case .all:
        placed = template.isRandomized
            ? fisherYatesShuffle(poolTasks, rng: rng)
            : Array(poolTasks.prefix(fillCount))
    }

    var placement: [Task?] = Array(repeating: nil, count: total)
    var nextTaskIdx = 0
    for cell in 0..<total {
        if cell == centerIdx && centerOmitsTask { continue }
        if nextTaskIdx < placed.count {
            placement[cell] = placed[nextTaskIdx]
        }
        nextTaskIdx += 1
    }
    return placement
}

/// Fisher-Yates shuffle with injectable RNG. Mirrors the TS-side
/// `fisherYatesShuffle(arr, rng?)`. Local helper because Swift's
/// `.shuffled()` doesn't expose an RNG hook.
func fisherYatesShuffle<T>(_ array: [T], rng: () -> Double = { Double.random(in: 0..<1) }) -> [T] {
    var result = array
    var i = result.count - 1
    while i > 0 {
        let j = Int(rng() * Double(i + 1))
        let clamped = min(j, i)
        result.swapAt(i, clamped)
        i -= 1
    }
    return result
}
