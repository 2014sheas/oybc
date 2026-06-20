import Foundation
import GRDB

/// Owns the state for one window in the per-window core-board pager.
///
/// Computes the initial window from a seed ISO start string via
/// `computeTimeframeBoundaries`, steps prev/next via
/// `stepCoreBoardWindow`, and loads the matching `isCore` board from
/// the local GRDB database using the same predicate
/// `CoreBoardBrowserViewModel` uses.
///
/// Mirrors the web `useCoreBoardWindow` concept.
@MainActor
final class CoreBoardWindowViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var windowStart: String = ""
    @Published private(set) var windowEnd: String = ""
    @Published private(set) var board: Board?
    @Published private(set) var isLoaded: Bool = false
    /// Human-readable window label ("Today", "Week of …", "May 2026", "2026").
    /// Stored, not computed: derived once when the window changes in
    /// `init`/`step`, so `body` reads don't re-parse + allocate a
    /// `DateFormatter` (via `formatTimeframeLabel`) on every render.
    @Published private(set) var windowLabel: String = ""
    /// Current greenlog streak for this timeframe (0 = none). Per-timeframe
    /// (constant across windows); the bar derives both its display + a11y label.
    @Published private(set) var streakCount: Int = 0

    // MARK: - Config (immutable after init)

    private let timeframe: Timeframe
    private let userId: String
    /// `"monday"` or `"sunday"` — the raw value of `WeekStartDay`, stored
    /// as a String to match the parameter type that
    /// `computeTimeframeBoundaries` and `stepCoreBoardWindow` accept.
    private let weekStartDay: String

    // MARK: - Stale-result guard

    /// Monotonically-increasing token incremented on every `reload` call.
    /// Each in-flight background fetch captures the token at dispatch and
    /// only applies its result if `reloadToken` still matches when it
    /// completes on the main queue. Prevents a slower earlier fetch from
    /// overwriting state produced by a newer reload — mirrors the
    /// identical pattern in `CoreBoardBrowserViewModel`.
    private var reloadToken: Int = 0

    // MARK: - Init

    /// Normalises `seedWindowStart` to the canonical window boundaries
    /// for `timeframe` (using `computeTimeframeBoundaries`) so the pager
    /// always displays a valid full window even if the caller passes an
    /// arbitrary mid-window date string.
    init(
        timeframe: Timeframe,
        seedWindowStart: String,
        userId: String,
        weekStartDay: String
    ) {
        self.timeframe = timeframe
        self.userId = userId
        self.weekStartDay = weekStartDay

        // Normalise the seed to its window's canonical boundaries.
        // Mirror of how `CoreBoardBrowserViewModel.reload` anchors to
        // `computeTimeframeBoundaries(referenceDate: now)`.
        if let seedDate = parseISO8601Date(seedWindowStart),
           let window = computeTimeframeBoundaries(
               timeframe: timeframe,
               referenceDate: seedDate,
               weekStartDay: weekStartDay
           ) {
            self.windowStart = wizardLocalISOString(window.start)
            self.windowEnd = wizardLocalISOString(window.end)
        } else {
            // Fallback (unreachable in practice — the seed always comes from
            // `wizardLocalISOString`): keep the raw seed and treat the window as
            // instantaneous (start == end), so `isPast` degrades to "is the seed
            // before now" and `reload` surfaces an empty state.
            self.windowStart = seedWindowStart
            self.windowEnd = seedWindowStart
        }
        self.windowLabel = Self.makeLabel(timeframe: timeframe, windowStartISO: self.windowStart)
    }

    // MARK: - Derived

    /// Builds the window label from an ISO start string, via
    /// `formatTimeframeLabel` — the same helper
    /// `CoreBoardBrowserViewModel.rebuildCells` uses for
    /// `CoreBoardWindowCell.windowLabel`. Static so `init` can call it
    /// before all stored properties are initialised.
    private static func makeLabel(timeframe: Timeframe, windowStartISO: String) -> String {
        guard let date = parseISO8601Date(windowStartISO) else { return "" }
        return formatTimeframeLabel(timeframe: timeframe, startDate: date)
    }

    /// `true` when the window's end is strictly before now (past window).
    var isPast: Bool {
        guard let endDate = parseISO8601Date(windowEnd) else { return false }
        return endDate < Date()
    }

    // MARK: - Actions

    /// Load the matching core board for `(userId, timeframe, windowStart)`
    /// from the local DB. Uses the same column filter that
    /// `CoreBoardBrowserViewModel.fetchCoreBoards` uses so results are
    /// consistent between the browser and the pager.
    func reload() {
        let userId = self.userId
        let timeframe = self.timeframe
        let timeframeRaw = timeframe.rawValue
        let start = windowStart
        let weekStartDay = self.weekStartDay
        // Capture `now` once before the read so the streak computation uses a
        // stable instant (parity with CoreBoardSlotsViewModel.reload).
        let now = Date()

        reloadToken += 1
        let token = reloadToken

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                // One read for both the window's board and all boards (for the
                // per-timeframe greenlog streak). `computeStreak` re-filters to
                // isCore/!isDeleted/timeframe internally.
                let (result, streak) = try AppDatabase.shared.read { db -> (Board?, Int) in
                    let match = try Board
                        .filter(
                            Column("userId") == userId
                            && Column("isDeleted") == false
                            && Column("isCore") == true
                            && Column("timeframe") == timeframeRaw
                            && Column("startDate") == start
                        )
                        .fetchOne(db)
                    let allBoards = try Board
                        .filter(Column("userId") == userId && Column("isDeleted") == false)
                        .fetchAll(db)
                    let streak = computeStreak(
                        timeframe: timeframe, criterion: .greenlog,
                        boards: allBoards, weekStartDay: weekStartDay, now: now
                    )
                    return (match, streak)
                }
                DispatchQueue.main.async {
                    guard token == self.reloadToken else { return }
                    self.board = result
                    self.streakCount = streak
                    self.isLoaded = true
                }
            } catch {
                DispatchQueue.main.async {
                    guard token == self.reloadToken else { return }
                    self.board = nil
                    self.streakCount = 0
                    self.isLoaded = true
                }
            }
        }
    }

    /// Step the current window by `offset` calendar units (+1 = next,
    /// -1 = previous). Calls `stepCoreBoardWindow` — the same helper
    /// `CoreBoardBrowserViewModel.rebuildCells` uses — then reloads.
    /// A nil return from the step helper (e.g. `.custom` timeframe) is
    /// a no-op so the view stays on the last valid window.
    func step(_ offset: Int) {
        guard let window = stepCoreBoardWindow(
            timeframe: timeframe,
            fromStartIso: windowStart,
            step: offset,
            weekStartDay: weekStartDay
        ) else { return }

        isLoaded = false
        board = nil
        windowStart = wizardLocalISOString(window.start)
        windowEnd = wizardLocalISOString(window.end)
        windowLabel = Self.makeLabel(timeframe: timeframe, windowStartISO: windowStart)
        reload()
    }
}
