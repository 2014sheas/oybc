import Combine
import Foundation
import GRDB

/// The ONE data seam behind Task Detail — the pushed route and the "Open in library"
/// sheet both render its `model` (docs/TASK_DETAIL_REDESIGN.md §PR 4). DB-injected.
///
/// - **Reads:** one background snapshot (task, placements, boards, links, events), then
///   the hero is read through an *anchor* `BoardPlayViewModel` — the soonest-ending
///   active board the task is placed on (`TaskDetailKernel.heroAnchorBoard`) — so the
///   count, goal, completion and compound children come from the same windowed
///   resolvers board play uses. The anchor input is the boards of the task's OWN
///   placements; the Boards rows come from the placement reach
///   (`fetchTaskDetailPlacements` → `TaskPlacementRows`).
/// - **Writes:** the hero writes through the anchor placement via the anchor view
///   model's handlers (`completeTaskOrchestrated`, shared-counter increment /
///   decrement, compound child toggle / increment) and Undoes through the same
///   `SquareLogStrip` recipes, so a log from Task Detail is a log on that board.
/// - No anchor → `model.hero == .none` and no write is possible.
///
/// Web twin: `hooks/useTaskDetail.ts`.
@MainActor
final class TaskDetailViewModel: ObservableObject {

    // MARK: - Published

    @Published private(set) var model: TaskDetailModel?
    @Published private(set) var loadError: String?
    /// The hero's Undo strip after a write (nil when none).
    @Published private(set) var strip: SquareLogStrip?
    /// A write is in flight — the hero's controls disable but never hide.
    @Published private(set) var isBusy = false
    /// The dimmed busy look: `isBusy` held for `BusyLook.delay` (controls go inert at once).
    @Published private(set) var showsBusyLook = false
    @Published var saveError: String?

    // MARK: - Collaborators

    let database: AppDatabase
    private let clock: () -> Date

    // MARK: - Loaded state (read by the shells)

    private(set) var taskId: String
    private(set) var task: Task?
    private(set) var compoundChildren: [Task] = []
    private(set) var pickerBoards: [Board] = []
    private(set) var pickerTemplates: [RecurringBoardTemplate] = []
    private(set) var counterRoot: Task?
    private(set) var userTasks: [Task] = []
    private var snapshot: Snapshot?

    // MARK: - Anchor + watched board

    private(set) var anchor: BoardPlayViewModel?
    /// The square the hero drives on the anchor board, and the compound child it
    /// drives there (nil when the square IS the task).
    private var anchorChoice: AppDatabase.HeroAnchorCandidate?
    private var anchorSub: AnyCancellable?
    private var busyLookSub: AnyCancellable?
    private var processingSub: AnyCancellable?
    private var watched: BoardPlayViewModel?
    private var watchedSub: AnyCancellable?
    private var loadToken = 0

    init(taskId: String, database: AppDatabase = .shared, now: @escaping () -> Date = Date.init) {
        self.taskId = taskId
        self.database = database
        self.clock = now
        busyLookSub = $isBusy.delayedBusyLook().sink { [weak self] in self?.showsBusyLook = $0 }
    }

    /// Test seam: the snapshot read. Production always uses `fetchSnapshot`.
    var snapshotFetcher: @Sendable (String, AppDatabase, Bool) throws -> Snapshot? = { id, db, userTasks in
        try TaskDetailViewModel.fetchSnapshot(taskId: id, database: db, includeUserTasks: userTasks)
    }

    // MARK: - Snapshot

    /// Everything not read through the anchor board.
    struct Snapshot {
        let task: Task
        /// The task's OWN live placements (hero anchor, "Placed on" Activity rows).
        let placements: [BoardTask]
        /// The squares the hero may anchor on, best rank first (binding decision 3).
        let anchorCandidates: [AppDatabase.HeroAnchorCandidate]
        /// Every live board the task reaches (own, a linked row's, a parent compound's) — PR 5.
        let boards: [Board]
        /// One kernel row per reached board (`TaskPlacementRows`).
        let rows: [TaskPlacementRows.Row]
        /// Workspace tasks by id (the rows' members and their roots).
        let taskById: [String: Task]
        let parents: [Task]
        let children: [Task]
        let templates: [RecurringBoardTemplate]
        /// Live events keyed by task id — the task's own and its counter root's.
        let events: [String: [TaskEvent]]
        let counterRoot: Task?
        /// The user's tasks for the edit sheet's pickers; nil on a post-write refresh (the previous list stands).
        let userTasks: [Task]?
        let pickerBoards: [Board]
        let pickerTemplates: [RecurringBoardTemplate]
        /// Task ids (own + compound children) whose un-complete would be inert (Decision 9).
        let sealBlocked: Set<String>
        let watchedBoard: Board?
        /// A compound's direct child links (ordered) — board rows evaluate it per board window.
        let childLinks: [CompoundChild]
    }

    nonisolated static func fetchSnapshot(taskId: String, database db: AppDatabase, includeUserTasks: Bool = true) throws -> Snapshot? {
        guard let task = try db.fetchTask(id: taskId), !task.isDeleted else { return nil }
        let userId = task.userId
        // Placement resolution (PR 5): the placement REACH, each board scored by the shared kernel.
        let reached = try db.fetchTaskDetailPlacements(taskId: taskId)
        let placements = reached.ownPlacements
        let boards = reached.boards
        let parents = try db.fetchCompoundParents(forTaskId: taskId)
        let children = try db.fetchCompoundChildrenTasks(parentTaskId: taskId)
        let templates = try db.fetchTemplatesReferencingTask(taskId)
        let userTasks = includeUserTasks ? try db.fetchTasks(userId: userId) : nil
        let counterId: String? = task.type == .counting
            ? (task.sharedCounterId ?? (task.isCounter == true ? task.id : nil))
            : task.countsTowardCounterId
        let root = try counterId.flatMap { try db.fetchTask(id: $0) }.flatMap { $0.isDeleted || $0.userId != userId ? nil : $0 }
        let links = task.type == .compound ? try db.fetchCompoundChildren(compoundTaskId: taskId) : []
        var ids = [task.id]
        if let rootId = task.sharedCounterId { ids.append(rootId) }
        for child in children {
            ids.append(child.id)
            if let rootId = child.sharedCounterId { ids.append(rootId) }
        }
        ids = Array(Set(ids))
        let events = try db.read { d -> [String: [TaskEvent]] in
            // One query for every id (a task id with no events keeps its empty entry).
            var out: [String: [TaskEvent]] = Dictionary(uniqueKeysWithValues: ids.map { ($0, []) })
            for e in try TaskEvent.filter(ids.contains(Column("taskId")) && Column("isDeleted") == false).fetchAll(d) {
                out[e.taskId, default: []].append(e)
            }
            return out
        }
        var picker: ([Board], [RecurringBoardTemplate]) = ([], [])
        if task.type == .achievement {
            picker = (try db.fetchBoards(userId: userId), try db.fetchRecurringBoardTemplates(userId: userId))
        }
        let blocked = (try? db.sealBlockedTaskIds(taskIds: Set([task.id] + children.map(\.id)))) ?? []
        let watchedBoard = try task.referencedBoardId.flatMap { try db.fetchBoards(ids: [$0]).first { !$0.isDeleted } }
        return Snapshot(
            task: task, placements: placements, anchorCandidates: reached.anchorCandidates, boards: boards, rows: reached.rows, taskById: reached.taskById, parents: parents, children: children, templates: templates,
            events: events, counterRoot: root, userTasks: userTasks, pickerBoards: picker.0, pickerTemplates: picker.1,
            sealBlocked: blocked, watchedBoard: watchedBoard, childLinks: links
        )
    }

    // MARK: - Load

    /// Loads (or switches to) `taskId` and builds the model. Clears the strip.
    func load(taskId: String? = nil) async {
        if let taskId, taskId != self.taskId { strip = nil; model = nil; anchor = nil; watched = nil }
        if let taskId { self.taskId = taskId }
        loadToken += 1
        let token = loadToken
        let id = self.taskId, db = database
        do {
            let fetch = snapshotFetcher
            let snap = try await _Concurrency.Task.detached(priority: .userInitiated) {
                try fetch(id, db, true)
            }.value
            guard token == loadToken else { return }
            guard let snap else {
                loadError = "Task not found"
                return
            }
            loadError = nil
            apply(snap)
        } catch {
            guard token == loadToken else { return }
            loadError = "Failed to load task: \(error.localizedDescription)"
        }
    }

    /// Re-reads everything (after a write, an edit, or returning from Counter Detail).
    func refresh() async { await load() }

    private func apply(_ snap: Snapshot) {
        snapshot = snap
        task = snap.task
        compoundChildren = snap.children
        pickerBoards = snap.pickerBoards
        pickerTemplates = snap.pickerTemplates
        counterRoot = snap.counterRoot
        if let all = snap.userTasks { userTasks = all }
        // The hero anchors on a square that IS the task — its own, a counter root's
        // linked row's, or a direct-parent compound's (binding decision 3, amended
        // 2026-10-18): the best rank with a square in play, its soonest-ending board.
        anchorChoice = Self.chooseAnchor(snap.anchorCandidates, boards: snap.boards, now: clock())
        setAnchor(anchorChoice?.placement.boardId)
        if snap.task.type == .achievement { setWatched(snap.task.referencedBoardId) } else { watched = nil; watchedSub = nil }
    }

    /// The best-ranked candidate whose board is in play; within a rank, the soonest-ending board.
    nonisolated static func chooseAnchor(
        _ candidates: [AppDatabase.HeroAnchorCandidate], boards: [Board], now: Date
    ) -> AppDatabase.HeroAnchorCandidate? {
        for rank in 0...2 {
            let ofRank = candidates.filter { $0.rank == rank }
            let ids = Set(ofRank.map(\.placement.boardId))
            if let board = TaskDetailKernel.heroAnchorBoard(boards.filter { ids.contains($0.id) }, now: now) {
                return ofRank.first { $0.placement.boardId == board.id }
            }
        }
        return nil
    }

    private func setAnchor(_ boardId: String?) {
        guard let boardId else {
            anchor = nil; anchorSub = nil; processingSub = nil
            isBusy = false
            rebuild()
            return
        }
        if anchor?.boardId != boardId {
            let vm = BoardPlayViewModel(boardId: boardId, userId: snapshot?.task.userId, database: database)
            anchor = vm
            anchorSub = vm.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.rebuild() }
            }
            // A write finishing refreshes the non-anchor reads (activity, rows, footer).
            processingSub = vm.$isProcessing.removeDuplicates().sink { [weak self] busy in
                guard let self else { return }
                self.isBusy = busy
                if !busy, self.model != nil { _Concurrency.Task { await self.refreshAfterWrite() } }
            }
        }
        anchor?.reload { [weak self] in self?.rebuild() }
    }

    private var refreshing = false
    /// A refresh was requested while one was in flight: its snapshot may predate that write, so
    /// run once more when the in-flight fetch lands (a dropped request left the lower sections stale).
    private var refreshQueued = false
    /// Re-reads the non-anchor sections after a write. Coalesces: a request during a fetch sets a
    /// dirty flag and the loop reads again afterwards, so the last write is always reflected.
    func refreshAfterWrite() async {
        if refreshing { refreshQueued = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshQueued = false
            let id = taskId, db = database, fetch = snapshotFetcher
            guard let snap = try? await _Concurrency.Task.detached(priority: .userInitiated, operation: {
                try fetch(id, db, false)
            }).value, id == taskId else { continue }
            snapshot = snap
            task = snap.task
            rebuild()
        } while refreshQueued
    }

    /// The achievement's watched board, loaded through its own board view model so its
    /// per-cell completion comes from the same kernel the board grid reads.
    private func setWatched(_ boardId: String?) {
        guard let boardId else { watched = nil; watchedSub = nil; return }
        if watched?.boardId != boardId {
            let vm = BoardPlayViewModel(boardId: boardId, userId: snapshot?.task.userId, database: database)
            watched = vm
            watchedSub = vm.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }
        }
        watched?.reload { [weak self] in self?.rebuild() }
    }

    // MARK: - Watched board's per-cell completion (the one new read)

    /// Row-major completion flags for a board: a sealed board reads its frozen
    /// `sealedCompletedCells`, a live one the kernel's per-cell states; a FREE centre
    /// counts as complete; an empty square does not.
    nonisolated static func completionGrid(
        board: Board, boardTasks: [BoardTask], cellStates: [String: DerivationPass.CellState]
    ) -> [Bool] {
        let size = board.boardSize
        var grid = Array(repeating: false, count: size * size)
        if let sealed = board.sealedCompletedCells {
            for i in sealed where i >= 0 && i < grid.count { grid[i] = true }
        } else {
            for bt in PlacementIntegrity.resolvePlacements(boardTasks, boardSize: size) {
                let i = bt.row * size + bt.col
                if i >= 0, i < grid.count, cellStates[bt.id]?.isCompleted == true { grid[i] = true }
            }
        }
        if size % 2 == 1, CenterSquare.effectiveCenter(board.centerSquareType) == .free {
            grid[(size / 2) * size + size / 2] = true
        }
        return grid
    }

    // MARK: - Model

    /// The anchor board's live copy of the chosen square.
    private var anchorPlacement: BoardTask? {
        guard let a = anchor, let choice = anchorChoice, choice.placement.boardId == a.boardId else { return nil }
        return a.boardTasks.first { $0.id == choice.placement.id && !$0.isDeleted }
    }

    /// The compound child the hero drives, when the anchor square is its parent's.
    private var anchorChildId: String? { anchorChoice?.childTaskId }

    private func rebuild() {
        guard let snap = snapshot else { return }
        model = buildModel(snap)
    }

    private func buildModel(_ snap: Snapshot) -> TaskDetailModel {
        let task = snap.task
        let now = clock()
        let root = snap.counterRoot
        let family = resolveFamilyCountKind(task, lookup: { id in id == root?.id ? root : snap.taskById[id] })
        let counterName = task.type == .normal ? root.map { CounterSettings.counterDisplayName($0) } : nil
        let ruleLabel: String? = task.type == .compound
            ? CompoundEvaluation.compoundRuleLabel(task.operatorType, threshold: task.threshold, childCount: snap.children.count)
            : nil

        // Hero, read through the anchor board.
        var hero: TaskDetailModel.Hero = .none
        var anchorName: String?
        var anchorTimeframe: Timeframe?
        if let a = anchor, let bt = anchorPlacement, let placed = a.placedTask(bt), a.board != nil {
            anchorName = a.board?.displayName
            anchorTimeframe = a.board?.timeframe
            if let childId = anchorChildId {
                // The hero is ONE child of the anchor compound: its own control.
                if let child = a.squareCompound(bt, placed, sealBlocked: snap.sealBlocked).children.first(where: { $0.id == childId }) {
                    if let count = child.counting { hero = .counting(count) } else { hero = .normal(isDone: child.isDone, sealBlocked: child.sealBlocked) }
                }
            } else {
            switch task.type {
            case .counting:
                hero = .counting(a.squareCountState(placed))
            case .normal:
                let done = a.squareNormalDone(bt, placed)
                hero = .normal(isDone: done, sealBlocked: done && snap.sealBlocked.contains(task.id))
            case .compound:
                hero = .compound(a.squareCompound(bt, placed, sealBlocked: snap.sealBlocked), ruleLabel: ruleLabel ?? "")
            case .achievement:
                let card = a.squareAchievement(bt, placed)
                var line: TaskDetailKernel.ClosestLine?
                if let w = watched, let wb = w.board {
                    line = TaskDetailKernel.closestLine(
                        Self.completionGrid(board: wb, boardTasks: w.boardTasks, cellStates: w.kernelCellStates), gridSize: wb.boardSize
                    )
                }
                let grid = (watched?.board).map { Self.completionGrid(board: $0, boardTasks: watched?.boardTasks ?? [], cellStates: watched?.kernelCellStates ?? [:]) } ?? []
                hero = .achievement(.init(card: card, closestLine: line, lineCells: line.map { l in l.cells.map { grid.indices.contains($0) ? grid[$0] : false } } ?? []))
            }
            }
        } else if anchorChoice == nil, task.type == .counting {
            // No square in play: the board-less control over the all-time count.
            let source = boardlessSource(snap)
            let current = source?.currentCount ?? 0
            hero = .boardlessCounting(.init(
                current: current, goal: 0, unit: source?.unit ?? task.unit ?? "", kind: family,
                chips: CounterLogAmount.tapChips(kind: family, goal: nil)
            ))
        }

        // Counter row.
        var counter: TaskDetailModel.CounterLink?
        if let root {
            let kind = resolveCountKind(root.countKind)
            counter = .init(
                counterId: root.id, label: task.type == .counting ? "Shared counter" : "Counts toward",
                name: CounterSettings.counterDisplayName(root),
                total: formatCountTotal(root.currentCount ?? 0, kind: kind),
                unit: countUnitSuffix(kind, unit: root.unit).trimmingCharacters(in: .whitespaces)
            )
        }

        // Placement rows: a value on EVERY board, read through that board's own window.
        var active: [TaskDetailModel.BoardRow] = []
        var past: [TaskDetailModel.BoardRow] = []
        var missed: [TaskDetailKernel.MissedBoard] = []
        let ordered = snap.boards.sorted { a, b in
            if compareBoardsForList(a, b, now: now) { return true }
            if compareBoardsForList(b, a, now: now) { return false }
            return a.id < b.id
        }
        let kernelRows = Dictionary(snap.rows.map { ($0.boardId, $0) }, uniquingKeysWith: { a, _ in a })
        for board in ordered {
            guard let kernelRow = kernelRows[board.id], let member = snap.taskById[kernelRow.memberTaskId] else { continue }
            let isDraft = board.status == .draft
            let isActive = !isDraft && isBoardActiveForList(board, now: now)
            var v = Self.rowValue(kernelRow, member: member, taskById: snap.taskById)
            if task.type == .achievement, board.id == anchor?.boardId, case let .achievement(a) = hero, a.card.isMet {
                v = RowValue(value: "Done", sub: nil, done: true, fraction: 1)
            }
            let badge: String? = board.isCore ? "Core · \(board.timeframe.rawValue)" : nil
            var row = TaskDetailModel.BoardRow(
                id: board.id, name: board.displayName, badge: badge, caption: "",
                value: v?.value, valueSub: v?.sub, isDone: v?.done ?? false, isDraft: isDraft, fraction: v?.fraction ?? 0
            )
            if isDraft { row.value = nil; row.valueSub = nil }
            if isActive {
                row.caption = TaskDetailFormat.activeCaption(timeframe: board.timeframe, endDate: board.endDate, now: now)
                active.append(row)
            } else {
                // Missed = the window is OVER and the task did not complete it (a board closed
                // before its end is not missed). Normal, Counting with a goal, Compound.
                if !isDraft, Self.windowIsOver(board, now: now), !row.isDone, Self.canBeMissed(member, row: kernelRow) {
                    missed.append(.init(boardId: board.id, endDate: board.endDate ?? board.startDate))
                }
                row.caption = TaskDetailFormat.pastCaption(
                    isDraft: isDraft, timeframe: board.timeframe, start: board.startDate, end: board.endDate,
                    status: boardPlacementStatus(board, now: now)
                )
                past.append(row)
            }
        }

        // Activity (derived, no persisted log — E5).
        let boardNames = Dictionary(uniqueKeysWithValues: snap.boards.map { ($0.id, $0.displayName) })
        let feed = TaskDetailKernel.activity(
            taskId: task.id, createdAt: task.createdAt, unit: root?.unit ?? task.unit, kind: family,
            events: (snap.events[task.id] ?? []) + (task.sharedCounterId.flatMap { snap.events[$0] } ?? []),
            placements: snap.placements, missed: missed, boardNames: boardNames
        )
        let lines = feed.rows.map {
            TaskDetailModel.ActivityLine(id: $0.key, kind: $0.kind, text: $0.text, when: TaskDetailFormat.activityDate($0.at, now: now))
        }

        // Links.
        let parents = snap.parents.map { TaskDetailModel.Link(id: $0.id, title: $0.title, kind: .compound) }
        let subtasks = snap.children.map { child in
            TaskDetailModel.Link(
                id: child.id, title: child.title, kind: RisoTaskKind(taskType: child.type),
                isDone: anchor?.compoundChildIsCompleted(child) ?? false
            )
        }
        var watches: TaskDetailModel.Link?
        var watchesMeta: String?
        var watchesHeading = "Watches board"
        var watchedBoardId: String?
        if task.type == .achievement {
            let trigger = (task.achievementTrigger ?? .greenlog) == .bingo ? "First bingo" : "Greenlog"
            if let wb = snap.watchedBoard {
                watches = .init(id: wb.id, title: wb.displayName, kind: .achievement)
                watchedBoardId = wb.id
                watchesMeta = trigger
            } else if let tpl = snap.templates.first(where: { $0.id == task.referencedTemplateId }) {
                watches = .init(id: tpl.id, title: tpl.name, kind: .achievement)
                watchesHeading = "Watches repeating board"
                watchesMeta = trigger
            }
        }

        return TaskDetailModel(
            taskId: task.id, title: task.title.isEmpty ? "(untitled task)" : task.title,
            description: (task.description ?? "").isEmpty ? nil : task.description,
            kind: RisoTaskKind(taskType: task.type),
            kicker: TaskDetailFormat.kicker(task: task, countKind: family, counterName: counterName, ruleLabel: ruleLabel),
            anchorName: anchorName, anchorTimeframe: anchorTimeframe, hero: hero, counter: counter,
            activeBoards: active, pastBoards: past, parents: parents, subtasks: subtasks, subtaskRule: ruleLabel,
            watches: watches, watchesHeading: watchesHeading, watchesMeta: watchesMeta, watchedBoardId: watchedBoardId,
            templates: snap.templates.map { .init(id: $0.id, name: $0.name) },
            activity: lines, footer: TaskDetailFormat.footer(completions: feed.completionCount, updatedAt: task.updatedAt, now: now)
        )
    }

    /// One placement row's windowed value.
    struct RowValue: Equatable {
        let value: String?
        let sub: String?
        let done: Bool
        let fraction: Double
    }

    /// Whether the board's window is over (its `endDate` is past) — a board closed early is not.
    nonisolated static func windowIsOver(_ board: Board, now: Date) -> Bool {
        guard let end = board.endDate.flatMap({ parseISO8601Date($0) }) else { return false }
        return end < now
    }

    /// A row's member can be missed when it has something to miss: a Normal, a
    /// Counting with a goal on that board, a Compound with sub-tasks; never an
    /// achievement.
    nonisolated static func canBeMissed(_ member: Task, row: TaskPlacementRows.Row) -> Bool {
        switch member.type {
        case .normal: return true
        case .counting: return (row.goal ?? 0) > 0
        case .compound: return (row.childrenTotal ?? 0) > 0
        case .achievement: return false
        }
    }

    /// A placement row's value, formatted from the kernel's per-board state:
    /// Normal ("Done" or nothing), Counting ("12" / "/20"), Compound ("2" / "/3").
    /// The member may be a sub-task reached through a compound or a counter
    /// root's linked row — the value is the member's.
    nonisolated static func rowValue(_ row: TaskPlacementRows.Row, member: Task, taskById: [String: Task]) -> RowValue? {
        if let count = row.count {
            let kind = resolveFamilyCountKind(member, lookup: { taskById[$0] })
            let goal = row.goal ?? 0
            return RowValue(
                value: formatCount(count, kind: kind), sub: goal > 0 ? "/\(formatCount(goal, kind: kind))" : nil,
                done: row.done, fraction: goal > 0 ? min(1, count / goal) : 0
            )
        }
        if let total = row.childrenTotal, total > 0 {
            let doneCount = row.childrenDone ?? 0
            return RowValue(
                value: "\(doneCount)", sub: "/\(total)", done: row.done,
                fraction: row.done ? 1 : Double(doneCount) / Double(total)
            )
        }
        return RowValue(value: row.done ? "Done" : nil, sub: nil, done: row.done, fraction: row.done ? 1 : 0)
    }

    // MARK: - Hero writes (through the anchor placement)

    /// Toggles a Normal task on the anchor board; the strip names the new state.
    func toggleNormal() {
        if let childId = anchorChildId {
            toggleChild(childId)
            strip = strip.map(rescopedToPage)
            return
        }
        guard let a = anchor, let bt = anchorPlacement, let placed = a.placedTask(bt), !a.isProcessing else { return }
        let wasDone = a.squareNormalDone(bt, placed)
        strip = nil
        a.handleNormalTap(boardTask: bt)
        strip = SquareLogStrip.afterWrite(started: a.isProcessing, SquareLogStrip(
            boardTaskId: bt.id, scopeTaskId: taskId,
            text: SquareSheetFormat.toggleText(title: placed.title, nowDone: !wasDone),
            undo: .restoreNormal(boardTaskId: bt.id, wasDone: wasDone)
        ))
    }

    /// A chip / entry log (or removal) on the task itself, or on one of its counting children.
    func log(taskId logged: String? = nil, amount: CountValue, persistAsDefault: Bool = false, removing: Bool = false) {
        guard let a = anchor, let bt = anchorPlacement else {
            if anchorChoice == nil { boardlessLog(amount: amount, persistAsDefault: persistAsDefault, removing: removing) }
            return
        }
        // On a compound child's anchor the hero's own log is the child's.
        let requested = logged ?? taskId
        let target = requested == taskId ? (anchorChildId ?? taskId) : requested
        strip = nil
        let written = a.performSquareLog(placement: bt, taskId: target, amount: amount, persistAsDefault: persistAsDefault, removing: removing)
        // A remapped hero write (a root anchored on a linked child) keeps the hero's strip scope.
        strip = requested == taskId ? written.map(rescopedToPage) : written
    }

    /// The strip re-scoped to this page's task, so the hero shows it whatever square it wrote.
    private func rescopedToPage(_ s: SquareLogStrip) -> SquareLogStrip {
        SquareLogStrip(boardTaskId: s.boardTaskId, scopeTaskId: taskId, text: s.text, undo: s.undo)
    }

    // MARK: - Board-less writes (no square in play)

    /// The task a board-less log writes: a linked row's root, else the task itself
    /// (a unit task's counter credit follows from its own cascade).
    private func boardlessSource(_ snap: Snapshot) -> Task? {
        snap.task.sharedCounterId != nil ? snap.counterRoot : snap.task
    }

    /// Logs (or removes) "now" through the counter writes the Counters hub uses.
    private func boardlessLog(amount: CountValue, persistAsDefault: Bool, removing: Bool) {
        guard let snap = snapshot, let source = boardlessSource(snap), !isBusy, amount > 0 else { return }
        let db = database, id = source.id
        let kind = resolveFamilyCountKind(source, lookup: { $0 == source.id ? source : nil })
        let unit = source.unit ?? ""
        strip = nil
        isBusy = true
        _Concurrency.Task {
            defer { isBusy = false }
            do {
                let applied: CountValue = try await _Concurrency.Task.detached(priority: .userInitiated) {
                    if removing { return -(try db.decrementSharedCounter(sourceTaskId: id, by: amount).effectiveDelta.magnitude) }
                    _ = try db.incrementSharedCounter(sourceTaskId: id, by: amount)
                    if persistAsDefault { try db.setCounterDefaultLogAmount(sourceTaskId: id, amount: amount) }
                    return amount
                }.value
                await refreshAfterWrite()
                guard applied != 0 else { return }
                strip = SquareLogStrip(
                    boardTaskId: "", scopeTaskId: taskId,
                    text: SquareSheetFormat.logText(amount: applied.magnitude, kind: kind, unit: unit, board: Self.allTime, removed: applied < 0),
                    undo: applied > 0 ? .counterLog(sourceTaskId: id) : .childDelta(taskId: id, delta: applied)
                )
            } catch {
                saveError = "Couldn't log: \(error.localizedDescription)"
            }
        }
    }

    /// Reverses a board-less write: the counter's last log entry, or re-adds a removal.
    private func boardlessUndo(_ undo: SquareLogUndo) {
        let db = database
        isBusy = true
        _Concurrency.Task {
            defer { isBusy = false }
            do {
                try await _Concurrency.Task.detached(priority: .userInitiated) {
                    switch undo {
                    case let .counterLog(id): _ = try db.undoLastCounterLog(sourceTaskId: id)
                    case let .childDelta(id, delta) where delta < 0: _ = try db.incrementSharedCounter(sourceTaskId: id, by: -delta)
                    default: break
                    }
                }.value
                await refreshAfterWrite()
            } catch {
                saveError = "Couldn't undo: \(error.localizedDescription)"
            }
        }
    }

    /// The board-less hero's label (the count's scope).
    nonisolated static let allTime = "All-time"

    /// A compound child's checklist toggle.
    func toggleChild(_ childId: String) {
        guard let a = anchor, let bt = anchorPlacement else { return }
        strip = nil
        strip = a.performChildToggle(placement: bt, childId: childId)
    }

    /// Reverses exactly the write the strip describes.
    func undo() {
        if anchor == nil, let s = strip, !isBusy { strip = nil; boardlessUndo(s.undo); return }
        guard let a = anchor, let s = strip, !a.isProcessing else { return }
        strip = nil
        a.undoSquareLog(s.undo)
    }

    // MARK: - Edit / delete

    /// Saves the edit sheet's patch (`applyTaskEditPatch`: validation + cycle check + cascade).
    func saveEdits(patch: EditTaskSheet.Patch) async -> Bool {
        let db = database, id = taskId
        do {
            _ = try await _Concurrency.Task.detached(priority: .userInitiated) { try db.applyTaskEditPatch(taskId: id, patch: patch) }.value
            saveError = nil
            await refresh()
            return true
        } catch {
            saveError = AppDatabase.taskEditErrorMessage(error)
            return false
        }
    }

    func computeDeleteImpact() async -> AppDatabase.TaskDeletionImpact? {
        let db = database, id = taskId
        do {
            return try await _Concurrency.Task.detached(priority: .userInitiated) { try db.computeTaskDeletionImpact(taskId: id) }.value
        } catch {
            saveError = "Failed to compute delete impact: \(error.localizedDescription)"
            return nil
        }
    }

    func performDelete() async -> Bool {
        let db = database, id = taskId
        do {
            try await _Concurrency.Task.detached(priority: .userInitiated) { try db.deleteTaskWithCascade(taskId: id) }.value
            return true
        } catch {
            saveError = "Failed to delete: \(error.localizedDescription)"
            return false
        }
    }

    /// The delete confirm's consequence lines.
    static func deleteConfirmMessage(_ impact: AppDatabase.TaskDeletionImpact) -> String {
        var lines: [String] = ["This can't be undone."]
        if impact.boardTaskCount > 0 {
            lines.append("Removes from \(impact.boardTaskCount) board square\(impact.boardTaskCount == 1 ? "" : "s") across \(impact.affectedBoardIds.count) board\(impact.affectedBoardIds.count == 1 ? "" : "s").")
        }
        if impact.childLinkCount > 0 {
            lines.append("Detaches from \(impact.childLinkCount) compound parent\(impact.childLinkCount == 1 ? "" : "s").")
        }
        if impact.parentLinkCount > 0 {
            lines.append("Releases \(impact.parentLinkCount) subtask\(impact.parentLinkCount == 1 ? "" : "s") (subtasks stay in your library).")
        }
        return lines.joined(separator: "\n")
    }
}
