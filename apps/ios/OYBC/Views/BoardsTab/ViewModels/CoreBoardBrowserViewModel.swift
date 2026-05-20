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

    init(initialRadius: Int = 10, pageSize: Int = 10) {
        self.initialRadius = initialRadius
        self.pageSize = pageSize
    }

    // MARK: - Public state

    /// Loaded cells in chronological order.
    var cells: [CoreBoardWindowCell] = []
    /// Index of the cell representing the current window. -1 while
    /// loading.
    var currentIndex: Int = -1
    /// Most recent reload error, surfaced as a caption.
    var loadError: String?

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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let boards = try self.fetchCoreBoards(userId: userId, timeframe: timeframe)
                DispatchQueue.main.async {
                    self.boardsByStart = Dictionary(
                        uniqueKeysWithValues: boards.map { ($0.startDate, $0) }
                    )
                    self.rebuildCells()
                    self.loadError = nil
                }
            } catch {
                let message = "Failed to load core boards: \(error.localizedDescription)"
                DispatchQueue.main.async { self.loadError = message }
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
                windowLabel: playgroundTimeframeLabel(timeframe: timeframe, startDate: window.start),
                board: boardsByStart[startIso],
                isCurrentWindow: nowRef >= window.start && nowRef <= window.end,
                isPastWindow: nowRef > window.end
            )
            out.append(cell)
        }
        cells = out
        currentIndex = out.firstIndex(where: { $0.isCurrentWindow }) ?? -1
    }

    // MARK: - Data loader

    private func fetchCoreBoards(userId: String, timeframe: Timeframe) throws -> [Board] {
        try AppDatabase.shared.read { db in
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

// MARK: - Window stepping helper (iOS twin of shared `stepWindow`)

/// Step from `fromStartIso` by `step` calendar units of `timeframe`,
/// returning the resulting window's start + end Dates. Mirrors the
/// shared `stepWindow` algorithm (`packages/shared/src/algorithms/calendarBoundaries.ts`).
///
/// MONTHLY / YEARLY use `Calendar.date(byAdding:)` so JS's month-overflow
/// trick translates cleanly: day=1 guarantees we never construct an
/// invalid date (Feb 31 ⇒ Mar 3 in JS, but we don't need that — we
/// just need to land "somewhere in the next month" so
/// `computeTimeframeBoundaries` then snaps to the full window).
func stepCoreBoardWindow(
    timeframe: Timeframe,
    fromStartIso: String,
    step: Int,
    weekStartDay: String
) -> (start: Date, end: Date)? {
    guard let fromDate = parseISO8601Date(fromStartIso) else { return nil }
    var components = Calendar.current.dateComponents(
        [.year, .month, .day],
        from: fromDate
    )
    components.hour = 0
    components.minute = 0
    components.second = 0
    let cal = Calendar.current

    let referenceDate: Date?
    switch timeframe {
    case .daily:
        referenceDate = cal.date(byAdding: .day, value: step, to: fromDate)
    case .weekly:
        referenceDate = cal.date(byAdding: .day, value: 7 * step, to: fromDate)
    case .monthly:
        // Day=1 of the target month, mirroring web's `new Date(y, m + step, 1)`.
        components.day = 1
        guard let firstOfCurrent = cal.date(from: components) else { return nil }
        referenceDate = cal.date(byAdding: .month, value: step, to: firstOfCurrent)
    case .yearly:
        components.month = 1
        components.day = 1
        guard let firstOfYear = cal.date(from: components) else { return nil }
        referenceDate = cal.date(byAdding: .year, value: step, to: firstOfYear)
    case .custom:
        return nil
    }
    guard let ref = referenceDate else { return nil }
    return computeTimeframeBoundaries(
        timeframe: timeframe,
        referenceDate: ref,
        weekStartDay: weekStartDay
    )
}
