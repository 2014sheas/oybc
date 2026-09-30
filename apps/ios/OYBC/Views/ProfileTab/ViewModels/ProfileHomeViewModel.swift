import Foundation

/// Loads and derives the DB-backed pieces of the Profile home screen
/// (Profile reorg PR2, `design_handoff_profile_reorg/README.md` §1):
///
///   - the Board settings tile's repeating-board count,
///   - the Streak tile's bingo / longest / greenlog stats,
///   - the Shared counters section's most-recently-logged counters.
///
/// Identity (name/email/avatar) and Getting Started progress are
/// environment-sourced (`AuthService` / `TutorialProgressStore`) and read
/// directly by `ProfileView` — this view model only owns state that needs a
/// DB read, following the `AppDatabase`-injection seam (CLAUDE.md "DB access
/// in new/touched ViewModels") so it's constructible against
/// `AppDatabase.makeTestInstance()` in tests without touching the production
/// singleton.
@MainActor
final class ProfileHomeViewModel: ObservableObject {

    // MARK: - Published state

    /// Non-deleted repeating-board templates (active AND paused) — the
    /// Board settings tile's "{n} repeating boards" line counts the whole
    /// roster, matching `BoardSettingsView`'s own roster list.
    @Published private(set) var repeatingBoardsCount: Int = 0
    @Published private(set) var streak = StreakStats()
    /// The two most-recently-logged counters (or fewer), most recent first.
    @Published private(set) var recentCounters: [SharedCounterGroup] = []
    /// Total live counter count — feeds the "All {n} ›" link.
    @Published private(set) var totalCounterCount: Int = 0
    /// The user's live (non-deleted) task pool — dedupe input for the "+ New
    /// counter" sheet opened from the empty-counters CTA.
    @Published private(set) var counterDedupeTasks: [OYBC.Task] = []
    /// False until `load()` lands — an empty `recentCounters` before this is
    /// "not computed yet", not "no counters" (late-mutation audit, shape B;
    /// mirrors `ProfileView`'s pre-existing `streaksLoaded` convention).
    @Published private(set) var isLoaded = false
    /// Counter ids with an in-flight "+ Log" write — disables that row's pill.
    @Published private(set) var loggingCounterIds: Set<String> = []
    /// The "Logged +N · Undo" toast raised by a successful "+ Log" — the same
    /// `CounterLogToastView` affordance the Counters Hub shows (parity with
    /// web's Profile home, which reuses the hub's `CounterLogToast`). `nil`
    /// when no toast is showing; cleared by Undo or the view's auto-dismiss.
    @Published private(set) var toast: LogToast?

    struct StreakStats: Equatable {
        var bingoStreak: Int = 0
        var longestStreak: Int = 0
        var greenlogCount: Int = 0
    }

    // MARK: - DB injection

    private let db: AppDatabase
    init(db: AppDatabase = .shared) {
        self.db = db
    }

    // MARK: - Loading

    /// Loads every DB-backed piece in one background hop.
    ///
    /// - Parameters:
    ///   - userId: The signed-in user.
    ///   - weekStartDay: `authService.userPreferences.weekStartDay.rawValue`
    ///     — only affects weekly streak windows (the tile itself always
    ///     shows the DAILY streak, but `computeStreak` takes it uniformly).
    ///   - now: Reference instant, injected for deterministic tests.
    func load(userId: String, weekStartDay: String, now: Date = Date()) {
        let db = self.db
        _Concurrency.Task.detached(priority: .userInitiated) {
            let boards = (try? db.fetchBoards(userId: userId)) ?? []
            let templates = (try? db.fetchRecurringBoardTemplates(userId: userId)) ?? []
            let (tasks, groups) = db.fetchSharedCounterGroups(userId: userId, showExpired: false, now: now)
            let events = (try? db.fetchNonDeletedTaskEvents(userId: userId)) ?? []
            let eventsByTaskId = Dictionary(grouping: events, by: \.taskId)
            let tasksById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

            // Streak tile: headline number is the daily BINGO streak (design
            // handoff §Interactions: "Streak tile number: Daily timeframe,
            // bingo streak"); Longest + GREENLOGs reuse the exact stats
            // StreaksView's hero already computes (daily greenlog longest-run
            // + all-time completed-board count) so the two surfaces never
            // disagree about what "Longest"/"GREENLOGs" means.
            let bingoStreak = computeStreak(
                timeframe: .daily, criterion: .bingo,
                boards: boards, weekStartDay: weekStartDay, now: now
            )
            let longestStreak = computeLongestStreak(
                timeframe: .daily, boards: boards, weekStartDay: weekStartDay, now: now
            )
            let greenlogCount = boards.filter { $0.status == .completed && !$0.isDeleted }.count

            let ordered = Self.orderCountersByRecency(
                groups: groups, tasksById: tasksById, eventsByTaskId: eventsByTaskId
            )

            await MainActor.run {
                self.repeatingBoardsCount = templates.count
                self.streak = StreakStats(
                    bingoStreak: bingoStreak,
                    longestStreak: longestStreak,
                    greenlogCount: greenlogCount
                )
                self.recentCounters = Array(ordered.prefix(2))
                self.totalCounterCount = groups.count
                self.counterDedupeTasks = tasks
                self.isLoaded = true
            }
        }
    }

    // MARK: - "+ Log" pill + Undo toast

    /// Toast state for one "+ Log" — mirrors the Hub's private
    /// `HubToastState` field for field (`toastKey` re-keys the view so the
    /// auto-dismiss timer restarts on back-to-back logs).
    struct LogToast: Equatable {
        let counterId: String
        let amount: Int
        let unit: String
        let verb: CounterLogToastView.Verb
        let toastKey: String
    }

    /// Dismisses the toast without undoing (auto-dismiss / `onDone`).
    func dismissToast() {
        toast = nil
    }

    /// Logs `group.defaultLogAmount ?? 1` for `group` in place, raises the
    /// "Logged +N · Undo" toast, then reloads. Mirrors
    /// `CountersHubView.handleLog`'s write path exactly (same
    /// `incrementSharedCounter` call, same `attemptLoggedWrite` logging
    /// wrapper, same toast/Undo affordance) — the Profile compact row and the
    /// Hub's full card share one underlying op, per the design handoff's
    /// "reuse, don't duplicate".
    ///
    /// - Parameters:
    ///   - group: The counter to log.
    ///   - onError: Fired on the main actor when the write fails (the caller
    ///     surfaces an alert; a failed write never toasts "Logged +N").
    func handleLog(
        group: SharedCounterGroup,
        userId: String,
        weekStartDay: String,
        onError: @escaping (String) -> Void
    ) {
        guard !loggingCounterIds.contains(group.counterId) else { return }
        let amount = group.defaultLogAmount ?? 1
        let counterId = group.counterId
        let unit = group.unit ?? ""
        let db = self.db
        loggingCounterIds.insert(counterId)
        _Concurrency.Task.detached(priority: .userInitiated) {
            let ok = attemptLoggedWrite("ProfileHomeViewModel.handleLog(\(counterId))") {
                _ = try db.incrementSharedCounter(sourceTaskId: counterId, by: amount)
            }
            await MainActor.run {
                self.loggingCounterIds.remove(counterId)
                guard ok else {
                    onError("Failed to log. Try again.")
                    return
                }
                self.toast = LogToast(
                    counterId: counterId, amount: amount, unit: unit,
                    verb: .logged, toastKey: UUID().uuidString
                )
                self.load(userId: userId, weekStartDay: weekStartDay)
            }
        }
    }

    /// Reverses the most recent log on `counterId` (the toast's Undo) via
    /// `undoLastCounterLog` — the same op the Hub's Undo calls — clears the
    /// toast, then reloads. A failed write reports through `onError` instead
    /// of silently leaving the count as-is.
    func handleUndo(
        counterId: String,
        userId: String,
        weekStartDay: String,
        onError: @escaping (String) -> Void
    ) {
        let db = self.db
        _Concurrency.Task.detached(priority: .userInitiated) {
            let ok = attemptLoggedWrite("ProfileHomeViewModel.handleUndo(\(counterId))") {
                _ = try db.undoLastCounterLog(sourceTaskId: counterId)
            }
            await MainActor.run {
                self.toast = nil
                guard ok else {
                    onError("Failed to undo. Try again.")
                    return
                }
                self.load(userId: userId, weekStartDay: weekStartDay)
            }
        }
    }

    // MARK: - Pure helpers (unit-tested independently of the DB)

    /// Orders counter groups by "most recently logged" — the counter root's
    /// latest `.increment` `task_events` row (`selectLastIncrementEntry`'s
    /// `createdAt`), falling back to the source task's own `createdAt` when
    /// it has never been logged. Ties break on `counterId` for a stable,
    /// deterministic order. No new persisted field (owner-decisions.md
    /// amendment 2026-09-30 §Derived, not new state).
    nonisolated static func orderCountersByRecency(
        groups: [SharedCounterGroup],
        tasksById: [String: OYBC.Task],
        eventsByTaskId: [String: [TaskEvent]]
    ) -> [SharedCounterGroup] {
        groups.sorted { a, b in
            let dateA = lastActivityDate(counterId: a.counterId, tasksById: tasksById, eventsByTaskId: eventsByTaskId)
            let dateB = lastActivityDate(counterId: b.counterId, tasksById: tasksById, eventsByTaskId: eventsByTaskId)
            if dateA != dateB { return dateA > dateB }
            return a.counterId < b.counterId
        }
    }

    /// The instant used to order one counter: its latest increment event's
    /// `createdAt` (write time — same convention `selectLastIncrementEntry`
    /// already uses for Undo), or the source task's `createdAt` when it has
    /// no qualifying event yet. Unparseable/missing timestamps degrade to
    /// `.distantPast` so a malformed row sorts last rather than crashing.
    nonisolated static func lastActivityDate(
        counterId: String,
        tasksById: [String: OYBC.Task],
        eventsByTaskId: [String: [TaskEvent]]
    ) -> Date {
        let events = eventsByTaskId[counterId] ?? []
        if let entry = selectLastIncrementEntry(events: events, sourceTaskId: counterId),
           let created = DateFormatting.parseISO(entry.createdAt) {
            return created
        }
        if let createdAt = tasksById[counterId]?.createdAt,
           let parsed = DateFormatting.parseISO(createdAt) {
            return parsed
        }
        return .distantPast
    }

    /// The Board settings tile's two summary lines (design handoff §Copy:
    /// `Defaults 3×3 · Free · Mon` / `2 repeating boards` /
    /// `No repeating boards yet`).
    struct BoardSettingsTileSummary: Equatable {
        let defaultsLine: String
        let repeatingLine: String
    }

    nonisolated static func boardSettingsTileSummary(
        defaultBoardSize: DefaultBoardSize,
        centerType: DefaultCenterSquareType,
        weekStartDay: WeekStartDay,
        repeatingCount: Int
    ) -> BoardSettingsTileSummary {
        let size = "\(defaultBoardSize.rawValue)×\(defaultBoardSize.rawValue)"
        let center = centerType == .free ? "Free" : "None"
        let weekStart = weekStartDay == .monday ? "Mon" : "Sun"
        let repeatingLine = repeatingCount == 0
            ? "No repeating boards yet"
            : "\(repeatingCount) repeating board\(repeatingCount == 1 ? "" : "s")"
        return BoardSettingsTileSummary(
            defaultsLine: "Defaults \(size) · \(center) · \(weekStart)",
            repeatingLine: repeatingLine
        )
    }

    /// Which Getting Started surface Profile home shows, per design handoff
    /// §1.3: hidden once every lesson is done; the gold day-one hero (ABOVE
    /// the tiles) only while `completedCount == 0`; the compact row
    /// (BELOW the tiles) for every state in between.
    enum GettingStartedDisplay: Equatable {
        case hidden
        case dayOneHero
        case row
    }

    nonisolated static func gettingStartedDisplay(completedCount: Int, isComplete: Bool) -> GettingStartedDisplay {
        if isComplete { return .hidden }
        return completedCount == 0 ? .dayOneHero : .row
    }
}
