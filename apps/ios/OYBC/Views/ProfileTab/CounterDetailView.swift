import SwiftUI

// MARK: - CounterDetailView (container)

/// Profile sub-page — one shared counter's home (Shared Counters P1 + P2,
/// R2 Counters UX refresh).
///
/// Container: loads fresh data on appear/after log/undo (group + trailing
/// daily totals for the sparkline/Today stat), then renders
/// `CounterDetailContent`.
///
/// Sections (R2 Counters UX refresh — design handoff §Counter Detail):
///   1. Header — back circle · blue "SHARED COUNTER" kicker · counter name ·
///      "⋯" overflow (Delete counter…).
///   2. Hero card — all-time total + REAL 7-day sparkline
///      (`AppDatabase.fetchCounterDailyTotals`) + milestone bar
///      (`counterMilestoneProgress`, `Helpers/CounterMilestone.swift`).
///   3. Stat strip — Today (REAL) / Streak (STUB) / Best week (STUB).
///   4. Log card (blue fill) — `CounterDetailLogCard`: fixed chips per kind +
///      −/+Add. Logging updates the counter's `defaultLogAmount` to the amount
///      just used and shows the reusable `CounterLogToastView` ("Logged +N · Undo").
///   5. "Counting on N tasks" — active member cards.
///   7. "Not counting now" — inactive members greyed.
///   8. Delete — quiet red text link (was a filled `RisoButton`).
struct CounterDetailView: View {

    let counterId: String
    /// §Member rules (B3, RC9) — expired-member visibility, threaded from the
    /// hub on push (web carries it as `?showExpired=1`). Defaults to the hub's
    /// own default, so other entry points need not pass it.
    var showExpired: Bool = false
    /// Member-card tap → the host opens that board (cross-tab via
    /// `MainTabView.openBoard`, so a core board lands in its pager window).
    let onOpenBoard: (String) -> Void

    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    // MARK: - Private state

    @State private var group: SharedCounterGroup?
    @State private var isLoaded = false
    @State private var dailyTotals = CounterDailyTotalsResult(days: [], todayTotal: 0)
    @State private var isLogging = false
    @State private var logError: String?
    @State private var toast: DetailToastState?

    // Delete-counter (P5 decision 8: deleteCounterWithUnlink) UI state.
    @State private var deleteImpact: AppDatabase.TaskDeletionImpact?
    @State private var isDeleting = false
    @State private var deleteError: String?

    /// Trailing window for the sparkline + "Today" stat.
    private static let sparklineDays = 7

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            RisoPaperBackground()

            if let group {
                CounterDetailContent(
                    group: group,
                    dailyTotals: dailyTotals,
                    isLogging: isLogging,
                    logError: logError,
                    deleteError: deleteError,
                    onLog: { amount, direction in handleLog(amount: amount, direction: direction) },
                    onDeleteTap: handleDeleteTap,
                    onOpenBoard: onOpenBoard
                )
            } else if isLoaded {
                notFoundState
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let toast {
                CounterLogToastView(
                    amount: toast.amount,
                    unit: toast.unit,
                    verb: toast.verb,
                    kind: toast.kind,
                    onUndo: handleUndo,
                    onDone: { self.toast = nil }
                )
                .padding(.horizontal, Riso.gutter)
                .padding(.bottom, 24)
                .id(toast.toastKey)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationBarHidden(true)
        .onAppear { loadData() }
        // Delete-confirm sheet — mirrors the `countingStepperBoardTaskId`
        // Binding-derivation pattern in `BoardPlayView.swift`. NOT a
        // `swipeActions` destructive Button (known SwiftUI crash trap) and
        // NOT a plain `.alert` (the member-unlink list needs a scrollable
        // custom body, matching web's richer `CounterDeleteConfirmDialog`).
        .sheet(
            isPresented: Binding(
                get: { deleteImpact != nil },
                set: { if !$0 { deleteImpact = nil } }
            )
        ) {
            if let impact = deleteImpact, let group {
                CounterDeleteConfirmView(
                    group: group,
                    impact: impact,
                    isDeleting: isDeleting,
                    onConfirm: { handleConfirmDelete(impact: impact) },
                    onCancel: { deleteImpact = nil }
                )
                .interactiveDismissDisabled(isDeleting)
            }
        }
    }

    // MARK: - Data loading

    private func loadData() {
        guard let userId = authService.currentUser?.id else { return }
        let id = counterId
        let visibility = showExpired
        _Concurrency.Task.detached(priority: .userInitiated) {
            // RC9 — the kernel drops expired members after the root walk (as the hub).
            let groups = AppDatabase.shared.fetchSharedCounterGroups(
                userId: userId, showExpired: visibility
            ).groups
            let found = groups.first { $0.counterId == id }
            let totals = (try? AppDatabase.shared.fetchCounterDailyTotals(
                sourceTaskId: id, days: Self.sparklineDays, now: AppDatabase.currentTimestamp()
            )) ?? CounterDailyTotalsResult(days: [], todayTotal: 0)
            await MainActor.run {
                group = found
                dailyTotals = totals
                isLoaded = true
            }
        }
    }

    // MARK: - Log (amount-chip driven — P2 + R2)

    /// Logs `amount` in `direction`, persists it as the counter's new
    /// default, then surfaces the "Logged/Removed" toast. Mirrors web's
    /// `CounterDetailPage.handleLog`.
    private func handleLog(amount: CountValue, direction: CounterLogDirection) {
        guard !isLogging, amount > 0, let group else { return }
        isLogging = true
        logError = nil
        let id = counterId
        let unit = group.unit ?? ""
        let kindForToast = group.countKind
        _Concurrency.Task.detached(priority: .userInitiated) {
            let ok = attemptLoggedWrite("CounterDetailView.handleLog(\(id))") {
                switch direction {
                case .add:
                    _ = try AppDatabase.shared.incrementSharedCounter(sourceTaskId: id, by: amount)
                case .remove:
                    // decrementSharedCounter clamps to 0 itself — no additional guard needed.
                    _ = try AppDatabase.shared.decrementSharedCounter(sourceTaskId: id, by: amount)
                }
                // The amount just used becomes the new default (no-op if unchanged).
                try AppDatabase.shared.setCounterDefaultLogAmount(sourceTaskId: id, amount: amount)
            }
            await MainActor.run {
                isLogging = false
                if ok {
                    toast = DetailToastState(
                        amount: amount, unit: unit, kind: kindForToast,
                        verb: direction == .add ? .logged : .removed,
                        toastKey: UUID().uuidString
                    )
                    loadData()
                } else {
                    logError = "Failed to log. Try again."
                }
            }
        }
    }

    private func handleUndo() {
        let id = counterId
        _Concurrency.Task.detached(priority: .userInitiated) {
            let ok = attemptLoggedWrite("CounterDetailView.handleUndo(\(id))") { _ = try AppDatabase.shared.undoLastCounterLog(sourceTaskId: id) }
            await MainActor.run {
                toast = nil
                if ok { loadData() } else { logError = "Failed to undo. Try again." }
            }
        }
    }

    // MARK: - Delete counter (P5 decision 8)

    /// Computes the deletion impact (member count + rows) before showing the
    /// confirm sheet — read-only, safe to call before the user commits.
    private func handleDeleteTap() {
        deleteError = nil
        let id = counterId
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                let impact = try AppDatabase.shared.computeTaskDeletionImpact(taskId: id)
                await MainActor.run { deleteImpact = impact }
            } catch {
                await MainActor.run { deleteError = "Failed to compute delete impact." }
            }
        }
    }

    /// Confirms the delete: unlinks every live member (each keeps its current
    /// count as an independent standalone counter) then cascade-deletes the
    /// source, all in one GRDB write transaction (`deleteCounterWithUnlink`).
    ///
    /// On success, pops back to the Counters Hub. On failure, closes the
    /// confirm sheet and surfaces `deleteError` on the underlying page —
    /// mirrors web's `CounterDetailPage.handleConfirmDelete` close-dialog-
    /// on-error pattern (never leaves a stale confirm sheet open over a
    /// failed op the user can't see feedback for).
    private func handleConfirmDelete(impact: AppDatabase.TaskDeletionImpact) {
        guard !isDeleting else { return }
        isDeleting = true
        deleteError = nil
        let id = counterId
        _Concurrency.Task.detached(priority: .userInitiated) {
            let now = AppDatabase.currentTimestamp()
            do {
                try AppDatabase.shared.deleteCounterWithUnlink(sourceId: id, now: now)
                await MainActor.run {
                    isDeleting = false
                    deleteImpact = nil
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                    deleteImpact = nil
                    deleteError = "Failed to delete counter."
                }
            }
        }
    }

    // MARK: - Not-found state

    private var notFoundState: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.risoMuted.opacity(0.5))
            Text("Counter not found")
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Log direction for `CounterDetailContent.onLog` — an add ("+ Add N",
/// `incrementSharedCounter`) or a remove ("−", `decrementSharedCounter`).
enum CounterLogDirection {
    case add
    case remove
}

/// Toast state for the Counter Detail log card's "Logged/Removed +N · Undo" toast.
private struct DetailToastState {
    let amount: CountValue
    let unit: String
    let kind: CountKind
    let verb: CounterLogToastView.Verb
    let toastKey: String
}

// MARK: - CounterDetailContent (pure-props leaf, snapshot-testable)

/// Pure presentational leaf for the Counter Detail page.
/// No environment, no DB, no Firebase — receives plain values. The Log card
/// (`CounterDetailLogCard`) owns the amount-chip selection state.
struct CounterDetailContent: View {

    let group: SharedCounterGroup
    var dailyTotals: CounterDailyTotalsResult
    var isLogging: Bool
    var logError: String?
    /// Surfaced when a delete attempt fails — the confirm sheet has already
    /// closed by the time this is shown (mirrors web's close-dialog-on-error
    /// pattern), so it renders on this page itself.
    var deleteError: String?
    var onLog: (CountValue, CounterLogDirection) -> Void
    /// Fired by the "⋯" overflow menu's "Delete counter…" item AND the
    /// footer's red text link — the container computes the deletion impact
    /// and shows the confirm sheet.
    var onDeleteTap: () -> Void
    /// Member-card tap → open that board (host-routed; core → pager).
    var onOpenBoard: (String) -> Void

    /// Snapshot-testability seams forwarded to the Log card.
    private let initialSelectedAmount: CountValue?
    private let initialCustomActive: Bool

    init(
        group: SharedCounterGroup,
        dailyTotals: CounterDailyTotalsResult = CounterDailyTotalsResult(days: [], todayTotal: 0),
        isLogging: Bool = false,
        logError: String? = nil,
        deleteError: String? = nil,
        initialSelectedAmount: CountValue? = nil,
        /// Snapshot-testability seam: forces the "#" custom chip into its
        /// selected (gold, showing the live amount) state without requiring
        /// a real tap sequence. Production call sites never pass this.
        initialCustomActive: Bool = false,
        onLog: @escaping (CountValue, CounterLogDirection) -> Void = { _, _ in },
        onDeleteTap: @escaping () -> Void = {},
        onOpenBoard: @escaping (String) -> Void = { _ in }
    ) {
        self.group = group
        self.dailyTotals = dailyTotals
        self.isLogging = isLogging
        self.logError = logError
        self.deleteError = deleteError
        self.onLog = onLog
        self.onDeleteTap = onDeleteTap
        self.onOpenBoard = onOpenBoard
        self.initialSelectedAmount = initialSelectedAmount
        self.initialCustomActive = initialCustomActive
    }

    // MARK: - Derived

    private var unitLabel: String { group.unit ?? "" }

    /// The family kind (D5) — every value on the page formats at it.
    private var kind: CountKind { group.countKind }

    private var activeMembers: [SharedCounterMemberTask] {
        group.tasks.filter { $0.isActive }
    }

    private var inactiveMembers: [SharedCounterMemberTask] {
        group.tasks.filter { !$0.isActive }
    }

    private var milestoneProgress: CounterMilestoneProgress {
        counterMilestoneProgress(group.lifetime, kind: kind)
    }

    // MARK: - Body

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                // Header row — blue "SHARED COUNTER" kicker + "⋯" overflow.
                HStack(spacing: 8) {
                    RisoSubPageHeader(title: group.name, kicker: "Shared counter", kickerColor: .risoBlue)
                    overflowMenu
                        .padding(.trailing, Riso.gutter)
                }
                .padding(.top, 16)
                .padding(.bottom, 20)

                // 1. Hero card
                heroCard
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 14)

                // 2. Stat strip — Today (real) / Streak / Best week (P4 stubs)
                statStrip
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 14)

                // 3. Log card (chips per kind + −/+Add)
                CounterDetailLogCard(
                    group: group,
                    isLogging: isLogging, logError: logError,
                    initialSelectedAmount: initialSelectedAmount, initialCustomActive: initialCustomActive,
                    onLog: onLog
                )
                .id("\(group.counterId)-\(group.countKind.rawValue)")
                .padding(.horizontal, Riso.gutter)
                .padding(.bottom, 18)

                // 5. "Counting on N tasks" (active members)
                if !activeMembers.isEmpty {
                    sectionLabel("Counting on \(activeMembers.count) task\(activeMembers.count == 1 ? "" : "s")")
                    activeMembersSection
                        .padding(.bottom, 14)
                }

                // 7. "Not counting now" (inactive members)
                if !inactiveMembers.isEmpty {
                    sectionLabel("Not counting now")
                    inactiveMembersSection
                        .padding(.bottom, 14)
                }

                // 8. Delete-counter action — quiet red text link.
                if let deleteError {
                    Text(deleteError)
                        .font(.risoBody(12, .semibold))
                        .foregroundStyle(Color.risoRed)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 8)
                }
                Button("Delete counter…", action: onDeleteTap)
                    .font(.risoHead(12, .bold))
                    .foregroundStyle(Color.risoRed)
                    .buttonStyle(.plain)
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 14)

                Spacer(minLength: 24)
            }
        }
    }

    // MARK: - Overflow menu

    private var overflowMenu: some View {
        Menu {
            Button(role: .destructive, action: onDeleteTap) {
                Label("Delete counter…", systemImage: "trash")
            }
        } label: {
            Text("⋯")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.risoPaper2))
                .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
        }
        .accessibilityLabel("Counter options")
    }

    // MARK: - Hero card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatCountTotal(group.lifetime, kind: kind))
                        .font(.risoHead(46, .extraBold))
                        .foregroundStyle(Color.risoBlue)
                        .monospacedDigit()
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                    Text("all-time\(countUnitSuffix(kind, unit: group.unit))")
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoMuted)
                }

                Spacer(minLength: 8)

                if !dailyTotals.days.isEmpty {
                    sparkline
                }
            }
            .padding(.horizontal, Riso.cardPadding)
            .padding(.top, Riso.cardPadding)

            milestoneBar
                .padding(.horizontal, Riso.cardPadding)
                .padding(.top, 10)
                .padding(.bottom, Riso.cardPadding)
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name), \(formatCountTotal(group.lifetime, kind: kind)) all-time\(countUnitSuffix(kind, unit: group.unit))")
    }

    /// 7-day sparkline (real data via `dailyTotals`) — 9px-wide bars, blue
    /// with a static-ink border, today's bar gold.
    private var sparkline: some View {
        let maxDaily = max(1, dailyTotals.days.map(\.total).max() ?? 0)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(dailyTotals.days.enumerated()), id: \.offset) { index, day in
                let isToday = index == dailyTotals.days.count - 1
                // 6% min-bar floor — matches web's `Math.max(6, …)` percentage
                // exactly (R2 final review: 0.12 rendered tiny days ~2× taller).
                let heightFraction = max(0.06, day.total / maxDaily)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isToday ? Color.risoGold : Color.risoBlue)
                    .frame(width: 9, height: 40 * heightFraction)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1.5)
                            .strokeBorder(Color.risoInkStatic, lineWidth: 1)
                    )
            }
        }
        .frame(height: 40, alignment: .bottom)
        .accessibilityLabel("7-day activity — today \(formatCountWithUnit(dailyTotals.todayTotal, kind: kind, unit: unitLabel))")
    }

    private var milestoneBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            RisoProgressBar(value: milestoneProgress.fraction, color: .risoBlue, height: 8)
            (
                Text("\(formatCountTotal(milestoneProgress.remaining, kind: kind)) to ")
                    .font(.risoBody(10, .regular))
                    .foregroundStyle(Color.risoMuted)
                + Text(formatCountTotal(milestoneProgress.next, kind: kind))
                    .font(.risoBody(10, .bold))
                    .foregroundStyle(Color.risoMuted)
                + Text(" milestone")
                    .font(.risoBody(10, .regular))
                    .foregroundStyle(Color.risoMuted)
            )
        }
    }

    // MARK: - Stat strip

    private var statStrip: some View {
        HStack(spacing: 10) {
            statCard(label: "TODAY", value: formatCountTotal(dailyTotals.todayTotal, kind: kind))
            // P4 — build-now-feed-P4: needs a real streak rollup (window-goal
            // history); UI shipped now, wired to real data in P4.
            statCard(label: "STREAK", value: "—")
            // P4 — build-now-feed-P4: needs closed-window best-week rollup storage.
            statCard(label: "BEST WEEK", value: "—")
        }
    }

    private func statCard(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.risoHead(17, .extraBold))
                .foregroundStyle(Color.risoInk)
            Text(label)
                .font(.risoBody(9, .bold))
                .tracking(0.9)
                .foregroundStyle(Color.risoMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    // MARK: - Active members section

    @ViewBuilder
    private var activeMembersSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(activeMembers.enumerated()), id: \.element.taskId) { index, member in
                if index > 0 {
                    Divider()
                        .background(Color.risoInk.opacity(0.12))
                        .padding(.horizontal, Riso.cardPadding)
                }
                activeMemberCard(member)
            }
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .padding(.horizontal, Riso.gutter)
    }

    private func activeMemberCard(_ member: SharedCounterMemberTask) -> some View {
        let progressFraction: Double = {
            guard member.goal > 0 else { return 1 }
            return min(1.0, Double(member.logged) / Double(member.goal))
        }()

        return Button {
            if let boardId = member.boardId { onOpenBoard(boardId) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(member.timeframe?.risoColor ?? Color.risoMuted)
                        .frame(width: 9, height: 9)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(member.taskTitle)
                            .font(.risoBody(13, .bold))
                            .foregroundStyle(Color.risoInk)
                            .lineLimit(1)
                        Text(member.boardName ?? "–")
                            .font(.risoBody(11, .regular))
                            .foregroundStyle(Color.risoMuted)
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Text(SharedCounterMemberRow.loggedLabel(logged: member.logged, goal: member.goal, kind: kind))
                            .font(.risoHead(14, .bold))
                            .foregroundStyle(member.met ? Color.risoGreen : Color.risoInk)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.risoMuted)
                    }
                }

                RisoProgressBar(
                    value: progressFraction,
                    color: member.met ? .risoGreen : .risoBlue,
                    height: 6
                )

                Text(caption(for: member))
                    .font(.risoBody(10, .regular))
                    .foregroundStyle(member.met ? Color.risoGreen : Color.risoMuted)
                    .lineLimit(2)
            }
            .padding(.horizontal, Riso.cardPadding)
            .padding(.vertical, 12).contentShape(Rectangle()) // whole card (incl. the Spacer) is the tap target
        }
        .buttonStyle(.plain)
        .disabled(member.boardId == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(member.taskTitle) on \(member.boardName ?? "no board"), \(formatCountWithUnit(member.logged, kind: kind, unit: unitLabel)) of \(formatCountWithUnit(member.goal, kind: kind, unit: unitLabel)), \(caption(for: member))"
        )
    }

    /// Derives the window caption from the task's progress state. Priority:
    /// over-goal → met → in progress (with remaining count). Copy contract
    /// (R2 Counters UX refresh, parity with web `buildCaption`): "N to go ·
    /// ends {window}" — remaining-first, window as a trailing "ends" clause.
    /// `member.window` is already a formatted label (e.g. "This week",
    /// "February 2026"), never a literal day name — no day-specific phrasing
    /// is invented here (that's a P4 follow-up).
    private func caption(for member: SharedCounterMemberTask) -> String {
        if member.met, member.over > 0 {
            return "✓ Goal met · \(formatCount(member.over, kind: kind)) over"
        }
        if member.met {
            return "✓ Goal met this window"
        }
        let remaining = max(0, member.goal - member.logged)
        let base = "\(formatCountWithUnit(remaining, kind: kind, unit: unitLabel)) to go"
        guard let window = member.window else { return base }
        return "\(base) · ends \(window)"
    }

    // MARK: - Inactive members section

    @ViewBuilder
    private var inactiveMembersSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(inactiveMembers.enumerated()), id: \.element.taskId) { index, member in
                if index > 0 {
                    Divider()
                        .background(Color.risoInk.opacity(0.12))
                        .padding(.horizontal, Riso.cardPadding)
                }
                inactiveMemberRow(member)
            }
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .padding(.horizontal, Riso.gutter)
    }

    private func inactiveMemberRow(_ member: SharedCounterMemberTask) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.risoMuted.opacity(0.35))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(member.taskTitle)
                    .font(.risoBody(13, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
            }

            Spacer()

            Text(SharedCounterMemberRow.loggedLabel(logged: member.logged, goal: member.goal, kind: kind))
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted)
        }
        .padding(.horizontal, Riso.cardPadding)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(member.taskTitle), not counting now")
    }

    // MARK: - Section label

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .risoSectionLabel()
            .padding(.horizontal, Riso.gutter)
            .padding(.bottom, 8)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Counter Detail — populated") {
    let srcMember = SharedCounterMemberTask(
        taskId: "src",
        taskTitle: "Push-ups",
        isSource: true,
        boardId: "bm",
        boardName: "February Fitness",
        timeframe: .monthly,
        window: "February 2026",
        goal: 1000,
        logged: 512,
        met: false,
        over: 0,
        isActive: true
    )
    let weekMember = SharedCounterMemberTask(
        taskId: "der1",
        taskTitle: "Push-ups",
        isSource: false,
        boardId: "bw",
        boardName: "Week 5 Wellness",
        timeframe: .weekly,
        window: "Week of Feb 3 – 9, 2026",
        goal: 30,
        logged: 45,
        met: true,
        over: 15,
        isActive: true
    )
    let inactiveMember = SharedCounterMemberTask(
        taskId: "der2",
        taskTitle: "Push-ups",
        isSource: false,
        boardId: nil,
        boardName: nil,
        timeframe: .daily,
        window: nil,
        goal: 10,
        logged: 0,
        met: false,
        over: 0,
        isActive: false
    )
    let group = SharedCounterGroup(
        counterId: "src",
        name: "Push-ups",
        action: "Do",
        unit: "reps",
        lifetime: 512,
        defaultLogAmount: 10,
        tasks: [srcMember, weekMember, inactiveMember],
        taskCount: 3,
        boardCount: 2,
        activeTaskCount: 2
    )
    let dailyTotals = CounterDailyTotalsResult(
        days: [
            CounterDailyTotal(dateISO: "2026-01-26", total: 12),
            CounterDailyTotal(dateISO: "2026-01-27", total: 0),
            CounterDailyTotal(dateISO: "2026-01-28", total: 30),
            CounterDailyTotal(dateISO: "2026-01-29", total: 8),
            CounterDailyTotal(dateISO: "2026-01-30", total: 15),
            CounterDailyTotal(dateISO: "2026-01-31", total: 20),
            CounterDailyTotal(dateISO: "2026-02-01", total: 10),
        ],
        todayTotal: 10
    )
    NavigationStack {
        CounterDetailContent(group: group, dailyTotals: dailyTotals)
    }
}

#Preview("Counter Detail — empty / 0 lifetime") {
    let src = SharedCounterMemberTask(
        taskId: "src",
        taskTitle: "Morning runs",
        isSource: true,
        boardId: "b1",
        boardName: "April Running",
        timeframe: .monthly,
        window: "April 2026",
        goal: 20,
        logged: 0,
        met: false,
        over: 0,
        isActive: true
    )
    let group = SharedCounterGroup(
        counterId: "src",
        name: "Morning runs",
        action: "Go for",
        unit: "runs",
        lifetime: 0,
        tasks: [src],
        taskCount: 1,
        boardCount: 1,
        activeTaskCount: 1
    )
    NavigationStack {
        CounterDetailContent(group: group)
    }
}
#endif
