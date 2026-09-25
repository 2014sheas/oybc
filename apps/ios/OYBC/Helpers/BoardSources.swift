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

    /// A source's supply after its done-filter — the ids a platform hands
    /// in as `Supply.supplyTaskIds`. Only a BOARD source on `.todo` ("Not
    /// done yet") drops anything: the ids in `doneTaskIds` (complete in that
    /// board's window). A pool source, or a board source on `.all`, returns
    /// `supplyTaskIds` unchanged. Excludes are NOT applied here — that stays
    /// `resolveSourceAvailable`'s job. Order preserved; no dedupe.
    ///
    /// TS twin: `availableSupplyIds` (`packages/shared/src/algorithms/
    /// boardSources.ts`), pinned by `doneFilterVectors` in
    /// `boardSourceVectors.json`.
    ///
    /// - Parameters:
    ///   - source: The source row (only `kind` and `filter` are read).
    ///   - supplyTaskIds: The RAW supply (pre-filter, pre-exclude); `[]`
    ///     for an unresolved source.
    ///   - doneTaskIds: The supply ids complete in the source board's
    ///     window; empty for pools and unresolved sources.
    /// - Returns: The supply with the done-filter applied.
    static func availableSupplyIds(
        source: BoardSource,
        supplyTaskIds: [String],
        doneTaskIds: Set<String>
    ) -> [String] {
        guard source.kind == .board, source.filter == .todo else { return supplyTaskIds }
        return supplyTaskIds.filter { !doneTaskIds.contains($0) }
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

    /// The copy a board-kind source shows when it resolves to no board for
    /// the window being built (a series whose instance for that window
    /// doesn't exist yet, or a one-off board that has ended or been sealed)
    /// — the wizard's source-row subtitle and the spawn-provenance note both
    /// read it. TS twin: `NO_BOARD_FOR_WINDOW_NOTE`.
    static let noBoardForWindowNote = "No board for this window yet"

    /// True when a board may be offered as a source in the board wizard
    /// (the "Add from a pool or board" Sources sheet) and may SUPPLY squares
    /// to a stored source.
    ///
    /// Owner ruling 2026-09-24 (supersedes #482's 30-day lookback): "There
    /// is no REAL use case for ended boards as sources." A board is eligible
    /// only while its window is OPEN:
    ///
    /// - not deleted, not a draft, not archived (active or completed);
    /// - not sealed — a sealed board is a permanent record;
    /// - no `endDate` (an INDEFINITE board never ends), an unparseable
    ///   `endDate` (fail open), or `endDate >= now`.
    ///
    /// `endDate` is a LOCAL-wall-clock ISO string; it is compared as a parsed
    /// `Date` against `now`, never as a string against a UTC timestamp.
    ///
    /// TS twin: `isEligibleSourceBoard` — keep in lockstep (pinned by
    /// `eligibilityVectors` in `boardSourceVectors.json`).
    ///
    /// - Parameters:
    ///   - board: The candidate board.
    ///   - now: The instant to judge "has the window ended" against.
    /// - Returns: Whether the board may be offered as / supply a source.
    static func isEligibleSourceBoard<B: SourceBoardCandidate>(_ board: B, now: Date) -> Bool {
        if board.isDeleted { return false }
        guard board.status == .active || board.status == .completed else { return false }
        if board.sealedAt != nil { return false }
        guard let endDate = board.endDate else { return true }
        guard let endsAt = parseISO8601Date(endDate) else { return true } // fail open
        return endsAt >= now
    }

    // MARK: - Series binding tie-break

    /// Series binding's tie-break: picks the instance a recurring-series
    /// source should pull from out of an already-filtered candidate set —
    /// the LATEST `startDate`, and on an equal `startDate` the LOWEST `id`.
    ///
    /// Two offline devices can each spawn the same window (spawn ids are
    /// random), so a series may hold two instances with one `startDate`.
    /// The `id` secondary key makes the pick independent of input order, so
    /// iOS and web pull supply from the same board. (`max(by:)` on
    /// `startDate` alone — like web's stable sort — let a tie fall to
    /// whichever row came first, and GRDB and Dexie return rows in
    /// different orders.) Both keys compare with `String <`, which
    /// for these fixed-format ASCII strings (local ISO dates, UUIDs) orders
    /// identically to the TS twin's code-unit `<`.
    ///
    /// TS twin: `pickSeriesInstance` — keep in lockstep (pinned by
    /// `seriesInstanceVectors` in `boardSourceVectors.json`).
    ///
    /// - Parameter candidates: The live instances to choose among (any order).
    /// - Returns: The chosen instance, or nil when `candidates` is empty.
    static func pickSeriesInstance<T: SeriesInstanceCandidate>(_ candidates: [T]) -> T? {
        var best: T?
        for c in candidates {
            guard let current = best else { best = c; continue }
            if c.startDate > current.startDate
                || (c.startDate == current.startDate && c.id < current.id) {
                best = c
            }
        }
        return best
    }

    /// Series binding for a window (owner ruling 2026-09-24): the instance
    /// of a recurring series that supplies a board being built for the
    /// window starting at `referenceIso` — the instance whose
    /// `[startDate, endDate]` CONTAINS the reference (inclusive at both
    /// ends; a nil `endDate` is an open window). Two containing instances
    /// tie-break through ``pickSeriesInstance(_:)`` (latest `startDate`,
    /// then lowest `id`).
    ///
    /// Returns nil when no instance contains the reference — there is NO
    /// fallback to the newest started or newest instance any more: an ended
    /// or future instance never supplies another window. Callers map nil to
    /// "No board for this window yet" (no supply, capacity 0).
    ///
    /// Callers pre-filter `candidates` to live, open instances
    /// (``isEligibleSourceBoard(_:now:)``); this helper only decides
    /// containment. Board dates and the reference are fixed-format LOCAL-ISO
    /// strings, compared with `String` `<=` exactly like the TS twin's
    /// code-unit comparison.
    ///
    /// TS twin: `resolveSeriesInstanceForWindow` — keep in lockstep (pinned
    /// by `seriesForWindowVectors` in `boardSourceVectors.json`).
    ///
    /// - Parameters:
    ///   - candidates: The series' live instances (any order).
    ///   - referenceIso: The new board's window `startDate` (local ISO).
    /// - Returns: The containing instance, or nil when none contains it.
    static func resolveSeriesInstanceForWindow<T: SeriesWindowCandidate>(
        _ candidates: [T],
        referenceIso: String
    ) -> T? {
        pickSeriesInstance(candidates.filter { c in
            c.startDate <= referenceIso && (c.endDate.map { referenceIso <= $0 } ?? true)
        })
    }

    // MARK: - Remove-confirm (owner ruling 2026-09-19, amended 2026-09-23)

    /// What a pulled source carries BEYOND its as-minted defaults — the
    /// detail behind `sourceHasConfiguration`, so the wizard's
    /// remove-confirm can name what would be lost instead of warning
    /// vaguely. TS twin: `SourceConfigurationDetail`.
    ///
    /// Every field is a DIFFERENCE from the creation defaults, never an
    /// absolute reading of the row: an untouched source reads
    /// all-zero/false/nil.
    struct ConfigurationDetail: Equatable {
        /// Members this board suppressed from the source's supply.
        let excludedCount: Int
        /// Members carrying an AUTHORED rule — see `sourceConfiguration`.
        let memberRuleCount: Int
        /// The range was dragged off the `[0, all]` mint default.
        let rangeNarrowed: Bool
        /// The non-default filter the row is on, or nil — the ONLY stored
        /// form of "the filter changed". The value is carried (rather than
        /// derived by the caller) so `removeSourceLossSentence` can name the
        /// control by its on-screen label without being handed the source.
        let filter: BoardSource.Filter?

        /// `filter != nil`, COMPUTED — never a second stored bit. Storing
        /// both allowed the illegal `(filterChanged: true, filter: nil)`,
        /// where the predicate said "configured" and the sentence dropped
        /// the clause. Kept as a named member because it reads well at call
        /// sites and the vectors pin it.
        var filterChanged: Bool { filter != nil }
    }

    /// True when a member rule is something a PERSON wrote, as opposed to
    /// the one-off prefill's machine-written target.
    ///
    /// `vary`, `split` and any `parts` entry are only ever authored (the
    /// setters prune their defaults away). A lone `target` is ambiguous: on a
    /// one-off board, `prefillRemainingTargets` writes one for every counting
    /// member of a board source the moment it is pulled. So a rule whose ONLY
    /// field is a `target` equal to `seededTargetByTaskId[taskId]` is
    /// machine-written and does not count.
    ///
    /// The seed map is authoritative only for the keys it has: a target on a
    /// member the map doesn't mention (a pool member, or any caller that
    /// passed no map) is hand-set by definition and counts.
    private static func isAuthoredMemberRule(
        _ rule: BoardSourceMemberRule,
        seededTarget: Int?
    ) -> Bool {
        if rule.vary != nil || rule.split != nil { return true }
        if let parts = rule.parts, !parts.isEmpty { return true }
        guard let target = rule.target else { return false }
        guard let seededTarget else { return true }
        return target != seededTarget
    }

    /// Describe how far one pulled source has been configured away from the
    /// row the wizard mints when you pull it. TS twin: `sourceConfiguration`.
    ///
    /// Member rules are counted by AUTHORSHIP, not by entry count (amended
    /// ruling 2026-09-23): the setters already prune an all-default rule out
    /// of the map, but the one-off prefill still writes a `target` for every
    /// counting member of a freshly pulled board source — counting those made
    /// the confirm fire on the exact misclick-right-after-adding case it was
    /// meant to skip. See `isAuthoredMemberRule`.
    ///
    /// - Parameters:
    ///   - source: The pulled source row.
    ///   - defaultFilter: The filter this source's KIND mints on — `.todo`
    ///     for a board, `.all` for a pool
    ///     (`BoardWizardViewModel.newSourceFilter(for:)`). Passed in rather
    ///     than derived here so this helper never reaches into wizard code;
    ///     do NOT pass `BoardSource.init`'s own default (`.all` for every
    ///     kind), which is the legacy-decode default and would make every
    ///     freshly pulled board look configured.
    ///   - seededTargetByTaskId: What the one-off prefill would seed right
    ///     now, from `seededTargetsForSource`. Empty for a pool source, a
    ///     recurring wizard, and any non-wizard caller — every stored target
    ///     then counts as authored.
    /// - Returns: The per-dimension detail.
    static func sourceConfiguration(
        _ source: BoardSource,
        defaultFilter: BoardSource.Filter,
        seededTargetByTaskId: [String: Int] = [:]
    ) -> ConfigurationDetail {
        var memberRuleCount = 0
        for (taskId, rule) in source.memberRules ?? [:]
        where isAuthoredMemberRule(rule, seededTarget: seededTargetByTaskId[taskId]) {
            memberRuleCount += 1
        }
        return ConfigurationDetail(
            excludedCount: source.excludedTaskIds.count,
            memberRuleCount: memberRuleCount,
            rangeNarrowed: source.min != 0 || source.max != nil,
            filter: source.filter != defaultFilter ? source.filter : nil
        )
    }

    /// True when removing this source would throw away work the person did
    /// on it — the gate on the wizard's remove-confirm (an untouched source
    /// removes instantly; a configured one asks first). TS twin:
    /// `sourceHasConfiguration`.
    ///
    /// - Parameters:
    ///   - source: The pulled source row.
    ///   - defaultFilter: See `sourceConfiguration(_:defaultFilter:seededTargetByTaskId:)`.
    ///   - seededTargetByTaskId: Likewise.
    /// - Returns: Whether the row carries any configuration.
    static func sourceHasConfiguration(
        _ source: BoardSource,
        defaultFilter: BoardSource.Filter,
        seededTargetByTaskId: [String: Int] = [:]
    ) -> Bool {
        let detail = sourceConfiguration(
            source,
            defaultFilter: defaultFilter,
            seededTargetByTaskId: seededTargetByTaskId
        )
        return detail.excludedCount > 0
            || detail.memberRuleCount > 0
            || detail.rangeNarrowed
            // Reads `filter`, the stored form, for the same reason
            // `removeSourceLossSentence` does: the two must never disagree,
            // not even for a detail some caller hand-built.
            || detail.filter != nil
    }

    /// The done-filter segmented's on-screen labels — quoted verbatim in the
    /// loss sentence so the copy names the control the person actually used.
    private static func filterLabel(_ filter: BoardSource.Filter) -> String {
        filter == .all ? "All squares" : "Not done yet"
    }

    /// The one sentence the remove-confirm uses to name what a removal costs
    /// — shared so the two platforms can't word it differently. TS twin:
    /// `removeSourceLossSentence`.
    ///
    /// Order is fixed (exclusions, member rules, range, filter) and the
    /// pieces join naturally: `"A."` / `"A and B."` / `"A, B and C."`.
    ///
    /// - Parameter detail: From `sourceConfiguration(_:defaultFilter:seededTargetByTaskId:)`.
    /// - Returns: The sentence, or `nil` when nothing is configured (in
    ///   which case no confirm is shown at all).
    static func removeSourceLossSentence(_ detail: ConfigurationDetail) -> String? {
        var parts: [String] = []
        if detail.excludedCount > 0 {
            parts.append("\(detail.excludedCount) exclusion" + (detail.excludedCount == 1 ? "" : "s"))
        }
        if detail.memberRuleCount > 0 {
            parts.append("\(detail.memberRuleCount) member rule" + (detail.memberRuleCount == 1 ? "" : "s"))
        }
        if detail.rangeNarrowed { parts.append("the narrowed range") }
        if let filter = detail.filter { parts.append("the \"\(filterLabel(filter))\" filter") }
        guard !parts.isEmpty else { return nil }
        return "You'll lose \(joinNaturally(parts))."
    }

    /// `["a"]` → `"a"`; `["a","b"]` → `"a and b"`; `["a","b","c"]` → `"a, b and c"`.
    private static func joinNaturally(_ parts: [String]) -> String {
        guard parts.count > 1, let last = parts.last else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// The fields `BoardSources.pickSeriesInstance` reads — TS twin
/// `SeriesInstanceCandidate` (`Pick<Board, 'id' | 'startDate'>`).
protocol SeriesInstanceCandidate {
    var id: String { get }
    var startDate: String { get }
}

extension Board: SeriesInstanceCandidate {}

/// The fields `BoardSources.resolveSeriesInstanceForWindow` reads — TS twin
/// `SeriesWindowCandidate` (`Pick<Board, 'id' | 'startDate' | 'endDate'>`).
protocol SeriesWindowCandidate: SeriesInstanceCandidate {
    var endDate: String? { get }
}

extension Board: SeriesWindowCandidate {}

/// The fields `BoardSources.isEligibleSourceBoard` reads — TS twin
/// `SourceBoardCandidate` (`Pick<Board, 'status' | 'endDate' | 'sealedAt' | 'isDeleted'>`).
protocol SourceBoardCandidate {
    var status: BoardStatus { get }
    var endDate: String? { get }
    var sealedAt: String? { get }
    var isDeleted: Bool { get }
}

extension Board: SourceBoardCandidate {}

extension BoardSources {
    /// Can this repeating board pull `taskId`? Task Detail's "used in
    /// repeating boards" list (2026-09 audit T2) — read by a person deciding
    /// whether editing or deleting the task affects the board. TS twin:
    /// `templateReferencesTask`, pinned by `boardSourceVectors.json`
    /// (`referenceVectors`).
    ///
    /// True when the task is in the record's hand-added layer, OR is in the
    /// AVAILABLE supply of any of its sources (raw supply − that source's
    /// `excludedTaskIds`). Ranges and the done-filter are deliberately
    /// ignored: a capped source or a "Not done yet" board source can still
    /// deal the task in some window, so the list over-includes rather than
    /// hides a board that would be affected. Ignoring ranges and the
    /// done-filter is a ruling, not an omission. Split-up child tasks are
    /// NOT listed: a board lists only the tasks in its sources' own supply,
    /// so a compound member's parts (dealt via Split-up) don't list the
    /// board; the compound itself does.
    ///
    /// The hand-added layer follows the resolvers' un-migrated rule: a
    /// record with none of `sources` / `poolIds` / `manualTaskIds` /
    /// `removedTaskIds` treats `seedTaskIds` as manual. Any other record
    /// never reads `seedTaskIds` — a creation-time snapshot the edit path
    /// leaves stale, which is the defect this replaces.
    ///
    /// - Parameters:
    ///   - template: The repeating board (sources via `sourcesForRecord`).
    ///   - taskId: The task being asked about.
    ///   - suppliesBySourceId: Each source's RAW supply keyed by its stored
    ///     `sourceId` (pool: `poolSourceSupplyById`; board: the series-bound
    ///     live instance's placements, done-filter NOT applied). A source
    ///     with no entry supplies nothing.
    /// - Returns: Whether the template references the task.
    static func templateReferencesTask(
        _ template: RecurringBoardTemplate,
        taskId: String,
        suppliesBySourceId: [String: [String]]
    ) -> Bool {
        let isUnmigrated = template.sources == nil && template.poolIds == nil
            && template.manualTaskIds == nil && template.removedTaskIds == nil
        let manual = isUnmigrated ? template.seedTaskIds : (template.manualTaskIds ?? [])
        if manual.contains(taskId) { return true }
        let sources = sourcesForRecord(
            sources: template.sources,
            poolIds: template.poolIds,
            removedTaskIds: template.removedTaskIds
        )
        return sources.contains { source in
            !source.excludedTaskIds.contains(taskId)
                && (suppliesBySourceId[source.sourceId] ?? []).contains(taskId)
        }
    }
}
