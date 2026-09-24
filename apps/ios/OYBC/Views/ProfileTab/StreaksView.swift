import SwiftUI

// MARK: - StreaksView (container)

/// Profile sub-page — "Streaks & history" (handoff §5e).
///
/// Thin env-bound container: fetches boards once on appear, derives all
/// displayed values (current streak, longest, GREENLOG count, week strip,
/// history list) from the local DB via `computeStreak` / `computeLongestStreak`
/// from `Streaks.swift`, then hands plain-value props to `StreaksContent`.
///
/// **Derive-not-persist**: no new table, schema, or sync field is introduced.
/// All values are computed from the existing `boards` table. Week strip is
/// derived from `completedAt` on daily core boards (see `StreaksContent`).
///
/// **History scope**: ALL completed non-deleted boards (not core-only) so the
/// list matches the prototype's generic "every cleared board lands here" copy.
struct StreaksView: View {

    @EnvironmentObject var authService: AuthService

    // MARK: - Private state

    @State private var currentStreak: Int = 0
    @State private var longestStreak: Int = 0
    @State private var greenlogCount: Int = 0
    @State private var weekDots: [WeekDot] = []
    @State private var historyRows: [StreakHistoryRow] = []

    // MARK: - Body

    var body: some View {
        StreaksContent(
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            greenlogCount: greenlogCount,
            weekDots: weekDots,
            historyRows: historyRows
        )
        .navigationBarHidden(true)
        .onAppear { loadData() }
    }

    // MARK: - Data loading

    private func loadData() {
        guard let userId = authService.currentUser?.id else { return }
        let weekStartDay = authService.userPreferences.weekStartDay.rawValue
        let now = Date()

        _Concurrency.Task.detached(priority: .userInitiated) {
            let boards = (try? AppDatabase.shared.fetchBoards(userId: userId)) ?? []

            // Hero: daily greenlog streak
            let current = computeStreak(
                timeframe: .daily, criterion: .greenlog,
                boards: boards, weekStartDay: weekStartDay, now: now
            )

            // Longest: across daily greenlog run
            let longest = computeLongestStreak(
                timeframe: .daily, boards: boards, weekStartDay: weekStartDay, now: now
            )

            // Total GREENLOGs = all completed non-deleted boards
            let completedBoards = boards.filter { $0.status == .completed && !$0.isDeleted }
            let greenlogCount = completedBoards.count

            // Week strip — last 7 days; a dot is filled if a daily core board
            // was completed that calendar day. Derived from completedAt strings.
            let dots = Self.buildWeekDots(boards: boards, now: now)

            // History — all completed non-deleted boards, sorted newest-first
            let history = Self.buildHistoryRows(boards: completedBoards, now: now)

            await MainActor.run {
                self.currentStreak = current
                self.longestStreak = longest
                self.greenlogCount = greenlogCount
                self.weekDots = dots
                self.historyRows = history
            }
        }
    }

    // MARK: - Week-dot derivation

    /// Returns 7 `WeekDot` values for the last 7 days (oldest → newest).
    /// A dot is filled green when a daily core board was GREENLOGed on that day.
    /// Falls back to streak coverage when no board has a `completedAt` on a day
    /// that is within the daily greenlog streak range — this ensures the strip
    /// looks non-empty for reasonable users even if `completedAt` is missing.
    private static func buildWeekDots(boards: [Board], now: Date) -> [WeekDot] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        // Collect the set of days (as day-start Date) where a daily core board
        // was GREENLOGed. We match completedAt's calendar day to each strip day.
        var greenloggedDays: Set<Date> = []
        for board in boards where board.isCore && board.timeframe == .daily && board.status == .completed && !board.isDeleted {
            // Use the shared parser, not a bare ISO8601DateFormatter — it tolerates
            // both UTC-`Z` and local-ISO `completedAt` strings (synced rows can be
            // either); a bare formatter would silently drop the non-`Z` ones.
            if let raw = board.completedAt, let date = DateFormatting.parseISO(raw) {
                let dayStart = calendar.startOfDay(for: date)
                greenloggedDays.insert(dayStart)
            }
        }
        return (0..<7).map { offset in
            let day = calendar.date(byAdding: .day, value: -(6 - offset), to: today)!
            let isToday = calendar.isDate(day, inSameDayAs: today)
            let isFilled = greenloggedDays.contains(day)
            return WeekDot(date: day, isFilled: isFilled, isToday: isToday)
        }
    }

    // MARK: - History-row derivation

    private static func buildHistoryRows(boards: [Board], now: Date) -> [StreakHistoryRow] {
        let calendar = Calendar.current
        return boards
            .compactMap { board -> (Board, Date)? in
                // Shared parser tolerates both UTC-`Z` and local-ISO completedAt.
                guard let raw = board.completedAt, let date = DateFormatting.parseISO(raw) else { return nil }
                return (board, date)
            }
            .sorted { $0.1 > $1.1 }
            .map { (board, date) in
                StreakHistoryRow(
                    id: board.id,
                    name: board.name,
                    squares: board.totalTasks,
                    bingos: board.linesCompleted,
                    timeframe: board.timeframe,
                    relativeDate: Self.relativeLabel(for: date, now: now, calendar: calendar)
                )
            }
    }

    private static func relativeLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }
}

// MARK: - Supporting value types

/// One dot in the 7-day week strip.
struct WeekDot: Identifiable {
    let id = UUID()
    let date: Date
    /// True when a daily core board was GREENLOGed on this calendar day.
    let isFilled: Bool
    /// True when this dot represents today.
    let isToday: Bool
}

/// One row in the GREENLOG history list.
struct StreakHistoryRow: Identifiable {
    let id: String
    let name: String
    let squares: Int
    let bingos: Int
    let timeframe: Timeframe
    let relativeDate: String
}

// MARK: - StreaksContent (pure-props leaf, snapshot-testable)

/// Pure presentational leaf for the Streaks & history page.
/// No environment, no DB, no Firebase. Receives plain values + displays them.
struct StreaksContent: View {

    // Hero
    let currentStreak: Int
    // Stat trio
    let longestStreak: Int
    let greenlogCount: Int
    // Week strip
    let weekDots: [WeekDot]
    // History list
    let historyRows: [StreakHistoryRow]

    var body: some View {
        ZStack {
            RisoPaperBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    RisoSubPageHeader(title: "Streaks")
                        .padding(.top, 16)
                        .padding(.bottom, 20)

                    sectionLabel("Your rhythm")

                    // 1. Hero card (gold)
                    heroCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)

                    // 2. Stat trio
                    statTrio
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)

                    // 3. GREENLOG history
                    sectionLabel("Greenlog history")

                    historySection
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)

                    // Footer hint
                    Text("Every cleared board lands here. Keep the chain going.")
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 32)
                }
            }
        }
    }

    // MARK: - Section label

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .risoSectionLabel()
            .padding(.horizontal, Riso.gutter)
            .padding(.bottom, 8)
    }

    // MARK: - Hero card

    private var heroCard: some View {
        VStack(spacing: 0) {
            // Medallion + streak number row
            HStack(alignment: .center, spacing: 14) {
                // Red spark medallion icon square
                Image(systemName: "flame.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.risoInkStatic)
                    .frame(width: 50, height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .fill(Color.risoRed)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .strokeBorder(Color.risoInkStatic, lineWidth: Riso.Keyline.dense)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(currentStreak)")
                            .font(.risoHead(42, .extraBold))
                            .foregroundStyle(Color.risoInkStatic)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text("day streak")
                            .font(.risoHead(16, .bold))
                            .foregroundStyle(Color.risoInkStatic.opacity(0.7))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Riso.cardPadding)
            .padding(.top, Riso.cardPadding)

            // 7-dot week strip
            weekStrip
                .padding(.horizontal, Riso.cardPadding)
                .padding(.top, 12)

            // "Keep it alive" note
            Text(keepItAliveNote)
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoInkStatic.opacity(0.65))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Riso.cardPadding)
                .padding(.top, 8)
                .padding(.bottom, Riso.cardPadding)
        }
        .risoCard(fill: .risoGold)
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Daily streak: \(currentStreak) day\(currentStreak == 1 ? "" : "s")")
    }

    private var keepItAliveNote: String {
        if currentStreak == 0 { return "Complete a daily board to start your streak." }
        if currentStreak == 1 { return "Off to a great start — come back tomorrow!" }
        return "Great work! Complete today's board to keep the chain going."
    }

    // MARK: - Week strip

    private var weekStrip: some View {
        HStack(spacing: 6) {
            ForEach(weekDots) { dot in
                weekDotView(dot)
            }
        }
    }

    private func weekDotView(_ dot: WeekDot) -> some View {
        let filled = dot.isFilled
        let isToday = dot.isToday
        return Circle()
            .fill(filled ? Color.risoGreen : Color.risoInkStatic.opacity(0.15))
            .frame(width: 28, height: 28)
            .overlay(
                Circle()
                    .strokeBorder(
                        isToday ? Color.risoInkStatic : Color.clear,
                        lineWidth: 2
                    )
            )
            .overlay(
                // Checkmark when filled
                Group {
                    if filled {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.risoPaper)
                    }
                }
            )
            .accessibilityElement()
            .accessibilityLabel(dot.isFilled ? "Completed" : (dot.isToday ? "Today — not yet" : "Missed"))
    }

    // MARK: - Stat trio

    private var statTrio: some View {
        HStack(spacing: 10) {
            statCard(label: "Current", value: "\(currentStreak)d", accent: .risoRed)
            statCard(label: "Longest", value: longestStreak == 0 ? "–" : "\(longestStreak)d", accent: .risoBlue)
            statCard(label: "GREENLOGs", value: "\(greenlogCount)", accent: .risoGreen)
        }
    }

    private func statCard(label: String, value: String, accent: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.risoHead(22, .extraBold))
                .foregroundStyle(Color.risoInk)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(label)
                .font(.risoBody(11, .bold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(Color.risoMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: - History section

    @ViewBuilder
    private var historySection: some View {
        if historyRows.isEmpty {
            emptyHistoryCard
        } else {
            VStack(spacing: 0) {
                ForEach(Array(historyRows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider()
                            .background(Color.risoInk.opacity(0.12))
                            .padding(.horizontal, Riso.cardPadding)
                    }
                    historyRow(row)
                }
            }
            .risoCard()
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        }
    }

    private var emptyHistoryCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.risoMuted.opacity(0.5))
            Text("No completed boards yet")
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoMuted)
            Text("Complete all tasks on any board to add it here.")
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, Riso.cardPadding)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    private func historyRow(_ row: StreakHistoryRow) -> some View {
        HStack(spacing: 12) {
            // Green checkmark badge
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.risoPaper)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.risoGreen)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                )

            // Name + meta
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.risoBody(14, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                Text("\(row.squares) squares · \(row.bingos) bingo\(row.bingos == 1 ? "" : "s")")
                    .font(.risoBody(12, .regular))
                    .foregroundStyle(Color.risoMuted)
            }

            Spacer(minLength: 0)

            // Timeframe pill + date
            VStack(alignment: .trailing, spacing: 4) {
                timeframeTag(row.timeframe)
                Text(row.relativeDate)
                    .font(.risoBody(11, .regular))
                    .foregroundStyle(Color.risoMuted)
            }
        }
        .padding(.horizontal, Riso.cardPadding)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(row.squares) squares, \(row.bingos) bingos, \(row.relativeDate)")
    }

    private func timeframeTag(_ timeframe: Timeframe) -> some View {
        let label: String
        switch timeframe {
        case .daily:   label = "Daily"
        case .weekly:  label = "Weekly"
        case .monthly: label = "Monthly"
        case .yearly:  label = "Yearly"
        case .custom:  label = "Custom"
        case .indefinite: label = "Ongoing"
        }
        return Text(label.uppercased())
            .font(.risoHead(9, .bold))
            .tracking(0.45)
            .foregroundStyle(Color.risoPaper)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Capsule().fill(timeframe.risoColor))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Streaks — healthy") {
    NavigationStack {
        StreaksContent(
            currentStreak: 12,
            longestStreak: 24,
            greenlogCount: 37,
            weekDots: [
                WeekDot(date: Date(), isFilled: true, isToday: false),
                WeekDot(date: Date(), isFilled: true, isToday: false),
                WeekDot(date: Date(), isFilled: false, isToday: false),
                WeekDot(date: Date(), isFilled: true, isToday: false),
                WeekDot(date: Date(), isFilled: true, isToday: false),
                WeekDot(date: Date(), isFilled: true, isToday: false),
                WeekDot(date: Date(), isFilled: false, isToday: true),
            ],
            historyRows: [
                StreakHistoryRow(id: "b1", name: "April Reading Sprint", squares: 25, bingos: 3, timeframe: .monthly, relativeDate: "Today"),
                StreakHistoryRow(id: "b2", name: "Week 22 Workout", squares: 9, bingos: 1, timeframe: .weekly, relativeDate: "May 31"),
                StreakHistoryRow(id: "b3", name: "Morning routine", squares: 9, bingos: 2, timeframe: .daily, relativeDate: "May 30"),
            ]
        )
    }
}

#Preview("Streaks — empty") {
    NavigationStack {
        StreaksContent(
            currentStreak: 0,
            longestStreak: 0,
            greenlogCount: 0,
            weekDots: (0..<7).map { i in WeekDot(date: Date(), isFilled: false, isToday: i == 6) },
            historyRows: []
        )
    }
}
#endif
