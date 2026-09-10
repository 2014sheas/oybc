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
///
/// **Counter-family exclusivity** (owner directive 2026-09-08): at most
/// ONE member of a shared-counter family (`sharedCounterId` root + its
/// derived versions) lands on a board. Priority: pinned CHOSEN center >
/// hand-added > covering-an-unmet-min > the draw. **The gate never
/// overpromises**: `computeSourceCapacity`'s `capacity` is a deterministic
/// dry-run of this same fill, and a short randomized deal retries in the
/// dry-run's deterministic order — gate-passed ⇒ the board fills.
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
        /// Distinct placeable things (manual ∪ availables), counting a
        /// shared-counter family ONCE.
        let uniqueCandidateCount: Int
        /// Σ per-source effective max + distinct manual tasks NO source
        /// supplies (informational; `capacity` is the honest number).
        let cappedBound: Int
        /// The honest achievable pool size: a deterministic dry-run of the
        /// actual fill (caps, overlap, family rule, the pinned center) —
        /// what the header/gate compares against the fillable cell count.
        /// Gate-passed ⇒ the deal fills (the deal's deterministic retry is
        /// a prefix of this dry-run).
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

    /// The header/gate math (docs/BOARD_SOURCES.md §Selection step 3) —
    /// with `capacity` computed as the achievable dry-run size. TS twin:
    /// `computeSourceCapacity`.
    static func computeSourceCapacity(
        _ supplies: [Supply],
        manualTaskIds: [String],
        counterFamilyByTaskId: [String: String] = [:],
        pinnedTaskId: String? = nil
    ) -> CapacityResult {
        func familyKey(_ id: String) -> String { counterFamilyByTaskId[id] ?? id }
        var unique = Set(manualTaskIds.map(familyKey))
        var suppliedAnywhere = Set<String>()
        var capSum = 0
        for supply in supplies {
            let available = resolveSourceAvailable(supply)
            capSum += effectiveSourceMax(supply.source, availableCount: available.count)
            for id in available {
                unique.insert(familyKey(id))
                suppliedAnywhere.insert(id)
            }
        }
        let manualOutside = Set(
            manualTaskIds.filter { !suppliedAnywhere.contains($0) }.map(familyKey)
        ).count
        let cappedBound = capSum + manualOutside
        return CapacityResult(
            uniqueCandidateCount: unique.count,
            cappedBound: cappedBound,
            capacity: computeAchievablePoolSize(
                supplies: supplies,
                manualTaskIds: manualTaskIds,
                counterFamilyByTaskId: counterFamilyByTaskId,
                pinnedTaskId: pinnedTaskId
            ).size
        )
    }

    /// The honest pool size: a deterministic, uncapped dry-run of the
    /// exact fill `selectBoardTasks` performs. TS twin:
    /// `computeAchievablePoolSize`.
    static func computeAchievablePoolSize(
        supplies: [Supply],
        manualTaskIds: [String],
        counterFamilyByTaskId: [String: String] = [:],
        pinnedTaskId: String? = nil
    ) -> (size: Int, taskIds: [String]) {
        let taskIds = runSelection(
            supplies: supplies,
            manualTaskIds: manualTaskIds,
            cellCount: Int.max,
            randomize: false,
            rng: { 0 },
            counterFamilyByTaskId: counterFamilyByTaskId,
            pinnedTaskId: pinnedTaskId
        )
        return (taskIds.count, taskIds)
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
    ///   - randomize: The template's `isRandomized`. When false the fill
    ///     is fully deterministic in candidate order — for `[0, all]`
    ///     shapes this reproduces the pre-sources `resolveMix`-order
    ///     first-N slice exactly (same subset when overfilled, same
    ///     order), preserving `placeBoard`'s documented determinism
    ///     contract for its callers.
    ///   - rng: Uniform `[0, 1)` generator. Tests pass the shared seeded
    ///     LCG so vectors pin exact outputs on both platforms.
    ///   - counterFamilyByTaskId: Counter-family exclusivity — task id →
    ///     family key (`buildCounterFamilyMap`). At most one member of a
    ///     family is picked; the pinned center's mates are pruned, a
    ///     family with hand-added AND source-only members prunes the
    ///     source-only ones, remaining ties resolve at draw time.
    ///   - pinnedTaskId: The CHOSEN center — its family-mates are pruned
    ///     so the caller-side center swap can never collide. Not
    ///     force-picked here.
    ///
    /// A short RANDOMIZED run retries once in deterministic candidate
    /// order (the capacity dry-run's order) — an unlucky shuffle under
    /// pathological cap overlap costs that deal its variety, never its
    /// board.
    static func selectBoardTasks(
        supplies: [Supply],
        manualTaskIds: [String],
        cellCount: Int,
        randomize: Bool = true,
        rng: () -> Double = { Double.random(in: 0..<1) },
        counterFamilyByTaskId: [String: String] = [:],
        pinnedTaskId: String? = nil
    ) -> SelectionResult {
        let first = runSelection(
            supplies: supplies,
            manualTaskIds: manualTaskIds,
            cellCount: cellCount,
            randomize: randomize,
            rng: rng,
            counterFamilyByTaskId: counterFamilyByTaskId,
            pinnedTaskId: pinnedTaskId
        )
        if first.count >= cellCount {
            return .ok(taskIds: Array(first.prefix(cellCount)))
        }
        let fallback = randomize
            ? runSelection(
                supplies: supplies,
                manualTaskIds: manualTaskIds,
                cellCount: cellCount,
                randomize: false,
                rng: { 0 },
                counterFamilyByTaskId: counterFamilyByTaskId,
                pinnedTaskId: pinnedTaskId
            )
            : first
        if fallback.count >= cellCount {
            return .ok(taskIds: Array(fallback.prefix(cellCount)))
        }
        return .short(shortBy: cellCount - fallback.count)
    }

    /// The shared fill core — one code path for the deal, its
    /// deterministic retry, and the capacity dry-run (the alignment
    /// guarantee). TS twin: `runSelection`.
    private static func runSelection(
        supplies: [Supply],
        manualTaskIds: [String],
        cellCount: Int,
        randomize: Bool,
        rng: () -> Double,
        counterFamilyByTaskId: [String: String],
        pinnedTaskId: String?
    ) -> [String] {
        func order(_ ids: [String]) -> [String] {
            randomize ? Shuffle.fisherYatesShuffle(ids, rng: rng) : ids
        }
        let availables = supplies.map { resolveSourceAvailable($0) }
        let availableSets = availables.map { Set($0) }
        let caps = supplies.enumerated().map { i, supply in
            effectiveSourceMax(supply.source, availableCount: availables[i].count)
        }
        var memberCounts = [Int](repeating: 0, count: supplies.count)

        // Candidate universe, first-seen order: sources in row order, then
        // any manual-only ids appended — the SAME deterministic order
        // `resolveMix` produced (pool union first, manual extras last), so
        // the `randomize: false` path slices the identical first-N the old
        // spawn did. (Membership caps are set-based, so candidate position
        // never affects WHICH source a pick counts against.)
        var candidateSeen = Set<String>()
        var candidates: [String] = []
        for available in availables {
            for id in available where !candidateSeen.contains(id) {
                candidateSeen.insert(id)
                candidates.append(id)
            }
        }
        for id in manualTaskIds where !candidateSeen.contains(id) {
            candidateSeen.insert(id)
            candidates.append(id)
        }

        var picked: [String] = []
        var pickedSet = Set<String>()

        // Counter-family exclusivity — priority pruning up front, then a
        // runtime one-per-family guard for whatever the pruning left tied.
        func familyOf(_ id: String) -> String? { counterFamilyByTaskId[id] }
        var blocked = Set<String>()
        if !counterFamilyByTaskId.isEmpty {
            var membersByFamily: [String: [String]] = [:]
            for id in candidates {
                guard let fam = familyOf(id) else { continue }
                membersByFamily[fam, default: []].append(id)
            }
            let manualSet = Set(manualTaskIds)
            let pinnedFamily = pinnedTaskId.flatMap { familyOf($0) }
            for (fam, members) in membersByFamily {
                if fam == pinnedFamily {
                    // The pinned CHOSEN center wins its family outright.
                    for id in members where id != pinnedTaskId { blocked.insert(id) }
                    continue
                }
                if members.count < 2 { continue }
                // Hand-added beats source-supplied; ties fall through to
                // the runtime guard = the draw.
                let handAdded = members.filter { manualSet.contains($0) }
                if !handAdded.isEmpty && handAdded.count < members.count {
                    for id in members where !manualSet.contains(id) { blocked.insert(id) }
                }
            }
        }
        var pickedFamilies = Set<String>()

        func admissible(_ id: String) -> Bool {
            if blocked.contains(id) { return false }
            if let fam = familyOf(id), pickedFamilies.contains(fam) { return false }
            for i in supplies.indices {
                if availableSets[i].contains(id) && memberCounts[i] >= caps[i] { return false }
            }
            return true
        }
        func pick(_ id: String) {
            picked.append(id)
            pickedSet.insert(id)
            if let fam = familyOf(id) { pickedFamilies.insert(fam) }
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
            let shuffledOwn = order(availables[i].filter { !pickedSet.contains($0) })
            for id in shuffledOwn {
                if memberCounts[i] >= target || picked.count >= cellCount { break }
                if !admissible(id) { continue }
                pick(id)
            }
        }

        // Phase B — fill the remaining cells from every remaining
        // admissible candidate: at random when randomized, in candidate
        // order when not.
        let shuffledRest = order(candidates.filter { !pickedSet.contains($0) })
        for id in shuffledRest {
            if picked.count >= cellCount { break }
            if !admissible(id) { continue }
            pick(id)
        }

        return picked
    }

    /// Task id → counter-family key: counting tasks map to
    /// `sharedCounterId ?? id`; other types get no entry. TS twin:
    /// `buildCounterFamilyMap`.
    static func buildCounterFamilyMap<S: Sequence>(
        _ tasks: S
    ) -> [String: String] where S.Element == Task {
        var map: [String: String] = [:]
        for task in tasks where task.type == .counting {
            map[task.id] = task.sharedCounterId ?? task.id
        }
        return map
    }

    /// True when a task type may enter source supply (pools and pulled
    /// boards). ACHIEVEMENT is banned (owner decision, 2026-09-10):
    /// watcher tasks are hand-placed only — the pool use case is too
    /// niche to carry, and the spawn/deal path runs no cycle check, so a
    /// dealt achievement watching its own series would deadlock its spawn
    /// (greenlog trigger). Enforced at supply resolution (not just in
    /// pickers) so legacy pool members and synced data are excluded
    /// uniformly. Mirrors web `isSourceSupplyTask` in
    /// `packages/shared/src/algorithms/boardSources.ts` — keep in
    /// lockstep.
    static func isSourceSupplyTask(_ task: Task) -> Bool {
        task.type != .achievement
    }

    /// Raw supply for a pool-kind source: the pool's own `taskIds`,
    /// filtered to present + non-deleted + supply-eligible
    /// (`isSourceSupplyTask`) tasks, order preserved. A missing or
    /// soft-deleted pool supplies nothing (derived detachment).
    static func poolSourceSupplyById(
        _ sourceId: String,
        poolsById: [String: Pool],
        tasksById: [String: Task]
    ) -> [String] {
        guard let pool = poolsById[sourceId], !pool.isDeleted else { return [] }
        return pool.taskIds.filter { taskId in
            guard let task = tasksById[taskId] else { return false }
            return !task.isDeleted && isSourceSupplyTask(task)
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
