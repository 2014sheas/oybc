import Foundation
import SwiftUI
@testable import OYBC

/// Builders for realistic mock data used across snapshot tests. Keeps
/// the test files focused on render variants rather than wiring up
/// model instances by hand each time.
///
/// Design choices:
/// - Tasks / boards / compoundChildren are constructed in-memory; we
///   do NOT round-trip through GRDB. The wizard step views read from a
///   `TaskLibraryViewModel` whose @Observable properties can be set
///   directly, which is faster and deterministic for snapshot runs.
/// - `BoardPlayView` does GRDB queries — those snapshots seed an
///   in-memory `AppDatabase.makeTestInstance()` and route reads through
///   it (covered when its tests are added).
/// - All ISO timestamps are pinned (`fixedTimestamp`) so snapshots
///   don't change across runs.
enum SnapshotFixtures {

    /// Stable timestamp used everywhere — keeps snapshot output identical
    /// across machines + days.
    static let fixedTimestamp = "2026-04-01T12:00:00Z"

    /// User id used by every fixture builder — matches the playground user
    /// so seeded data stays distinguishable from real-account data.
    static let userId = "snapshot-user-1"

    // MARK: - Library states

    enum LibraryState {
        case empty
        /// Mix of normal + counting + compound. Add narrower states
        /// (e.g. `onlyCounting`) when a test needs to isolate one type.
        case dense
    }

    /// Returns a `TaskLibraryViewModel` populated for a given render
    /// state. All view-model properties are set directly — no DB,
    /// no async load.
    static func makeTaskLibrary(state: LibraryState) -> TaskLibraryViewModel {
        let library = TaskLibraryViewModel()
        switch state {
        case .empty:
            break
        case .dense:
            let (tasks, children) = denseTaskSet()
            library.libraryTasks = tasks
            // Mirror reload(): browse surfaces read `browsableTasks`. The dense
            // fixtures are all standalone (createdInWizard == false), so the
            // browsable set equals the full set.
            library.browsableTasks = tasks
            library.allCompoundChildren = children
            library.compoundChildrenByCompound = groupChildren(children)
            library.allLibraryBoardTasks = sampleBoardTasks(taskIds: tasks.prefix(5).map { $0.id })
        }
        return library
    }

    // MARK: - Task builders

    static func makeTask(
        id: String,
        title: String,
        type: TaskType,
        action: String? = nil,
        unit: String? = nil,
        maxCount: Int? = nil,
        operatorType: OperatorType? = nil,
        threshold: Int? = nil,
        isCompleted: Bool = false
    ) -> Task {
        Task(
            id: id,
            userId: userId,
            title: title,
            description: nil,
            type: type,
            action: action,
            unit: unit,
            maxCount: maxCount,
            operatorType: operatorType,
            threshold: threshold,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: isCompleted,
            completedAt: nil,
            currentCount: nil,
            createdAt: fixedTimestamp,
            updatedAt: fixedTimestamp,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
    }

    static func makeCompoundChild(
        id: String,
        compoundTaskId: String,
        childTaskId: String,
        childIndex: Int
    ) -> CompoundChild {
        CompoundChild(
            id: id,
            compoundTaskId: compoundTaskId,
            childTaskId: childTaskId,
            childIndex: childIndex,
            createdAt: fixedTimestamp,
            updatedAt: fixedTimestamp,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
    }

    /// Build a `BoardPreviewCellsResult` fixture for `RisoBoardCard`/`RisoMiniGrid`
    /// snapshots (bugfix/board-preview-real-cells) — `RisoBoardCard.previewCells`
    /// is a required prop (no self-loading fallback), so every fixture that
    /// composes a `RisoBoardCard` needs an explicit value to stay DB-free.
    /// Marks the first `completed` of `size*size` cells done (row-major); not
    /// meant to exercise `BoardPreviewCells.build`'s real positional/derivation
    /// logic (see `BoardPreviewCellsTests` for that) — purely a pixel fixture.
    static func makePreviewCells(completed: Int, size: Int = 5) -> BoardPreviewCellsResult {
        let cells: [BoardPreviewCell] = (0..<(size * size)).map { $0 < completed ? .task(completed: true) : .task(completed: false) }
        return BoardPreviewCellsResult(size: size, cells: cells)
    }

    static func makeBoardTask(
        id: String,
        boardId: String,
        taskId: String,
        row: Int,
        col: Int,
        isCenter: Bool = false
    ) -> BoardTask {
        BoardTask(
            id: id,
            boardId: boardId,
            taskId: taskId,
            row: row,
            col: col,
            isCenter: isCenter,
            createdAt: fixedTimestamp,
            updatedAt: fixedTimestamp,
            version: 1
        )
    }

    /// Build a Board fixture via JSON round-trip (Board has no member-
    /// wise init because of its custom Codable decoder). Used by Phase
    /// 6.3 snapshot tests for both the achievement-square config sheet
    /// (board picker) and the cell-badge variants. Dates default to
    /// April 2026 (matching the algorithm-test fixtures) so spawn-in-
    /// window math stays predictable.
    static func makeBoard(
        id: String,
        name: String,
        boardSize: Int = 5,
        timeframe: Timeframe = .monthly,
        status: BoardStatus = .active,
        startDate: String = "2026-04-01T00:00:00.000Z",
        endDate: String = "2026-04-30T23:59:59.000Z",
        spawnedFromTemplateId: String? = nil,
        isCore: Bool = false,
        isDeleted: Bool = false
    ) -> Board {
        var dict: [String: Any] = [
            "id": id,
            "userId": userId,
            "name": name,
            "status": status.rawValue,
            "boardSize": boardSize,
            "timeframe": timeframe.rawValue,
            "startDate": startDate,
            "endDate": endDate,
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "totalTasks": boardSize * boardSize,
            "completedTasks": 0,
            "linesCompleted": 0,
            "completedLineIds": "[]",
            "createdAt": fixedTimestamp,
            "updatedAt": fixedTimestamp,
            "version": 1,
            "isCore": isCore,
            "isDeleted": isDeleted,
        ]
        if let tid = spawnedFromTemplateId { dict["spawnedFromTemplateId"] = tid }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    static func makeRecurringTemplate(
        id: String,
        name: String,
        timeframe: Timeframe = .monthly,
        boardSize: Int = 5,
        centerSquareType: CenterSquareType = .free,
        isRandomized: Bool = true,
        seedTaskCount: Int = 24,
        isActive: Bool = true,
        lastSpawnedWindowKey: String? = nil,
        // P7 (Board settings roster edit sheet) — optional pool-mix fields.
        // `nil` (the default) preserves every existing call site's
        // "genuinely un-migrated" decode shape unchanged.
        poolIds: [String]? = nil,
        manualTaskIds: [String]? = nil,
        removedTaskIds: [String]? = nil
    ) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: id,
            userId: userId,
            name: name,
            timeframe: timeframe,
            boardSize: boardSize,
            centerSquareType: centerSquareType,
            isRandomized: isRandomized,
            seedTaskIds: (0..<seedTaskCount).map { "\(id)-task-\($0)" },
            poolIds: poolIds,
            manualTaskIds: manualTaskIds,
            removedTaskIds: removedTaskIds,
            lastSpawnedWindowKey: lastSpawnedWindowKey,
            isActive: isActive,
            createdAt: fixedTimestamp,
            updatedAt: fixedTimestamp,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
    }

    // MARK: - Pool (Task Pools + Recurring Boards Rework, P1+)

    static func makeTestPool(id: String, name: String, taskIds: [String]) -> Pool {
        Pool(
            id: id, userId: userId, name: name, taskIds: taskIds,
            createdAt: fixedTimestamp, updatedAt: fixedTimestamp,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    static func makeCoreBoardDefault(
        id: String,
        timeframe: Timeframe,
        corePoolIds: [String] = [],
        coreDefaultTaskIds: [String] = []
    ) -> CoreBoardDefault {
        CoreBoardDefault(
            id: id, userId: userId, timeframe: timeframe,
            corePoolIds: corePoolIds, coreDefaultTaskIds: coreDefaultTaskIds,
            createdAt: fixedTimestamp, updatedAt: fixedTimestamp,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    // MARK: - Wizard controller

    /// Stage hint for the controller — Setup blank, Setup valid, or
    /// Preview with a full selection. Add narrower stages when a test
    /// needs to capture a partially-filled state (e.g. tasks step
    /// halfway selected).
    enum WizardStage: Equatable {
        case setupBlank
        case setupValid
        case setupRecurring
        case setupIndefinite
        case previewReady
        case previewRecurring
    }

    /// Fixed reference date used by all wizard-controller fixtures so
    /// `computedBoundaries` / `timeframeDisplayLabel` resolve to a
    /// stable calendar window regardless of when the tests run.
    ///
    /// Chosen as 2026-04-01 (Wednesday) — a known Wednesday so weekly
    /// boundaries (Mon–Sun with the monday weekStartDay pref) resolve
    /// to "Week of Mar 30 – Apr 5, 2026" deterministically. The same
    /// date is already the `fixedTimestamp` epoch used elsewhere in
    /// the fixtures, which keeps everything consistent.
    static let fixedReferenceDate: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 1
        comps.hour = 12; comps.minute = 0; comps.second = 0
        return Calendar.current.date(from: comps)!
    }()

    static func makeWizardController(stage: WizardStage = .setupBlank) -> BoardWizardViewModel {
        let prefs = makeUserPreferences()
        // Board Creation Split (iOS PR A) — `isRecurring` is now fixed at
        // init, so the recurring stages must pass `startRecurring: true`
        // here rather than assigning `controller.isRecurring` afterward.
        let startRecurring = (stage == .setupRecurring || stage == .previewRecurring)
        // Pass a fixed targetWindowDate so computedBoundaries (and the Riso
        // date note in RisoBoardSetupForm) resolves to a deterministic calendar
        // window instead of Date() — prevents month-rollover snapshot flakiness.
        let controller = BoardWizardViewModel(
            preferences: prefs,
            targetWindowDate: fixedReferenceDate,
            startRecurring: startRecurring
        )
        switch stage {
        case .setupBlank:
            break
        case .setupValid:
            controller.name = "April Reading Sprint"
            controller.timeframe = .monthly
        case .setupRecurring:
            // Recurring hub-card entry (Board Creation Split — mode fixed
            // at init via `startRecurring`, set above). Verifies the
            // "REPEATS EVERY" card renders + Custom/ongoing are absent.
            // Weekly chosen so the cadence label and the "starts …" caption
            // both differ from a daily/monthly variant.
            controller.name = "Weekly Workout"
            controller.updateTimeframe(.weekly)
        case .setupIndefinite:
            // Ongoing board — the "Custom" segment is selected and the End-date
            // control reads "None". Pin a fixed customStartDate so the Start
            // date picker renders deterministically (it binds to a live Date()
            // otherwise, which would flake the baseline on calendar rollover).
            controller.name = "Someday / Maybe"
            controller.timeframe = .indefinite
            controller.customStartDate = "2026-04-01"
        case .previewReady:
            controller.name = "April Reading Sprint"
            controller.timeframe = .monthly
            controller.currentStep = 3
            // Pin shuffle off — randomized placement breaks snapshot
            // determinism (every render produces a different grid).
            controller.isRandomized = false
            controller.selectedTaskIds = Set(denseTaskSet().0.prefix(controller.size * controller.size).map { $0.id })
            // Keep `poolOrder` in lockstep with `selectedTaskIds`, matching
            // the invariant every real mutator (`toggleTaskSelection` etc.)
            // maintains — sorted (not raw Set order) for the same
            // determinism reason `buildWizardPlacement` sorts when
            // `isRandomized == false`.
            controller.poolOrder = Array(controller.selectedTaskIds).sorted()
        case .previewRecurring:
            controller.name = "Weekly Workout"
            controller.updateTimeframe(.weekly)
            controller.currentStep = 3
            controller.isRandomized = false
            controller.selectedTaskIds = Set(denseTaskSet().0.prefix(controller.size * controller.size).map { $0.id })
            // P4 — the Preview step's recurring "deck" branch renders via
            // `RisoPoolListView`, which reads `poolOrder` (not raw
            // `selectedTaskIds`) for row order; without this the deck
            // rendered as an empty list despite a non-empty selection.
            controller.poolOrder = Array(controller.selectedTaskIds).sorted()
        }
        return controller
    }

    /// Returns user prefs pinned to a non-`.custom` timeframe so the
    /// wizard's customStartDate/customEndDate don't get seeded from
    /// `Date()` — that would drift the rendered date pickers across
    /// days and flake snapshot baselines. Monthly resolves to the
    /// current calendar month, which is also date-dependent — but the
    /// Setup step doesn't display those dates when Monthly is the
    /// selection (only the timeframe pill renders), so the snapshot
    /// stays stable.
    static func makeUserPreferences() -> UserPreferences {
        UserPreferences(
            weekStartDay: .monday,
            defaultBoardSize: .five,
            defaultCenterType: .free,
            defaultTimeframe: .monthly,
            defaultRandomize: true,
            theme: .system,
            // Snapshot fixtures pin the recurring*Enabled flags off so any
            // existing snapshot baselines that render the wizard or hub
            // surface stay byte-identical. New tests for the
            // PendingCoreBoardsSection seed their own pending list directly
            // and don't rely on this fixture's pref values.
            recurringDailyEnabled: false,
            recurringWeeklyEnabled: false,
            recurringMonthlyEnabled: false,
            recurringYearlyEnabled: false
        )
    }

    // MARK: - Internal builders

    /// Returns realistic primitive (.normal) tasks with everyday-goal
    /// titles so renders feel natural.
    private static func normalTasks() -> [Task] {
        [
            makeTask(id: "t-normal-1", title: "Morning workout", type: .normal),
            makeTask(id: "t-normal-2", title: "Cook a meal at home", type: .normal),
            makeTask(id: "t-normal-3", title: "Call a friend or family member", type: .normal),
            makeTask(id: "t-normal-4", title: "Meditate for 10 minutes", type: .normal),
            makeTask(id: "t-normal-5", title: "Write in a journal", type: .normal),
        ]
    }

    private static func countingTasks() -> [Task] {
        [
            makeTask(
                id: "t-counting-1",
                title: "Read 100 pages",
                type: .counting,
                action: "Read",
                unit: "pages",
                maxCount: 100
            ),
            makeTask(
                id: "t-counting-2",
                title: "Run 20 miles",
                type: .counting,
                action: "Run",
                unit: "miles",
                maxCount: 20
            ),
            makeTask(
                id: "t-counting-3",
                title: "Drink 8 glasses",
                type: .counting,
                action: "Drink",
                unit: "glasses",
                maxCount: 8
            ),
        ]
    }

    /// Returns compound parent rows + their CompoundChild link rows.
    /// Children themselves (the "leaves") are returned by
    /// `childTasksForCompounds`.
    private static func compoundTasksWithChildren() -> ([Task], [CompoundChild]) {
        let compoundAnd = makeTask(
            id: "t-compound-and",
            title: "Daily wellness",
            type: .compound,
            operatorType: .and
        )
        let compoundOr = makeTask(
            id: "t-compound-or",
            title: "Pick a hobby",
            type: .compound,
            operatorType: .or
        )
        let compounds = [compoundAnd, compoundOr]

        let children: [CompoundChild] = [
            makeCompoundChild(id: "cc-and-1", compoundTaskId: compoundAnd.id, childTaskId: "t-leaf-water", childIndex: 0),
            makeCompoundChild(id: "cc-and-2", compoundTaskId: compoundAnd.id, childTaskId: "t-leaf-stretch", childIndex: 1),
            makeCompoundChild(id: "cc-and-3", compoundTaskId: compoundAnd.id, childTaskId: "t-leaf-vitamins", childIndex: 2),
            makeCompoundChild(id: "cc-or-1", compoundTaskId: compoundOr.id, childTaskId: "t-leaf-paint", childIndex: 0),
            makeCompoundChild(id: "cc-or-2", compoundTaskId: compoundOr.id, childTaskId: "t-leaf-knit", childIndex: 1),
        ]
        return (compounds, children)
    }

    private static func childTasksForCompounds(_ children: [CompoundChild]) -> [Task] {
        let titles: [String: String] = [
            "t-leaf-water":    "Drink water",
            "t-leaf-stretch":  "Stretch 5 min",
            "t-leaf-vitamins": "Take vitamins",
            "t-leaf-paint":    "Paint a small canvas",
            "t-leaf-knit":     "Knit one row",
        ]
        let unique = Set(children.map { $0.childTaskId })
        return unique.sorted().map { id in
            makeTask(id: id, title: titles[id] ?? id, type: .normal)
        }
    }

    /// Composite "everything" library — primitives + compounds + leaves.
    private static func denseTaskSet() -> ([Task], [CompoundChild]) {
        let normals = normalTasks()
        let countings = countingTasks()
        let (compounds, children) = compoundTasksWithChildren()
        let leaves = childTasksForCompounds(children)
        return (normals + countings + compounds + leaves, children)
    }

    private static func groupChildren(_ children: [CompoundChild]) -> [String: [CompoundChild]] {
        var grouped: [String: [CompoundChild]] = [:]
        for c in children {
            grouped[c.compoundTaskId, default: []].append(c)
        }
        for id in grouped.keys {
            grouped[id]?.sort { $0.childIndex < $1.childIndex }
        }
        return grouped
    }

    // MARK: - Compound panel library

    /// Returns a small flat task list for the inline compound builder's
    /// smart autocomplete. Excludes compounds (per spec — no nested compounds
    /// in the inline builder). Used by `RisoCompoundPanelSnapshotTests`.
    static func makeCompoundSnapshotLibrary() -> [Task] {
        [
            makeTask(id: "cs-n1", title: "Meditate 10 min", type: .normal),
            makeTask(id: "cs-n2", title: "Read a chapter", type: .normal),
            makeTask(id: "cs-c1", title: "Run 5 km", type: .counting,
                     action: "Run", unit: "km", maxCount: 5),
            makeTask(id: "cs-c2", title: "Drink 8 glasses", type: .counting,
                     action: "Drink", unit: "glasses", maxCount: 8),
        ]
    }

    /// Sample BoardTasks pinned to a single board so the row "N boards"
    /// usage hint shows non-zero values for the first few tasks.
    private static func sampleBoardTasks(taskIds: [String]) -> [BoardTask] {
        let boardId = "board-fixture-1"
        return taskIds.enumerated().map { idx, taskId in
            makeBoardTask(
                id: "bt-\(taskId)",
                boardId: boardId,
                taskId: taskId,
                row: idx / 5,
                col: idx % 5
            )
        }
    }
}
