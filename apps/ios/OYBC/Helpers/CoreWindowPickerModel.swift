import Foundation

// MARK: - Core-window picker + chip model (pure)
//
// Pure derivation helpers for the core-board surface rework: the window
// chip's position dots, and the picker sheet's calendar-aligned tile
// pages. No database access — callers pass a `boardsByStart` lookup
// (the user's `isCore` boards for one timeframe, keyed by
// `Board.startDate`).
//
// Mirrors web `apps/web/src/pages/core-board-browser/corePickerTiles.ts`
// — change both together (parity rule 6).

enum CoreWindowPicker {

    // MARK: - Window descriptor (single source per window)

    /// Everything the pager needs to render ONE window, derived purely
    /// from that window's own start date.
    ///
    /// Owner-reported (2026-09-16): the CTA flipped "Set up" → "Backfill"
    /// and the chip suffix changed AFTER a swipe landed. Root cause was
    /// never load timing — the pager described a window through two
    /// different code paths depending on whether it was currently
    /// displayed (`isDisplayed ? viewModel.isPast : false`, etc.), and
    /// the paths disagreed. The instant a card's role flipped, its copy
    /// changed under the user.
    ///
    /// The rule this type enforces: **a window's description is a
    /// function of WHICH window it is, never of whether it happens to be
    /// on screen.** Build one of these per card — displayed or incoming,
    /// identical inputs, identical output — and there is no second path
    /// left to disagree.
    struct WindowDescriptor {
        let windowStart: String
        let label: String
        /// The window's end is strictly before `now`.
        let isPast: Bool
        /// This IS today's window.
        let isCurrent: Bool
        /// The window's core board (playable or draft), if any.
        let board: Board?
        /// Chip label suffix (" · closed" / " · past" / " · next" / "").
        let chipSuffix: String

        /// Full chip label — window label + suffix.
        var chipLabel: String { label + chipSuffix }
        /// A draft board occupies this window (never playable).
        var isDraft: Bool { board?.status == .draft }
        /// A playable (non-draft) board occupies this window.
        var playableBoard: Board? {
            guard let b = board, b.status != .draft else { return nil }
            return b
        }
    }

    /// Build the descriptor for `windowStart`. `now` is passed in (never
    /// read from the clock here) so every card in one render pass agrees
    /// and a long-lived screen can't flip `isPast` mid-session.
    static func describe(
        timeframe: Timeframe,
        windowStart: String,
        todayWindowStart: String,
        boardsByStart: [String: Board],
        weekStartDay: String,
        now: Date
    ) -> WindowDescriptor {
        let label = parseISO8601Date(windowStart).map {
            formatTimeframeLabel(timeframe: timeframe, startDate: $0)
        } ?? ""

        // isPast = this window's END is before now. Derived from the
        // window itself, so it's identical for a card whether it is the
        // preview or the landed card.
        let isPast: Bool = {
            guard let seed = parseISO8601Date(windowStart),
                  let window = computeTimeframeBoundaries(
                      timeframe: timeframe, referenceDate: seed, weekStartDay: weekStartDay
                  ) else { return false }
            return window.end < now
        }()

        let isCurrent = !todayWindowStart.isEmpty && windowStart == todayWindowStart
        let board = boardsByStart[windowStart]

        return WindowDescriptor(
            windowStart: windowStart,
            label: label,
            isPast: isPast,
            isCurrent: isCurrent,
            board: board,
            chipSuffix: chipLabelSuffix(
                board: board, isCurrentWindow: isCurrent, isPastWindow: isPast
            )
        )
    }

    // MARK: - Neighborhood (chip + caption dots)

    /// One position dot in the window chip / caption (offsets −2…+2).
    struct NeighborhoodDot: Identifiable, Equatable {
        /// Window offset relative to the displayed window (−2…+2).
        let offset: Int
        /// Local-ISO window start.
        let windowStart: String
        /// A core board exists for this window.
        let hasBoard: Bool
        /// This dot is the displayed window (offset 0).
        let isDisplayed: Bool
        /// This dot is today's (current) window.
        let isToday: Bool

        var id: Int { offset }
    }

    /// Build the ±2-window neighborhood around the displayed window, for
    /// the chip's position dots and the under-grid caption dots.
    static func buildNeighborhood(
        timeframe: Timeframe,
        windowStart: String,
        todayWindowStart: String,
        boardsByStart: [String: Board],
        weekStartDay: String
    ) -> [NeighborhoodDot] {
        var dots: [NeighborhoodDot] = []
        for offset in -2...2 {
            let start: String
            if offset == 0 {
                start = windowStart
            } else if let window = stepCoreBoardWindow(
                timeframe: timeframe, fromStartIso: windowStart,
                step: offset, weekStartDay: weekStartDay
            ) {
                start = wizardLocalISOString(window.start)
            } else {
                continue
            }
            dots.append(NeighborhoodDot(
                offset: offset,
                windowStart: start,
                hasBoard: boardsByStart[start] != nil,
                isDisplayed: offset == 0,
                isToday: start == todayWindowStart
            ))
        }
        return dots
    }

    // MARK: - Chip label suffix

    /// Suffix appended to the chip's window label: "· closed" for a
    /// sealed board's window, "· next"/"· past" for an empty non-current
    /// window, nothing otherwise.
    static func chipLabelSuffix(
        board: Board?,
        isCurrentWindow: Bool,
        isPastWindow: Bool
    ) -> String {
        if board?.sealedAt != nil { return " · closed" }
        if board == nil && !isCurrentWindow { return isPastWindow ? " · past" : " · next" }
        return ""
    }

    // MARK: - Tiles (six-state table)

    /// Visual state of one picker tile — the six-state table from the
    /// design spec, plus two derived extras the table implies but does
    /// not draw: `inProgress` (a live unsealed board in a non-current
    /// window) and `draft` (a draft board's window).
    enum TileState: Equatable {
        case closed        // past, sealed board
        case done          // completed (greenlog) board
        case pastEmpty     // past, no board
        case current       // today's window (gold)
        case nextEmpty     // the +1 window, empty ("set up")
        case futureEmpty   // further future, empty (dim)
        case inProgress    // live board in a non-current window
        case draft         // draft board
    }

    /// One tile in the picker grid.
    struct Tile: Identifiable, Equatable {
        let windowStart: String
        let windowEnd: String
        /// Short in-grid label (day number / "Sep 14 – 20" / "Jan" / "2026").
        let label: String
        let state: TileState
        /// Board progress for current/inProgress tiles ("4 of 9").
        let progressDone: Int?
        let progressTotal: Int?
        let isCurrent: Bool

        var id: String { windowStart }
    }

    /// One picker page: a calendar period of tiles.
    struct Page: Equatable {
        /// Page heading chip ("2026", "Q3 2026", "September 2026", "2020 – 2029").
        let title: String
        /// Footer labels for the previous/next page.
        let prevTitle: String
        let nextTitle: String
        let tiles: [Tile]
        /// DAILY only: leading blank cells before day 1 in the 7-col grid.
        let leadingBlanks: Int
    }

    /// Map one window (+ board lookup) to its tile state.
    static func tileState(
        board: Board?,
        isCurrent: Bool,
        isPast: Bool,
        isNext: Bool
    ) -> TileState {
        if let board {
            if board.sealedAt != nil { return .closed }
            if board.status == .completed { return .done }
            if board.status == .draft { return .draft }
            return isCurrent ? .current : .inProgress
        }
        if isCurrent { return .current }
        if isPast { return .pastEmpty }
        if isNext { return .nextEmpty }
        return .futureEmpty
    }

    // MARK: - Page periods

    /// Start of the calendar period (page) containing `date`:
    /// DAILY → month, WEEKLY → quarter, MONTHLY → year, YEARLY → decade.
    static func pageStart(timeframe: Timeframe, containing date: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month], from: date)
        switch timeframe {
        case .daily:
            comps.day = 1
        case .weekly:
            comps.month = ((comps.month! - 1) / 3) * 3 + 1
            comps.day = 1
        case .monthly:
            comps.month = 1
            comps.day = 1
        case .yearly:
            comps.year = (comps.year! / 10) * 10
            comps.month = 1
            comps.day = 1
        case .custom, .indefinite:
            comps.month = 1
            comps.day = 1
        }
        return cal.date(from: comps) ?? date
    }

    /// Step a page anchor by ±1 period.
    static func stepPage(timeframe: Timeframe, pageStart: Date, step: Int) -> Date {
        let cal = Calendar.current
        switch timeframe {
        case .daily:
            return cal.date(byAdding: .month, value: step, to: pageStart) ?? pageStart
        case .weekly:
            return cal.date(byAdding: .month, value: 3 * step, to: pageStart) ?? pageStart
        case .monthly:
            return cal.date(byAdding: .year, value: step, to: pageStart) ?? pageStart
        case .yearly:
            return cal.date(byAdding: .year, value: 10 * step, to: pageStart) ?? pageStart
        case .custom, .indefinite:
            return pageStart
        }
    }

    /// Page heading for the page starting at `pageStart`.
    static func pageTitle(timeframe: Timeframe, pageStart: Date) -> String {
        let cal = Calendar.current
        let year = cal.component(.year, from: pageStart)
        let month = cal.component(.month, from: pageStart)
        switch timeframe {
        case .daily:
            return "\(monthName(month)) \(year)"
        case .weekly:
            return "Q\((month - 1) / 3 + 1) \(year)"
        case .monthly:
            return "\(year)"
        case .yearly:
            return "\(year) – \(year + 9)"
        case .custom, .indefinite:
            return ""
        }
    }

    // MARK: - Labels

    /// Short tile label for a window inside a picker page.
    static func tileLabel(timeframe: Timeframe, windowStart: String) -> String {
        guard let d = parseISO8601Date(windowStart) else { return "" }
        let cal = Calendar.current
        switch timeframe {
        case .daily:
            return "\(cal.component(.day, from: d))"
        case .weekly:
            let end = cal.date(byAdding: .day, value: 6, to: d) ?? d
            let sm = monthAbbrev(cal.component(.month, from: d))
            let em = monthAbbrev(cal.component(.month, from: end))
            let sd = cal.component(.day, from: d)
            let ed = cal.component(.day, from: end)
            return sm == em ? "\(sm) \(sd) – \(ed)" : "\(sm) \(sd) – \(em) \(ed)"
        case .monthly:
            return monthAbbrev(cal.component(.month, from: d))
        case .yearly:
            return "\(cal.component(.year, from: d))"
        case .custom, .indefinite:
            return ""
        }
    }

    /// Short label for the position caption's side taps ("‹ August" /
    /// "October ›"): month name for MONTHLY, "Sep 14" for DAILY,
    /// "Sep 14 – 20" for WEEKLY, the year for YEARLY.
    static func captionSideLabel(timeframe: Timeframe, windowStart: String) -> String {
        guard let d = parseISO8601Date(windowStart) else { return "" }
        let cal = Calendar.current
        switch timeframe {
        case .daily:
            return "\(monthAbbrev(cal.component(.month, from: d))) \(cal.component(.day, from: d))"
        case .weekly:
            return tileLabel(timeframe: .weekly, windowStart: windowStart)
        case .monthly:
            return monthName(cal.component(.month, from: d))
        case .yearly:
            return "\(cal.component(.year, from: d))"
        case .custom, .indefinite:
            return ""
        }
    }

    /// Kicker + title copy per timeframe ("Monthly boards" / "Jump to a month").
    static func pickerCopy(timeframe: Timeframe) -> (kicker: String, title: String) {
        switch timeframe {
        case .daily:   return ("Daily boards", "Jump to a day")
        case .weekly:  return ("Weekly boards", "Jump to a week")
        case .monthly: return ("Monthly boards", "Jump to a month")
        case .yearly:  return ("Yearly boards", "Jump to a year")
        case .custom, .indefinite: return ("Core boards", "Jump to a window")
        }
    }

    /// "Today · September"-style footer label.
    static func todayLabel(timeframe: Timeframe, now: Date) -> String {
        let cal = Calendar.current
        switch timeframe {
        case .daily:
            return "Today · \(monthAbbrev(cal.component(.month, from: now))) \(cal.component(.day, from: now))"
        case .weekly:
            return "Today · this week"
        case .monthly:
            return "Today · \(monthName(cal.component(.month, from: now)))"
        case .yearly:
            return "Today · \(cal.component(.year, from: now))"
        case .custom, .indefinite:
            return "Today"
        }
    }

    // MARK: - Page building

    /// Build one picker page of tiles for the calendar period containing
    /// `pageStart`.
    static func buildPage(
        timeframe: Timeframe,
        pageStart: Date,
        boardsByStart: [String: Board],
        now: Date,
        weekStartDay: String
    ) -> Page {
        let pageEnd = stepPage(timeframe: timeframe, pageStart: pageStart, step: 1)
        let pageStartISO = wizardLocalISOString(pageStart)
        let pageEndISO = wizardLocalISOString(pageEnd)
        let nowISO = wizardLocalISOString(now)

        let todayStart = computeTimeframeBoundaries(
            timeframe: timeframe, referenceDate: now, weekStartDay: weekStartDay
        ).map { wizardLocalISOString($0.start) } ?? ""
        let nextStart = stepCoreBoardWindow(
            timeframe: timeframe, fromStartIso: todayStart, step: 1, weekStartDay: weekStartDay
        ).map { wizardLocalISOString($0.start) } ?? ""

        var tiles: [Tile] = []
        // First window whose START falls inside the page period.
        var window = computeTimeframeBoundaries(
            timeframe: timeframe, referenceDate: pageStart, weekStartDay: weekStartDay
        )
        while let w = window, wizardLocalISOString(w.start) < pageStartISO {
            window = stepCoreBoardWindow(
                timeframe: timeframe, fromStartIso: wizardLocalISOString(w.start),
                step: 1, weekStartDay: weekStartDay
            )
        }
        while let w = window {
            let startISO = wizardLocalISOString(w.start)
            guard startISO < pageEndISO else { break }
            let endISO = wizardLocalISOString(w.end)
            let board = boardsByStart[startISO]
            let isCurrent = startISO == todayStart
            let isPast = endISO < nowISO
            let state = tileState(
                board: board, isCurrent: isCurrent, isPast: isPast, isNext: startISO == nextStart
            )
            let showsProgress = board != nil && (state == .current || state == .inProgress)
            tiles.append(Tile(
                windowStart: startISO,
                windowEnd: endISO,
                label: tileLabel(timeframe: timeframe, windowStart: startISO),
                state: state,
                progressDone: showsProgress ? board?.completedTasks : nil,
                progressTotal: showsProgress ? board?.totalTasks : nil,
                isCurrent: isCurrent
            ))
            window = stepCoreBoardWindow(
                timeframe: timeframe, fromStartIso: startISO, step: 1, weekStartDay: weekStartDay
            )
        }

        // DAILY: leading blanks so day 1 lands on its weekday column.
        var leadingBlanks = 0
        if timeframe == .daily {
            let weekday = Calendar.current.component(.weekday, from: pageStart) // 1 = Sunday
            leadingBlanks = weekStartDay == "monday" ? (weekday + 5) % 7 : weekday - 1
        }

        return Page(
            title: pageTitle(timeframe: timeframe, pageStart: pageStart),
            prevTitle: pageTitle(
                timeframe: timeframe,
                pageStart: stepPage(timeframe: timeframe, pageStart: pageStart, step: -1)
            ),
            nextTitle: pageTitle(
                timeframe: timeframe,
                pageStart: stepPage(timeframe: timeframe, pageStart: pageStart, step: 1)
            ),
            tiles: tiles,
            leadingBlanks: leadingBlanks
        )
    }

    // MARK: - Month names

    private static let monthAbbrevs = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    private static func monthAbbrev(_ month: Int) -> String {
        guard (1...12).contains(month) else { return "" }
        return monthAbbrevs[month - 1]
    }
    private static func monthName(_ month: Int) -> String {
        guard (1...12).contains(month) else { return "" }
        return monthNames[month - 1]
    }
}
