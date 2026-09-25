import Foundation
import GRDB

/// Sentinel used to abort the recurring-spawn write transaction cleanly when
/// pool validation fails inside the txn. Caught at the call site; not surfaced
/// to callers (translated to a `.skipped` outcome). Moved here alongside the
/// `spawnRecurringBoard` transaction body (B4).
private enum RecurringSpawnAbort: Error {
    case skip
}

extension AppDatabase {
    // MARK: - RecurringBoardTemplates (Phase 6.2)

    /// Fetch all non-deleted templates for a user, ordered by `updatedAt desc`.
    func fetchRecurringBoardTemplates(userId: String) throws -> [RecurringBoardTemplate] {
        return try read { db in
            try RecurringBoardTemplate
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    /// Fetch a single template by id (including soft-deleted, for completeness).
    func fetchRecurringBoardTemplate(id: String) throws -> RecurringBoardTemplate? {
        return try read { db in
            try RecurringBoardTemplate.fetchOne(db, key: id)
        }
    }

    /// Insert / update a template. The caller is responsible for bumping
    /// `version` and `updatedAt` (mirror of `saveBoard`).
    func saveRecurringBoardTemplate(_ template: RecurringBoardTemplate) throws {
        try write { db in
            try template.save(db)
        }
    }

    /// Soft-delete a template. Spawned boards remain — they're independent
    /// once spawned (per Phase 6.2 design). Bumps `version` so LWW treats
    /// the deletion as later-wins.
    func softDeleteRecurringBoardTemplate(id: String) throws {
        try write { db in
            guard var template = try RecurringBoardTemplate.fetchOne(db, key: id) else { return }
            let now = Self.currentTimestamp()
            template.isDeleted = true
            template.deletedAt = now
            template.updatedAt = now
            template.version += 1
            try template.update(db)
        }
    }

    // MARK: - Atomic save + sync-enqueue (templates & pools)
    //
    // Mirror of `saveTaskAndEnqueueUpdate`: the model write and its
    // sync-queue item live in ONE transaction so a crash between them
    // can't leave the local row ahead of Firestore with no recovery.

    /// Save a template and enqueue its sync op atomically. The caller
    /// bumps `version`/`updatedAt` before calling; `operation` is
    /// `.create` for the first save, `.update` thereafter.
    func saveRecurringBoardTemplateAndEnqueue(
        _ template: RecurringBoardTemplate,
        operation: SyncOperationType,
        now: String
    ) throws {
        try write { db in
            try template.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "recurringBoardTemplates",
                entityId: template.id,
                operationType: operation,
                payload: template,
                now: now
            ).enqueue(db)
        }
    }

    /// Board Sources P3 — the "Remove that source" action of the
    /// deleted-source ask (docs/BOARD_SOURCES.md §Boards as sources).
    /// Drops every board-kind source whose board is missing, soft-deleted,
    /// or archived from the record's `sources`, recomputes the legacy trio
    /// mirror, bumps version, and enqueues — one transaction. Returns true
    /// when anything changed (the caller then re-runs the spawn pass).
    func removeMissingBoardSources(templateId: String, now: String) throws -> Bool {
        try write { db in
            guard var template = try RecurringBoardTemplate.fetchOne(db, key: templateId) else {
                return false
            }
            let sources = BoardSources.sourcesForRecord(
                sources: template.sources,
                poolIds: template.poolIds,
                removedTaskIds: template.removedTaskIds
            )
            let boardIds = sources.filter { $0.kind == .board }.map { $0.sourceId }
            guard !boardIds.isEmpty else { return false }
            // Series binding — "missing" means the resolver finds the source
            // DEAD: the stored row gone, or a series with no existing
            // instance (a stored archived window with a live series sibling
            // is NOT missing). A `.noWindow` source — no open board for this
            // window yet, owner ruling 2026-09-24 — is KEPT: it supplies
            // nothing now but is not gone, and removing it would silently
            // drop a series binding the next window needs.
            // Reference in LOCAL wall-clock format (board-date format) —
            // `now` is the UTC sync timestamp and mis-sorts near local
            // midnight (review-caught Critical, 2026-09-09).
            let reference = wizardLocalISOString(Date())
            var liveByStoredId: [String: Bool] = [:]
            for id in boardIds {
                if case .dead = try Self.resolveSourceBoardForWindow(
                    db: db, storedBoardId: id, reference: reference
                ) {
                    liveByStoredId[id] = false
                } else {
                    liveByStoredId[id] = true
                }
            }
            let kept = sources.filter { source in
                guard source.kind == .board else { return true }
                return liveByStoredId[source.sourceId] == true
            }
            guard kept.count != sources.count else { return false }
            template.sources = kept
            // Keep the P1 dual-write mirrors consistent with the new shape.
            let mirror = BoardSources.mixFieldsFromSources(kept)
            template.poolIds = mirror.poolIds
            template.removedTaskIds = mirror.removedTaskIds
            template.updatedAt = now
            template.version += 1
            try template.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "recurringBoardTemplates",
                entityId: template.id,
                operationType: .update,
                payload: template,
                now: now
            ).enqueue(db)
            return true
        }
    }

    /// Pause / resume a repeating board — the lost-update-safe active toggle.
    ///
    /// Re-reads the LIVE row inside the write and patches only `isActive`,
    /// `updatedAt` and `version` (live `version` + 1), then enqueues — one
    /// transaction. Callers must NOT save a full in-memory template for this:
    /// a copy captured before a spawn pass (which bumps
    /// `lastSpawnedWindowKey` + `version`) or a pulled edit would silently
    /// revert those fields and push the revert. Web twin:
    /// `updateRecurringBoardTemplate(id, { isActive })`, which patches the
    /// fresh row the same way.
    ///
    /// - Parameters:
    ///   - id: The template id.
    ///   - isActive: The desired active flag.
    ///   - now: ISO8601 timestamp stamped as `updatedAt` + on the sync item.
    /// - Returns: The written template, or `nil` when nothing was written
    ///   (row missing, soft-deleted, or already at `isActive`).
    /// - Throws: Any GRDB error from the read, save or enqueue.
    @discardableResult
    func setTemplateActive(id: String, isActive: Bool, now: String) throws -> RecurringBoardTemplate? {
        try write { db in
            guard var template = try RecurringBoardTemplate.fetchOne(db, key: id),
                  !template.isDeleted,
                  template.isActive != isActive else {
                return nil
            }
            template.isActive = isActive
            template.updatedAt = now
            template.version += 1
            try template.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "recurringBoardTemplates",
                entityId: template.id,
                operationType: .update,
                payload: template,
                now: now
            ).enqueue(db)
            return template
        }
    }

    /// Atomically spawn a Board + BoardTasks from a `PendingTemplateSpawn`
    /// and bump the template's `lastSpawnedWindowKey` — all sync-enqueued —
    /// in ONE transaction. Task resolution + pool validation happen INSIDE
    /// the write so a concurrent sync can't soft-delete a seed task between
    /// the read and the writes (which would let a board spawn against stale
    /// pool data). Validation failures roll the txn back and return a
    /// `.skipped(...)` outcome.
    ///
    /// Moved VERBATIM from `RecurringBoardSpawn.spawnTemplateBoard`'s write
    /// block so the sync-enqueue lives in the data layer. The service is now a
    /// thin wrapper that mints the `boardId` / `now` and delegates here.
    ///
    /// - Parameters:
    ///   - spawn: The pending-spawn descriptor (template + resolved window).
    ///   - boardId: The client-generated id for the new board.
    ///   - now: ISO8601 timestamp stamped on every row written here.
    ///   - sourceClock: The instant a board source's "has this board ended"
    ///     is judged against (owner ruling 2026-09-24: ended boards are never
    ///     sources). Defaults to the wall clock; tests inject it.
    /// - Returns: `.spawned(...)` on success or `.skipped(...)` with a reason.
    func spawnRecurringBoard(
        _ spawn: PendingTemplateSpawn,
        boardId: String,
        now: String,
        sourceClock: Date = AppDatabase.sourceClock()
    ) throws -> RecurringSpawnOutcome {
        let template = spawn.template
        let size = template.boardSize

        // Skip outcomes are returned by setting an outer `var` from inside the
        // write closure and short-circuiting via a thrown sentinel — the
        // GRDB-idiomatic "validate inside the transaction, skip without
        // committing". The `try ... write` signature is `(Database) throws -> T`,
        // and an early-exit outcome must NOT trigger the write either, so we
        // set the outcome, `throw` to abort the txn cleanly, then catch.
        var outcome: RecurringSpawnOutcome?
        var noBoardForWindowSourceIds: [String] = []
        do {
            try write { db in
                // Board Sources P1 (docs/BOARD_SOURCES.md) — the task
                // source is the record's SOURCES: the stamped `sources`
                // array when present, else the legacy trio derived on the
                // fly (`BoardSources.sourcesForRecord` — no data backfill;
                // rows written by old clients keep working). Pool sources
                // supply their resolvable taskIds; board sources resolve
                // through `resolveSourceBoard` below. An EMPTY source
                // contributes nothing and never blocks.
                //
                // Full-table task read: the supply resolvers need a
                // `tasksById` map to filter each pool's OWN resolvable
                // supply (deleted tasks skipped — derived detachment), and
                // the same map is reused below for the spawn-time
                // derivation pass, so this isn't an added read (mirrors
                // web's `spawnTemplateBoard`).
                let allTasks = try Task.fetchAll(db)
                var tasksById = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })

                let sources = BoardSources.sourcesForRecord(
                    sources: template.sources,
                    poolIds: template.poolIds,
                    removedTaskIds: template.removedTaskIds
                )

                // Board Sources P3 + series binding, under the owner ruling
                // of 2026-09-24 (ENDED BOARDS ARE NEVER SOURCES): each pulled
                // board resolves through `resolveSourceBoardForWindow`
                // against THIS spawn's window start — the one reference the
                // wizard's live supply, Preview, capacity and persist also
                // use. A series binds to its open instance CONTAINING the
                // window start; none (or an ended/sealed one-off) is
                // `.noWindow`: that source deals nothing and the provenance
                // note says "No board for this window yet" — the window still
                // spawns. Only a `.dead` source (the stored row gone /
                // deleted / archived, or a series with no instance at all)
                // blocks the window with the ask. Distinct from an EMPTY
                // source, which contributes nothing silently.
                let boardSourceIds = sources.filter { $0.kind == .board }.map { $0.sourceId }
                var sourceBoardById: [String: Board] = [:]
                for id in boardSourceIds {
                    switch try Self.resolveSourceBoardForWindow(
                        db: db, storedBoardId: id, reference: spawn.windowStart, now: sourceClock
                    ) {
                    case .dead:
                        outcome = .skipped(templateId: template.id, reason: .sourceBoardMissing)
                        throw RecurringSpawnAbort.skip
                    case .noWindow:
                        noBoardForWindowSourceIds.append(id)
                    case .live(let board):
                        sourceBoardById[id] = board
                    }
                }

                let poolSourceIds = sources.filter { $0.kind == .pool }.map { $0.sourceId }
                let pools = poolSourceIds.isEmpty
                    ? []
                    : try Pool.filter(poolSourceIds.contains(Column("id"))).fetchAll(db)
                let poolsById = Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })

                // Compound children — read ONCE, above the supply resolution,
                // and reused by three consumers: Split-up expansion + the
                // member-rules plan below, and the derivation pass at the
                // bottom (which is all it used to be read for). Ordered by
                // `childIndex` so it matches the batched
                // `fetchCompoundChildren(db:compoundTaskIds:)` the other mint
                // path uses. NOT an rng-determinism fix: both
                // `applyMemberRules` and `planDerivedTasks` apply their own
                // total childIndex-then-id comparator, so the plan is already
                // order-independent. This is for the stats consumer below,
                // which reads the rows in the order it is handed them.
                let allChildren = try CompoundChild
                    .filter(Column("isDeleted") == false)
                    .order(Column("childIndex"))
                    .fetchAll(db)
                var childrenByCompound: [String: [CompoundChild]] = [:]
                for c in allChildren { childrenByCompound[c.compoundTaskId, default: []].append(c) }

                // Board Sources P3 — board-kind sources resolve LIVE per
                // window: the source board's placed squares, with the
                // 'todo' filter dropping squares complete in THAT board's
                // window (the per-cell predicate, batched).
                var supplies: [BoardSources.Supply] = []
                for source in sources {
                    switch source.kind {
                    case .pool:
                        supplies.append(BoardSources.Supply(
                            source: source,
                            supplyTaskIds: BoardSources.poolSourceSupplyById(
                                source.sourceId, poolsById: poolsById, tasksById: tasksById
                            )
                        ))
                    case .board:
                        guard let sourceBoard = sourceBoardById[source.sourceId] else {
                            // `.noWindow` (no open board for this window):
                            // contributes nothing.
                            supplies.append(BoardSources.Supply(source: source, supplyTaskIds: []))
                            continue
                        }
                        let info = try Self.resolveSupply(db: db, board: sourceBoard)
                        let raw = BoardSources.availableSupplyIds(
                            source: source,
                            supplyTaskIds: info.supplyTaskIds,
                            doneTaskIds: info.doneTaskIds
                        )
                        supplies.append(BoardSources.Supply(source: source, supplyTaskIds: raw))
                    }
                }

                // Board Sources §Member rules (B2) — spec step 1: Split-up
                // expansion happens ONCE, here, and the expanded supplies are
                // what the capacity validation, the selection AND the
                // member-rule plan all consume. A `split: true` compound
                // therefore contributes its PARTS as selectable squares (and
                // never itself), so what Settings' capacity says and what this
                // spawn places can't disagree.
                let ruleSupplies = BoardSources.applyMemberRules(
                    supplies.map {
                        BoardSources.Supply(
                            source: $0.source,
                            supplyTaskIds: BoardSources.resolveSourceAvailable($0)
                        )
                    },
                    childrenByCompoundId: childrenByCompound,
                    tasksById: tasksById
                )

                // The manual layer isn't deleted-filtered (caller-curated,
                // matching resolveMix's old contract), but hard-gone ids
                // ARE dropped — the old path dropped them via its tasksById
                // compactMap the same way. A resolved-but-deleted manual
                // task stays, for the validator below.
                let manualTaskIds = (template.manualTaskIds ?? []).filter { tasksById[$0] != nil }

                // Validate the FULL candidate set (manual + every source's
                // available list, deduped) BEFORE selecting — preserves the
                // pre-sources skip semantics exactly: a deleted manual task
                // anywhere in the mix skips as `.hasDeletedTasks`, a
                // too-small mix as `.poolTooSmall`, independent of which
                // subset selection would have picked.
                var candidateSeen = Set<String>()
                var candidateTasks: [Task] = []
                func addCandidate(_ id: String) {
                    guard !candidateSeen.contains(id) else { return }
                    candidateSeen.insert(id)
                    if let t = tasksById[id] { candidateTasks.append(t) }
                }
                for id in manualTaskIds { addCandidate(id) }
                for supply in ruleSupplies {
                    for id in BoardSources.resolveSourceAvailable(supply.asSupply) { addCandidate(id) }
                }

                if candidateTasks.isEmpty {
                    outcome = .skipped(templateId: template.id, reason: .noPoolTasksResolved)
                    throw RecurringSpawnAbort.skip
                }

                let validation = validateSpawnPool(template: template, poolTasks: candidateTasks)
                if case .failure(let reason) = validation {
                    outcome = .skipped(templateId: template.id, reason: SpawnAttentionReason(reason))
                    throw RecurringSpawnAbort.skip
                }

                // Pick exactly the fillable cell count, honoring each
                // source's membership range (`[0, all]` for a migrated
                // shape). A range-infeasible pick maps to the same
                // skip-and-warn family as a small pool.
                // `randomize:` honors the template's determinism contract —
                // an `isRandomized: false` template keeps its stable
                // first-N subset + order (review-caught; `placeBoard`'s
                // verbatim path is defeated if selection already shuffled).
                let selection = BoardSources.selectBoardTasks(
                    // The EXPANDED supplies (see above) —
                    // `selectBoardTasks` re-applies
                    // `resolveSourceAvailable` internally, a no-op on an
                    // already exclude-filtered list.
                    supplies: ruleSupplies.map { $0.asSupply },
                    manualTaskIds: manualTaskIds,
                    cellCount: recurringTemplateFillableCellCount(
                        boardSize: size,
                        centerSquareType: template.centerSquareType
                    ),
                    randomize: template.isRandomized,
                    // Counter-family exclusivity (2026-09-08): at most one
                    // member of a shared-counter family per spawned board.
                    // Recurring boards have no CHOSEN center — no pin.
                    counterFamilyByTaskId: BoardSources.buildCounterFamilyMap(tasksById.values)
                )
                let selectedIds: [String]
                switch selection {
                case .short:
                    outcome = .skipped(templateId: template.id, reason: .poolTooSmall)
                    throw RecurringSpawnAbort.skip
                case .ok(let taskIds):
                    selectedIds = taskIds
                }

                // Board Sources §Member rules (B2, docs/BOARD_SOURCES.md
                // §Member rules — *Resolution pipeline* steps 3/5): the picked
                // ids are resolved against this window's rules and any
                // window-stamped derived counter / derived compound they call
                // for is MINTED HERE — before the `board_tasks` rows below
                // point at it, in this same transaction.
                // Auto targets pro-rate a member's goal by the ratio of the
                // SOURCE board's window to this one, so every supplied id —
                // and every child of a compound member, which is looked up by
                // the CHILD's id — needs its source window recorded.
                var sourceWindowByTaskId: [String: BoardSources.BoardWindow] = [:]
                for supply in ruleSupplies {
                    guard supply.source.kind == .board,
                          let sourceBoard = sourceBoardById[supply.source.sourceId] else { continue }
                    let sourceWindow = BoardSources.BoardWindow(
                        timeframe: sourceBoard.timeframe,
                        startDate: sourceBoard.startDate,
                        endDate: sourceBoard.endDate
                    )
                    for id in supply.supplyTaskIds {
                        sourceWindowByTaskId[id] = sourceWindow
                        for link in childrenByCompound[id] ?? [] {
                            sourceWindowByTaskId[link.childTaskId] = sourceWindow
                        }
                    }
                }
                let roots = AppDatabase.candidateRootIds(
                    selectedIds: selectedIds,
                    tasksById: tasksById,
                    childrenByCompoundId: childrenByCompound
                )
                let rootEvents = roots.isEmpty
                    ? []
                    : try TaskEvent.filter(roots.contains(Column("taskId"))).fetchAll(db)
                let mintResult = try AppDatabase.planAndMintDerivedRows(
                    db: db,
                    boardId: boardId,
                    userId: template.userId,
                    now: now,
                    selectedIds: selectedIds,
                    supplies: ruleSupplies,
                    manualTaskIds: manualTaskIds,
                    // RB7 — a repeating board carries its hand-added members'
                    // dice levels on the record; absent means "nobody varies".
                    manualTaskVary: template.manualTaskVary ?? [:],
                    window: BoardSources.BoardWindow(
                        timeframe: template.timeframe,
                        startDate: spawn.windowStart,
                        endDate: spawn.windowEnd
                    ),
                    mode: .recurring,
                    tasksById: tasksById,
                    childrenByCompoundId: childrenByCompound,
                    sourceWindowByTaskId: sourceWindowByTaskId,
                    events: rootEvents
                )
                // Fold the minted rows into the snapshots the placement and the
                // derivation pass below read from. Read BACK rather than
                // trusting the built row: RB3 skips an already-live row, so
                // what is STORED is the authority for what the board derives.
                for row in mintResult.minted.tasks {
                    if let stored = try Task.fetchOne(db, key: row.id) { tasksById[row.id] = stored }
                }
                for link in mintResult.minted.links {
                    guard let stored = try CompoundChild.fetchOne(db, key: link.id),
                          !stored.isDeleted else { continue }
                    childrenByCompound[stored.compoundTaskId, default: []].append(stored)
                }

                let orderedPool: [Task] = selectedIds.enumerated().compactMap { index, id in
                    tasksById[index < mintResult.placementIds.count ? mintResult.placementIds[index] : id]
                }

                let placement = buildSpawnPlacement(template: template, poolTasks: orderedPool)

                // Construct Board via JSON-dict round-trip — mirrors
                // BoardWizardPersist.swift since Board has no memberwise init.
                var boardDict: [String: Any] = [
                    "id": boardId,
                    "userId": template.userId,
                    "name": spawn.suggestedName,
                    "status": BoardStatus.active.rawValue,
                    "boardSize": size,
                    "timeframe": template.timeframe.rawValue,
                    "startDate": spawn.windowStart,
                    "endDate": spawn.windowEnd,
                    "centerSquareType": template.centerSquareType.rawValue,
                    "isRandomized": template.isRandomized,
                    "totalTasks": size * size,
                    "completedTasks": 0,
                    "linesCompleted": 0,
                    "createdAt": now,
                    "updatedAt": now,
                    "version": 1,
                    "isDeleted": false,
                    "spawnedFromTemplateId": template.id,
                    // Phase 6.1 — template-spawned boards are core by
                    // construction. They fulfill the same "recurring
                    // board for this window exists" promise as banner-
                    // spawned boards, so the recurring banner detector
                    // must treat them the same.
                    "isCore": true,
                ]
                let boardData = try JSONSerialization.data(withJSONObject: boardDict)
                var board = try JSONDecoder().decode(Board.self, from: boardData)

                // Shared with the wizard-save path so the `isCenter` rule
                // stays identical: only a `.chosen` centre task is flagged
                // (a `.none` centre holds an ordinary task, not a FREE cell).
                // Two members that share a shared-counter root collapse onto
                // ONE derived counter, so the same id can reach the placement
                // twice. Counter-family exclusivity already forbids that at
                // selection time, making this belt-and-braces — but a
                // duplicate `taskId` on one board trips the
                // placement-integrity invariants (docs/BOARD_INTEGRITY.md), so
                // the repeat cell is left empty rather than written.
                //
                // The invariant this trades away, stated plainly: the board
                // comes out one square short, against "boards are always
                // exactly filled". Throwing would be worse, so the guard drops
                // the cell and LOGS — the log is the only signal that the
                // unreachable path fired, and it exists on both platforms (web
                // `console.warn`s here).
                var placedTaskIds = Set<String>()
                let boardTasks = makeWizardBoardTaskRows(
                    placement: placement,
                    boardId: boardId,
                    size: size,
                    centerType: template.centerSquareType,
                    now: now
                ).filter { row in
                    guard placedTaskIds.insert(row.taskId).inserted else {
                        #if DEBUG
                        dlog("spawnRecurringBoard: task \(row.taskId) resolved twice on board \(boardId); leaving its cell empty")
                        #endif
                        return false
                    }
                    return true
                }

                // Windowed Completion (docs/WINDOWED_COMPLETION.md §What this
                // closes — respawn-bleed row): run the derivation pass at spawn so
                // stored stats are derivation output, not a hand-initialized 0. A
                // fresh window has no events, so event-owning squares resolve
                // incomplete (no respawn bleed); a FREE center still
                // auto-fills. The invariant "stored stats are always derivation
                // output" now holds from the first row written. Mirrors the web
                // `spawnTemplateBoard` change.
                // (`childrenByCompound` is hoisted above the supply resolution
                // — the member-rules plan needs it too; the minted derived
                // links were folded into it, so a derived compound evaluates
                // against its own parts here.)
                let windowContext = try AppDatabase.buildWindowContext(db: db)
                // Reuse the `tasksById` map read at the top of this closure for
                // source resolution — the only `tasks` writes in between are
                // the member-rule mint's, and those rows were read back into
                // the map above, so it is still an accurate snapshot for the
                // derivation pass (mirrors web's reuse of `tasksById`).
                let taskById: [String: Task] = tasksById
                let allBoardsForDerivation = try Board
                    .filter(Column("isDeleted") == false)
                    .fetchAll(db)
                let stats = DerivationPass.computeBoardStatsUpdate(
                    board: board,
                    boardTasksOnBoard: boardTasks,
                    childrenByCompound: childrenByCompound,
                    taskById: taskById,
                    allBoards: allBoardsForDerivation,
                    windowContext: windowContext
                )
                board.completedTasks = stats.completedTasks
                board.linesCompleted = stats.linesCompleted
                board.completedLineIds = stats.completedLineIds

                var updatedTemplate = template
                updatedTemplate.lastSpawnedWindowKey = spawn.windowStart
                updatedTemplate.updatedAt = now
                updatedTemplate.version += 1

                try board.insert(db)

                // Board-integrity PR-5 (Item 3) — isCenter uniqueness guard,
                // same rationale + fresh in-txn read as `saveWizardBoard`
                // (AppDatabase+Boards.swift): a spawned board is always
                // brand-new so this reads 0 today, but the check (rather
                // than trusting `makeWizardBoardTaskRows`'s current
                // single-center invariant) protects against a future
                // placement-builder bug slipping a second `isCenter: true`
                // row onto the freshly-spawned board.
                var liveCenterCount = try BoardTask
                    .filter(Column("boardId") == board.id
                            && Column("isDeleted") == false
                            && Column("isCenter") == true)
                    .fetchCount(db)
                for bt in boardTasks {
                    if bt.isCenter {
                        guard liveCenterCount == 0 else {
                            throw AppDatabaseError.invalidPlacement(
                                "Board already has a center placement."
                            )
                        }
                        liveCenterCount += 1
                    }
                    try bt.insert(db)
                }
                try updatedTemplate.update(db)

                try SyncQueueBuilder.makeItem(
                    entityType: "boards",
                    entityId: board.id,
                    operationType: .create,
                    payload: board,
                    now: now
                ).enqueue(db)

                for bt in boardTasks {
                    try SyncQueueBuilder.makeItem(
                        entityType: "boardTasks",
                        entityId: bt.id,
                        operationType: .create,
                        payload: bt,
                        now: now
                    ).enqueue(db)
                }

                try SyncQueueBuilder.makeItem(
                    entityType: "recurringBoardTemplates",
                    entityId: updatedTemplate.id,
                    operationType: .update,
                    payload: updatedTemplate,
                    now: now
                ).enqueue(db)

                outcome = .spawned(
                    boardId: boardId,
                    templateId: template.id,
                    windowStart: spawn.windowStart,
                    noBoardForWindowSourceIds: noBoardForWindowSourceIds
                )
            }
        } catch RecurringSpawnAbort.skip {
            // Expected: validation failed inside the txn, the GRDB write
            // rolled back, and `outcome` was set to a `.skipped(...)`
            // before the throw. Fall through to the return below.
        }

        return outcome ?? .skipped(templateId: template.id, reason: .spawnFailed)
    }

    /// "Repeat this board…" (Task Pools + Recurring Boards Rework, P6 —
    /// docs/POOLS_RECURRING.md §Surfaces item 7). Mints a NEW
    /// `RecurringBoardTemplate` from a one-off board's current live tasks
    /// (an own-mix, zero-pool repeating board) and back-stamps the
    /// board's `spawnedFromTemplateId` — both atomically in ONE
    /// transaction, mirroring `saveRecurringBoardTemplateAndEnqueue`'s
    /// model-write-plus-sync-enqueue pattern.
    ///
    /// Deliberately does **not** call `spawnRecurringBoard` — the board
    /// being repeated IS this window's board already; an immediate spawn
    /// would double it up. The correctly-computed (cadence-window, not
    /// board-timeframe-window) `lastSpawnedWindowKey` is exactly what
    /// keeps `findTemplatesPendingSpawn` from firing on the next
    /// Boards-tab open until the NEXT window arrives.
    ///
    /// - Parameters:
    ///   - board: The source one-off board. Only its display fields
    ///     (name/size/center/randomize/startDate) are read here — its
    ///     current BoardTask placements are read fresh, inside the
    ///     transaction, so a concurrent sync can't race a stale snapshot.
    ///   - cadence: The user-chosen repeat cadence.
    ///   - userId: The template's owner.
    ///   - weekStartDay: `"monday"` / `"sunday"` — only affects `.weekly`.
    ///   - now: ISO8601 timestamp stamped on every row written here.
    /// - Returns: The newly-created template, or `nil` if `board.startDate`
    ///   is unparseable (should never happen for a live board — the same
    ///   defensive branch as `buildRepeatBoardTemplateInput`).
    @discardableResult
    func repeatBoardAsTemplate(
        board: Board,
        cadence: Timeframe,
        userId: String,
        weekStartDay: String,
        now: String
    ) throws -> RecurringBoardTemplate? {
        var result: RecurringBoardTemplate?
        try write { db in
            // Fresh in-txn read of the board's live placements — never the
            // caller's possibly-stale `board` snapshot (mirrors the
            // `spawnRecurringBoard` posture of resolving supply data
            // inside the write).
            let placements = try BoardTask
                .filter(Column("boardId") == board.id && Column("isDeleted") == false)
                .order(Column("row"), Column("col"), Column("id"))
                .fetchAll(db)

            // ONE batched read for the RB4 check below (the batched style this
            // file's neighbours use), not a `get` per cell.
            let placedTaskIds = Array(Set(placements.map { $0.taskId }))
            var placedTaskById: [String: Task] = [:]
            for task in try Task.filter(placedTaskIds.contains(Column("id"))).fetchAll(db) {
                placedTaskById[task.id] = task
            }

            // Distinct, in placement order — a shared task placed twice
            // (shouldn't happen post board-integrity hardening, but this
            // mirrors makeWizardBoardTaskRows' dedup posture defensively)
            // must not appear twice in manualTaskIds.
            // RB4 amended (final-review FI2) — the roots behind any placed
            // window-stamped derived counters, in ONE batched read.
            let rootIds = Array(Set(placedTaskById.values
                .filter { BoardSources.isWindowStampedDerived($0) }
                .compactMap { $0.sharedCounterId }))
            var rootById: [String: Task] = [:]
            if !rootIds.isEmpty {
                for root in try Task.filter(rootIds.contains(Column("id"))).fetchAll(db) {
                    rootById[root.id] = root
                }
            }

            var seen = Set<String>()
            var boardTaskIds: [String] = []
            for bt in placements {
                let task = placedTaskById[bt.taskId]
                // Board Sources §Member rules (B2, RB4) — a per-window derived
                // COMPOUND is this window's re-targeted copy of a source
                // compound; carrying it forward as a hand-added member would
                // pin every future window to it.
                if let task, Self.isWindowStampedDerivedCompound(task) { continue }
                // RB4 amended (final-review FI2) — a derived COUNTER is
                // recorded by its ROOT id, never its own. The derived row
                // belongs to THIS board's window and is retired with this
                // board (RB5), so a record naming it would be skipped as
                // `.hasDeletedTasks` for every future window the day the user
                // deletes the board they repeated. The root is durable library
                // content and is what each new window re-mints from anyway. A
                // root that is itself missing or deleted contributes no member.
                var memberId = bt.taskId
                if let task,
                   BoardSources.isWindowStampedDerived(task),
                   let rootId = task.sharedCounterId {
                    guard let root = rootById[rootId], !root.isDeleted else { continue }
                    memberId = root.id
                }
                guard seen.insert(memberId).inserted else { continue }
                boardTaskIds.append(memberId)
            }

            guard let input = buildRepeatBoardTemplateInput(
                boardName: board.name,
                boardSize: board.boardSize,
                centerSquareType: board.centerSquareType,
                isRandomized: board.isRandomized,
                boardStartDate: board.startDate,
                boardTaskIds: boardTaskIds,
                cadence: cadence,
                weekStartDay: weekStartDay
            ) else { return }

            let template = RecurringBoardTemplate(
                id: Self.generateUUID(),
                userId: userId,
                name: input.name,
                timeframe: input.timeframe,
                boardSize: input.boardSize,
                centerSquareType: input.centerSquareType,
                isRandomized: input.isRandomized,
                seedTaskIds: input.seedTaskIds,
                poolIds: input.poolIds,
                manualTaskIds: input.manualTaskIds,
                removedTaskIds: input.removedTaskIds,
                // Board Sources §Member rules (B2, RB4) — authored, not
                // inferred: a repeat-this-board record pulls from no source at
                // all, and no member carries a vary level until a UI can
                // author one. Writing both explicitly keeps
                // `sourcesForRecord`'s legacy-shape inference off this record
                // and gives the member-rules readers a real empty map.
                sources: [],
                manualTaskVary: [:],
                lastSpawnedWindowKey: input.lastSpawnedWindowKey,
                isActive: input.isActive,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
            try template.insert(db)
            try SyncQueueBuilder.makeItem(
                entityType: "recurringBoardTemplates",
                entityId: template.id,
                operationType: .create,
                payload: template,
                now: now
            ).enqueue(db)

            // Back-stamp the source board — the badge, manage row, and the
            // spawn idempotency belt all key off `spawnedFromTemplateId`.
            guard var liveBoard = try Board.fetchOne(db, key: board.id) else {
                result = template
                return
            }
            liveBoard.spawnedFromTemplateId = template.id
            liveBoard.updatedAt = now
            liveBoard.version += 1
            try liveBoard.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boards",
                entityId: liveBoard.id,
                operationType: .update,
                payload: liveBoard,
                now: now
            ).enqueue(db)

            result = template
        }
        return result
    }

    /// Soft-delete a template and enqueue the delete op atomically.
    func softDeleteRecurringBoardTemplateAndEnqueue(id: String, now: String) throws {
        try write { db in
            guard var t = try RecurringBoardTemplate.fetchOne(db, key: id) else { return }
            t.isDeleted = true
            t.deletedAt = now
            t.updatedAt = now
            t.version += 1
            try t.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "recurringBoardTemplates",
                entityId: t.id,
                operationType: .delete,
                payload: t,
                now: now
            ).enqueue(db)
        }
    }

}
