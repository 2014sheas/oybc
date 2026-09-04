import Foundation

/// BoardSources — Board Sources rework (docs/BOARD_SOURCES.md, P1). Swift
/// port of `packages/shared/src/algorithms/boardSources.ts`, case-for-case.
/// Pure functions; no persistence. Both platforms keep these in lockstep —
/// when the TS version changes, mirror it here in the same PR. Pinned by
/// the shared vector fixture (`OYBCTests/BoardSourceVectorTests.swift` ↔
/// `packages/shared/tests/algorithms/boardSources.test.ts` over
/// `boardSourceVectors.json`).
///
/// **Selection semantics (normative):** ranges are MEMBERSHIP constraints —
/// for every source i, `min_i ≤ |board ∩ available_i| ≤ effectiveMax_i`.
/// No pick is attributed to one source: a task supplied by two sources
/// counts toward both memberships (and may satisfy two mins at once); a
/// manual task a source also supplies counts toward that source's cap.
/// `max == nil` is the "all" latch (effective max = live available count).
/// Mins clamp, never error. Fill order: mins first (sources in row order,
/// random within the source), then remaining cells at random from all
/// remaining admissible candidates. Never underfills silently.
enum BoardSources {

    /// One source plus its platform-resolved RAW supply (before excludes).
    /// Pool sources: `poolSourceSupplyById`. Board sources: resolved by
    /// the platform with the `.todo` filter already applied (P2); an
    /// unresolvable source passes `[]` — contributes nothing, never blocks.
    struct Supply {
        let source: BoardSource
        let supplyTaskIds: [String]
    }

    /// Result of `computeSourceCapacity` — TS twin `SourceCapacityResult`.
    struct CapacityResult: Equatable {
        /// Distinct tasks that could possibly appear (manual ∪ availables).
        let uniqueCandidateCount: Int
        /// Σ per-source effective max + distinct manual tasks NO source
        /// supplies (a manual task inside a source counts toward that
        /// source's membership cap instead).
        let cappedBound: Int
        /// `min(uniqueCandidateCount, cappedBound)` — what the header/gate
        /// compares against the fillable cell count.
        let capacity: Int
    }

    /// Result of `selectBoardTasks` — TS twin `SelectBoardTasksResult`.
    enum SelectionResult: Equatable {
        case ok(taskIds: [String])
        case short(shortBy: Int)
    }

    /// A source's AVAILABLE list: raw supply − `excludedTaskIds`, deduped,
    /// order preserved. Stale-inert excludes subtract nothing (by design).
    static func resolveSourceAvailable(_ supply: Supply) -> [String] {
        let excluded = Set(supply.source.excludedTaskIds)
        var seen = Set<String>()
        var out: [String] = []
        for id in supply.supplyTaskIds {
            if excluded.contains(id) || seen.contains(id) { continue }
            seen.insert(id)
            out.append(id)
        }
        return out
    }

    /// `max == nil` = the "all" latch → the live available count.
    static func effectiveSourceMax(_ source: BoardSource, availableCount: Int) -> Int {
        guard let max = source.max else { return availableCount }
        return Swift.min(max, availableCount)
    }

    /// The header/gate math (docs/BOARD_SOURCES.md §Selection step 3):
    /// "sum of every source's max + hand-added, deduped by task".
    static func computeSourceCapacity(
        _ supplies: [Supply],
        manualTaskIds: [String]
    ) -> CapacityResult {
        var unique = Set(manualTaskIds)
        var suppliedAnywhere = Set<String>()
        var capSum = 0
        for supply in supplies {
            let available = resolveSourceAvailable(supply)
            capSum += effectiveSourceMax(supply.source, availableCount: available.count)
            for id in available {
                unique.insert(id)
                suppliedAnywhere.insert(id)
            }
        }
        let manualOutside = Set(manualTaskIds.filter { !suppliedAnywhere.contains($0) }).count
        let cappedBound = capSum + manualOutside
        return CapacityResult(
            uniqueCandidateCount: unique.count,
            cappedBound: cappedBound,
            capacity: Swift.min(unique.count, cappedBound)
        )
    }

    /// Picks exactly `cellCount` task ids satisfying every source's
    /// membership range, or reports how short the candidate pool ran.
    /// Never returns an underfilled `.ok` — boards are always exactly
    /// filled (standing invariant). TS twin: `selectBoardTasks`.
    ///
    /// - Parameters:
    ///   - supplies: Per-source raw supplies (see `Supply`).
    ///   - manualTaskIds: Hand-added layer — unconstrained candidates
    ///     (but counting toward the cap of any source that supplies them).
    ///   - cellCount: `fillableCellCount(size, center)`.
    ///   - rng: Uniform `[0, 1)` generator. Tests pass the shared seeded
    ///     LCG so vectors pin exact outputs on both platforms.
    static func selectBoardTasks(
        supplies: [Supply],
        manualTaskIds: [String],
        cellCount: Int,
        rng: () -> Double = { Double.random(in: 0..<1) }
    ) -> SelectionResult {
        let availables = supplies.map { resolveSourceAvailable($0) }
        let availableSets = availables.map { Set($0) }
        let caps = supplies.enumerated().map { i, supply in
            effectiveSourceMax(supply.source, availableCount: availables[i].count)
        }
        var memberCounts = [Int](repeating: 0, count: supplies.count)

        // Candidate universe, first-seen order: manual, then sources.
        var candidateSeen = Set<String>()
        var candidates: [String] = []
        for id in manualTaskIds where !candidateSeen.contains(id) {
            candidateSeen.insert(id)
            candidates.append(id)
        }
        for available in availables {
            for id in available where !candidateSeen.contains(id) {
                candidateSeen.insert(id)
                candidates.append(id)
            }
        }

        var picked: [String] = []
        var pickedSet = Set<String>()

        func admissible(_ id: String) -> Bool {
            for i in supplies.indices {
                if availableSets[i].contains(id) && memberCounts[i] >= caps[i] { return false }
            }
            return true
        }
        func pick(_ id: String) {
            picked.append(id)
            pickedSet.insert(id)
            for i in supplies.indices where availableSets[i].contains(id) {
                memberCounts[i] += 1
            }
        }

        // Phase A — satisfy mins, sources in row order. A task already
        // picked (manual overlap / earlier source) counts toward this
        // source's membership, so `target` may already be met.
        for i in supplies.indices {
            let target = Swift.min(
                Swift.max(0, supplies[i].source.min),
                availables[i].count,
                caps[i],
                cellCount
            )
            if memberCounts[i] >= target { continue }
            let shuffledOwn = Shuffle.fisherYatesShuffle(
                availables[i].filter { !pickedSet.contains($0) },
                rng: rng
            )
            for id in shuffledOwn {
                if memberCounts[i] >= target || picked.count >= cellCount { break }
                if !admissible(id) { continue }
                pick(id)
            }
        }

        // Phase B — fill the remaining cells at random from every
        // remaining admissible candidate.
        let shuffledRest = Shuffle.fisherYatesShuffle(
            candidates.filter { !pickedSet.contains($0) },
            rng: rng
        )
        for id in shuffledRest {
            if picked.count >= cellCount { break }
            if !admissible(id) { continue }
            pick(id)
        }

        if picked.count < cellCount {
            return .short(shortBy: cellCount - picked.count)
        }
        return .ok(taskIds: picked)
    }

    /// Raw supply for a pool-kind source: the pool's own `taskIds`,
    /// filtered to present + non-deleted tasks, order preserved. A missing
    /// or soft-deleted pool supplies nothing (derived detachment).
    static func poolSourceSupplyById(
        _ sourceId: String,
        poolsById: [String: Pool],
        tasksById: [String: Task]
    ) -> [String] {
        guard let pool = poolsById[sourceId], !pool.isDeleted else { return [] }
        return pool.taskIds.filter { taskId in
            guard let task = tasksById[taskId] else { return false }
            return !task.isDeleted
        }
    }

    /// Legacy trio → sources: each pulled pool becomes a `[0, all]` pool
    /// source carrying the FULL flat `removedTaskIds` list as its excludes
    /// (semantically identical to the old global suppression; inert
    /// extras — docs/BOARD_SOURCES.md §Migration). TS twin:
    /// `sourcesFromMixFields`.
    static func sourcesFromMixFields(
        poolIds: [String]?,
        removedTaskIds: [String]?
    ) -> [BoardSource] {
        let removed = removedTaskIds ?? []
        return (poolIds ?? []).map { poolId in
            BoardSource(
                sourceId: poolId,
                kind: .pool,
                min: 0,
                max: nil,
                excludedTaskIds: removed,
                filter: .all
            )
        }
    }

    /// Sources → legacy trio mirror, written alongside `sources` during P1
    /// so every pre-rework reader (roster health, provenance, an old
    /// client) keeps working. Lossy by design: ranges and board-kind
    /// sources have no legacy representation. TS twin:
    /// `mixFieldsFromSources`.
    static func mixFieldsFromSources(
        _ sources: [BoardSource]
    ) -> (poolIds: [String], removedTaskIds: [String]) {
        var poolIds: [String] = []
        var removedSeen = Set<String>()
        var removed: [String] = []
        for source in sources {
            if source.kind == .pool && !poolIds.contains(source.sourceId) {
                poolIds.append(source.sourceId)
            }
            for id in source.excludedTaskIds where !removedSeen.contains(id) {
                removedSeen.insert(id)
                removed.append(id)
            }
        }
        return (poolIds, removed)
    }

    /// The canonical read path for a record that may or may not carry the
    /// P1 `sources` stamp yet: the stamped array when present, else the
    /// legacy trio mapped on the fly. Works forever for rows written by
    /// old clients — no data backfill required. TS twin: `sourcesForRecord`.
    static func sourcesForRecord(
        sources: [BoardSource]?,
        poolIds: [String]?,
        removedTaskIds: [String]?
    ) -> [BoardSource] {
        sources ?? sourcesFromMixFields(poolIds: poolIds, removedTaskIds: removedTaskIds)
    }
}
