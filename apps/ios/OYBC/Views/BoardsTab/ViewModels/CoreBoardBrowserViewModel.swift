import Foundation
import GRDB
import Observation

/// One row in the per-timeframe browser. Mirrors the web shape
/// (`apps/web/src/pages/core-board-browser/useCoreBoardBrowser.ts`)
/// so future cross-platform extractions can collapse the two.
struct CoreBoardWindowCell: Identifiable {
    /// Stable identifier (`windowStart` is unique per timeframe per user).
    var id: String { windowStart }
    /// Local-ISO start (matches `Board.startDate` for string-equal lookup).
    let windowStart: String
    /// Local-ISO end.
    let windowEnd: String
    /// Human-readable label, e.g. "Today", "Week of May 18 – 24, 2026".
    let windowLabel: String
    /// Matching `isCore=true` board for this window, if any.
    let board: Board?
    /// `now` falls within `[windowStart, windowEnd]`.
    let isCurrentWindow: Bool
    /// `windowEnd < now`.
    let isPastWindow: Bool
}

/// Owns the per-timeframe core-board browser state: the window-cell
/// list, the user's `isCore` board lookup (indexed by `startDate`),
/// and bidirectional pagination triggered by sentinel `.onAppear`
/// from the browser view.
///
/// Mirrors the web `useCoreBoardBrowser` hook
/// (`apps/web/src/pages/core-board-browser/useCoreBoardBrowser.ts`).
@Observable
final class CoreBoardBrowserViewModel {

    // MARK: - Config

    private let initialRadius: Int
    private let pageSize: Int

    /// Injected for tests; defaults to the production singleton.
    @ObservationIgnored private let database: AppDatabase

    init(initialRadius: Int = 10, pageSize: Int = 10, database: AppDatabase = .shared) {
        self.initialRadius = initialRadius
        self.pageSize = pageSize
        self.database = database
    }

    // MARK: - Public state

    /// Loaded cells in chronological order.
    var cells: [CoreBoardWindowCell] = []
    /// Index of the cell representing the current window. -1 while
    /// loading.
    var currentIndex: Int = -1
    /// Most recent reload error, surfaced as a caption.
    var loadError: String?

    /// TRUE mini-preview cells for every board currently in `boardsByStart`
    /// (bugfix/board-preview-real-cells perf follow-up), keyed by board id.
    /// Batch-built in `rebuildCells()` from `workspaceData`/`allBoardTasksCache`
    /// — fetched ONCE per `reload()`, not per row and not per pagination
    /// fetch (`loadEarlier`/`loadLater` never hit the DB; `fetchCoreBoards`
    /// already loads every core board for this user+timeframe up front, so
    /// pagination only changes which window OFFSETS are exposed, never which
    /// boards exist). `CoreBoardBrowserView` passes this straight through to
    /// every `CoreBoardWindowCellView` → `RisoBoardCard(previewCells:)`
    /// instead of letting the card self-load.
    var previewCellsByBoardId: [String: BoardPreviewCellsResult] = [:]

    // MARK: - Private state

    /// The current-window startDate string for the active timeframe;
    /// the pagination range is measured as offsets from this anchor.
    private var anchorWindowStart: String?
    /// Active timeframe (set by the most-recent `reload`).
    private var activeTimeframe: Timeframe?
    /// Active week-start-day raw string (`"monday"` / `"sunday"`) —
    /// matches the parameter type the rest of the wizard threads
    /// through `computeTimeframeBoundaries`.
    private var activeWeekStartDay: String?
    /// Window offsets currently loaded, inclusive at both ends.
    private var earliestOffset: Int = 0
    private var latestOffset: Int = 0
    /// `nowRef` — snapshot taken on first reload so the "current"
    /// flag doesn't tick at midnight mid-session.
    private var nowRef: Date = Date()
    /// Board lookup by startDate. Populated once per reload from a
    /// GRDB read; live-update isn't needed because the browser
    /// reloads on `.onAppear` (return-from-wizard).
    private var boardsByStart: [String: Board] = [:]
    /// Workspace-scoped preview-cell inputs (bugfix/board-preview-real-cells
    /// perf follow-up), fetched once per `reload()` alongside `boardsByStart`.
    private var workspaceData: BoardPreviewCells.WorkspaceData = .empty
    /// Workspace-wide BoardTask rows, fetched once per `reload()`. Each
    /// board's `BoardPreviewCells.build` filters this to its own id.
    private var allBoardTasksCache: [BoardTask] = []

    /// Monotonically-increasing token incremented on every `reload`
    /// call. Each in-flight background fetch captures the token at
    /// dispatch and only applies its result if `reloadToken` still
    /// matches when it completes on the main queue. Prevents a slower
    /// earlier fetch from stomping the state of a newer reload —
    /// happens in practice when the user tab-flips Boards-tab ↔
    /// Browser quickly, or navigates Daily → Weekly mid-fetch.
    private var reloadToken: Int = 0

    // MARK: - Public actions

    /// Initial load — ±`initialRadius` windows around the current
    /// window. Call from the browser view's `.onAppear`.
    func reload(timeframe: Timeframe, weekStartDay: String, userId: String) {
        self.activeTimeframe = timeframe
        self.activeWeekStartDay = weekStartDay
        let now = Date()
        self.nowRef = now
        guard let anchor = computeTimeframeBoundaries(
            timeframe: timeframe,
            referenceDate: now,
            weekStartDay: weekStartDay
        ) else {
            loadError = "Could not compute the current window."
            return
        }
        let anchorStart = wizardLocalISOString(anchor.start)
        self.anchorWindowStart = anchorStart
        self.earliestOffset = -initialRadius
        self.latestOffset = initialRadius

        // Bump the token + capture the new value so this fetch can
        // verify it's still the latest when it completes. Any in-flight
        // earlier fetch will see a mismatch and discard its result
        // instead of overwriting newer state.
        reloadToken += 1
        let token = reloadToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let boards = try self.fetchCoreBoards(userId: userId, timeframe: timeframe)
                // Batch preview-cell inputs (bugfix/board-preview-real-cells
                // perf follow-up) — fetched ONCE here, reused by every
                // board's `build(...)` call in `rebuildCells()`, instead of
                // each `RisoBoardCard` row self-loading.
                let allBoardTasks = (try? self.database.fetchAllBoardTasks()) ?? []
                let workspace = BoardPreviewCells.fetchWorkspaceData(userId: userId, database: self.database)
                DispatchQueue.main.async {
                    guard token == self.reloadToken else { return }
                    self.boardsByStart = Dictionary(
                        uniqueKeysWithValues: boards.map { ($0.startDate, $0) }
                    )
                    self.allBoardTasksCache = allBoardTasks
                    self.workspaceData = workspace
                    self.rebuildCells()
                    self.loadError = nil
                }
            } catch {
                let message = "Failed to load core boards: \(error.localizedDescription)"
                DispatchQueue.main.async {
                    guard token == self.reloadToken else { return }
                    self.loadError = message
                }
            }
        }
    }

    /// Prepend `pageSize` more past windows. No-op if no anchor is set.
    func loadEarlier() {
        guard anchorWindowStart != nil else { return }
        earliestOffset -= pageSize
        rebuildCells()
    }

    /// Append `pageSize` more future windows. No-op if no anchor is set.
    func loadLater() {
        guard anchorWindowStart != nil else { return }
        latestOffset += pageSize
        rebuildCells()
    }

    // MARK: - Cell rebuild

    /// Materialise `cells` from the offset range + board lookup. Pure
    /// over the current state — called on initial load, pagination,
    /// and post-board-create reload.
    private func rebuildCells() {
        guard let timeframe = activeTimeframe,
              let weekStartDay = activeWeekStartDay,
              let anchor = anchorWindowStart else {
            cells = []
            currentIndex = -1
            previewCellsByBoardId = [:]
            return
        }
        var out: [CoreBoardWindowCell] = []
        out.reserveCapacity(latestOffset - earliestOffset + 1)
        for offset in earliestOffset...latestOffset {
            guard let window = stepCoreBoardWindow(
                timeframe: timeframe,
                fromStartIso: anchor,
                step: offset,
                weekStartDay: weekStartDay
            ) else { continue }
            let startIso = wizardLocalISOString(window.start)
            let endIso = wizardLocalISOString(window.end)
            let cell = CoreBoardWindowCell(
                windowStart: startIso,
                windowEnd: endIso,
                windowLabel: formatTimeframeLabel(timeframe: timeframe, startDate: window.start),
                board: boardsByStart[startIso],
                isCurrentWindow: nowRef >= window.start && nowRef <= window.end,
                isPastWindow: nowRef > window.end
            )
            out.append(cell)
        }
        cells = out
        currentIndex = out.firstIndex(where: { $0.isCurrentWindow }) ?? -1

        // Batch preview cells (bugfix/board-preview-real-cells perf
        // follow-up) — pure recompute from already-fetched workspace data,
        // re-run on every `rebuildCells()` call (initial load AND
        // pagination) so a board entering the visible range via
        // `loadEarlier`/`loadLater` always has cells ready. No new DB read:
        // `boardsByStart` was fully populated up front in `reload()`.
        previewCellsByBoardId = BoardPreviewCells.buildMany(
            boards: Array(boardsByStart.values),
            boardTasks: allBoardTasksCache,
            workspace: workspaceData
        )
    }

    // MARK: - Data loader

    private func fetchCoreBoards(userId: String, timeframe: Timeframe) throws -> [Board] {
        try database.read { db in
            try Board
                .filter(
                    Column("userId") == userId
                    && Column("isDeleted") == false
                    && Column("isCore") == true
                    && Column("timeframe") == timeframe.rawValue
                )
                .fetchAll(db)
        }
    }
}

