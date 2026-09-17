import Foundation
import GRDB

/// Owns the state for one window in the per-window core-board pager.
///
/// Computes the initial window from a seed ISO start string via
/// `computeTimeframeBoundaries`, steps prev/next via
/// `stepCoreBoardWindow`, and loads the matching `isCore` board from
/// the local GRDB database.
///
/// Mirrors the web `useCoreBoardWindow` concept.
@MainActor
final class CoreBoardWindowViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var windowStart: String = ""
    @Published private(set) var windowEnd: String = ""
    /// The window's PLAYABLE core board (status active/completed) or nil.
    /// A draft core board for the window is surfaced via `draftBoard`
    /// instead — drafts are never opened as a playable board.
    @Published private(set) var board: Board?
    /// A DRAFT core board for the window, if one exists. The pager shows a
    /// "Resume draft" prompt for it rather than the playable grid.
    @Published private(set) var draftBoard: Board?
    @Published private(set) var isLoaded: Bool = false
    /// Human-readable window label ("Today", "Week of …", "May 2026", "2026").
    /// Stored, not computed: derived once when the window changes in
    /// `init`/`step`, so `body` reads don't re-parse + allocate a
    /// `DateFormatter` (via `formatTimeframeLabel`) on every render.
    @Published private(set) var windowLabel: String = ""
    /// Current greenlog streak for this timeframe (0 = none). Per-timeframe
    /// (constant across windows); the empty/draft title rows derive both
    /// the chip display + a11y label from it.
    @Published private(set) var streakCount: Int = 0
    /// The user's core boards for this timeframe keyed by `startDate` —
    /// feeds the window chip's position dots, the caption dots, the
    /// picker sheet's tiles, and the incoming swipe card's neighbor
    /// lookup. Refreshed on every `reload()`.
    @Published private(set) var coreBoardsByStart: [String: Board] = [:]
    /// Today's window start (local ISO) for this timeframe — the "gold
    /// ring" dot + the current-window checks. Recomputed on reload.
    @Published private(set) var todayWindowStart: String = ""

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
    /// overwriting state produced by a newer reload.
    private var reloadToken: Int = 0

    /// Injected for tests; defaults to the production singleton.
    private let database: AppDatabase

    // MARK: - Init

    /// Normalises `seedWindowStart` to the canonical window boundaries
    /// for `timeframe` (using `computeTimeframeBoundaries`) so the pager
    /// always displays a valid full window even if the caller passes an
    /// arbitrary mid-window date string.
    init(
        timeframe: Timeframe,
        seedWindowStart: String,
        userId: String,
        weekStartDay: String,
        database: AppDatabase = .shared
    ) {
        self.timeframe = timeframe
        self.userId = userId
        self.weekStartDay = weekStartDay
        self.database = database

        // Normalise the seed to its window's canonical boundaries
        // (anchored via `computeTimeframeBoundaries(referenceDate:)`).
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
    /// `formatTimeframeLabel`. Static so `init` can call it before all
    /// stored properties are initialised.
    private static func makeLabel(timeframe: Timeframe, windowStartISO: String) -> String {
        guard let date = parseISO8601Date(windowStartISO) else { return "" }
        return formatTimeframeLabel(timeframe: timeframe, startDate: date)
    }

    // `isPast` / `isCurrentWindow` were DELETED (2026-09-16): they
    // duplicated `CoreWindowPicker.describe`'s computation, and a future
    // edit to one and not the other would reopen the post-load mutation
    // bug this refactor closed. The descriptor is the single source.

    /// The pager's timeframe (read-only accessor for chrome that only
    /// has the view model).
    var pagerTimeframe: Timeframe { timeframe }

    /// Neighbor window start at `offset` from the displayed window (for
    /// caption labels + the incoming swipe card). Nil for unreachable
    /// timeframes.
    func neighborWindowStart(offset: Int) -> String? {
        guard let window = stepCoreBoardWindow(
            timeframe: timeframe,
            fromStartIso: windowStart,
            step: offset,
            weekStartDay: weekStartDay
        ) else { return nil }
        return wizardLocalISOString(window.start)
    }

    // MARK: - Actions

    /// Load the matching core board for `(userId, timeframe, windowStart)`
    /// from the local DB.
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

        // Today's window start — anchors the chip/caption "gold ring" dot
        // and the current-window checks.
        let todayStart = computeTimeframeBoundaries(
            timeframe: timeframe, referenceDate: now, weekStartDay: weekStartDay
        ).map { wizardLocalISOString($0.start) } ?? ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                // One read for the window's board, all boards (for the
                // per-timeframe greenlog streak — `computeStreak` re-filters
                // to isCore/!isDeleted/timeframe internally), and the
                // timeframe's core boards (chip dots / picker tiles).
                let (result, streak, byStart) = try self.database.read { db -> (Board?, Int, [String: Board]) in
                    let match = try Board
                        .filter(
                            Column("userId") == userId
                            && Column("isDeleted") == false
                            && Column("isCore") == true
                            && Column("timeframe") == timeframeRaw
                            && Column("startDate") == start
                        )
                        .fetchOne(db)?.healingDisplayName()
                    let allBoards = try Board
                        .filter(Column("userId") == userId && Column("isDeleted") == false)
                        .fetchAll(db).healingDisplayNames()
                    let streak = computeStreak(
                        timeframe: timeframe, criterion: .greenlog,
                        boards: allBoards, weekStartDay: weekStartDay, now: now
                    )
                    // Core-board lookup by startDate — derived from the same
                    // fetch (no extra read). Duplicate startDates can't
                    // happen for a healthy core roster; keep the first.
                    var byStart: [String: Board] = [:]
                    for b in allBoards where b.isCore && b.timeframe == timeframe {
                        if byStart[b.startDate] == nil { byStart[b.startDate] = b }
                    }
                    return (match, streak, byStart)
                }
                DispatchQueue.main.async {
                    guard token == self.reloadToken else { return }
                    // Split playable vs draft: a draft core board is surfaced
                    // through `draftBoard` (Resume prompt), never as a playable
                    // board. Active/completed land in `board`.
                    if let b = result, b.status == .draft {
                        self.board = nil
                        self.draftBoard = b
                    } else {
                        self.board = result
                        self.draftBoard = nil
                    }
                    self.streakCount = streak
                    self.coreBoardsByStart = byStart
                    self.todayWindowStart = todayStart
                    self.isLoaded = true
                }
            } catch {
                DispatchQueue.main.async {
                    guard token == self.reloadToken else { return }
                    self.board = nil
                    self.draftBoard = nil
                    self.streakCount = 0
                    self.coreBoardsByStart = [:]
                    self.todayWindowStart = todayStart
                    self.isLoaded = true
                }
            }
        }
    }

    /// Step the current window by `offset` calendar units (+1 = next,
    /// -1 = previous). Calls `stepCoreBoardWindow`, then reloads.
    /// A nil return from the step helper (e.g. `.custom` timeframe) is
    /// a no-op so the view stays on the last valid window.
    func step(_ offset: Int) {
        guard let window = stepCoreBoardWindow(
            timeframe: timeframe,
            fromStartIso: windowStart,
            step: offset,
            weekStartDay: weekStartDay
        ) else { return }
        commitWindow(window)
    }

    /// Jump the pager straight to the window starting at `targetStartIso`
    /// (a picker-tile tap). The target is re-snapped to canonical window
    /// boundaries defensively; no board row is ever created here.
    func jump(toWindowStart targetStartIso: String) {
        guard let seedDate = parseISO8601Date(targetStartIso),
              let window = computeTimeframeBoundaries(
                  timeframe: timeframe,
                  referenceDate: seedDate,
                  weekStartDay: weekStartDay
              ) else { return }
        commitWindow(window)
    }

    /// Land on `window`, rendering its FINAL state in the same frame.
    ///
    /// Owner-reported jank (2026-09-15): dropping to `isLoaded = false`
    /// here put a spinner up after every swipe/jump, and an empty window's
    /// prompt (+ its "Swipe back to…" hint) then mounted LATE when the
    /// async reload resolved — shifting every element below it. But
    /// `coreBoardsByStart` already holds EVERY core board of this
    /// timeframe (it feeds the chip dots, picker tiles, and the mid-swipe
    /// preview card), so the landed window's board/draft/empty state is
    /// known synchronously: seed it, keep `isLoaded` true, and let
    /// `reload()` reconcile in the background (token-guarded — a stale
    /// seed self-corrects without a spinner). The spinner now appears
    /// only on the true first load, before the map exists.
    private func commitWindow(_ window: (start: Date, end: Date)) {
        windowStart = wizardLocalISOString(window.start)
        windowEnd = wizardLocalISOString(window.end)
        windowLabel = Self.makeLabel(timeframe: timeframe, windowStartISO: windowStart)

        if isLoaded {
            let seeded = coreBoardsByStart[windowStart]
            if let b = seeded, b.status == .draft {
                board = nil
                draftBoard = b
            } else {
                board = seeded
                draftBoard = nil
            }
        } else {
            board = nil
            draftBoard = nil
        }
        reload()
    }
}
