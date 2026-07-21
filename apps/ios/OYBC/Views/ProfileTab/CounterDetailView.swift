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
///   4. Log card (blue fill) — amount chips (1 / default / 25 / #) + −/+Add N.
///      Logging updates the counter's `defaultLogAmount` to the amount just
///      used and shows the reusable `CounterLogToastView` ("Logged +N · Undo").
///   5. Explainer line.
///   6. "Counting on N tasks" — active member cards.
///   7. "Recent weeks" — STUB history card.
///   8. "Not counting now" — inactive members greyed.
///   9. Delete — quiet red text link (was a filled `RisoButton`).
struct CounterDetailView: View {

    let counterId: String

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
                    onDeleteTap: handleDeleteTap
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
        _Concurrency.Task.detached(priority: .userInitiated) {
            let tasks = (try? AppDatabase.shared.fetchTasks(userId: userId)) ?? []
            let boards = (try? AppDatabase.shared.fetchBoards(userId: userId)) ?? []
            let boardTasks = (try? AppDatabase.shared.fetchAllBoardTasks()) ?? []
            let groups = buildSharedCounterGroups(tasks: tasks, boardTasks: boardTasks, boards: boards)
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
    private func handleLog(amount: Int, direction: CounterLogDirection) {
        guard !isLogging, amount > 0, let group else { return }
        isLogging = true
        logError = nil
        let id = counterId
        let unit = group.unit ?? ""
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                switch direction {
                case .add:
                    _ = try AppDatabase.shared.incrementSharedCounter(sourceTaskId: id, by: amount)
                case .remove:
                    // decrementSharedCounter clamps to 0 itself — no additional guard needed.
                    _ = try AppDatabase.shared.decrementSharedCounter(sourceTaskId: id, by: amount)
                }
                // The amount just used becomes the new default (no-op if unchanged).
                try AppDatabase.shared.setCounterDefaultLogAmount(sourceTaskId: id, amount: amount)
                await MainActor.run {
                    isLogging = false
                    toast = DetailToastState(
                        amount: amount, unit: unit,
                        verb: direction == .add ? .logged : .removed,
                        toastKey: UUID().uuidString
                    )
                    loadData()
                }
            } catch {
                await MainActor.run {
                    isLogging = false
                    logError = "Failed to log. Try again."
                }
            }
        }
    }

    private func handleUndo() {
        let id = counterId
        _Concurrency.Task.detached(priority: .userInitiated) {
            _ = try? AppDatabase.shared.undoLastCounterLog(sourceTaskId: id)
            await MainActor.run {
                toast = nil
                loadData()
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
    let amount: Int
    let unit: String
    let verb: CounterLogToastView.Verb
    let toastKey: String
}

// MARK: - CounterDetailContent (pure-props leaf, snapshot-testable)

/// Pure presentational leaf for the Counter Detail page.
/// No environment, no DB, no Firebase — receives plain values. Owns its own
/// amount-chip selection UI state (not tied to the DB), seeded once from
/// `group.defaultLogAmount` on first appearance — mirrors web's
/// `initializedForRef` guard (sync the chip selection to the counter's
/// current default exactly once per counter, NOT on every live reload, so a
/// background `defaultLogAmount` write from this very session's own log
/// doesn't clobber the user's in-progress chip selection).
struct CounterDetailContent: View {

    let group: SharedCounterGroup
    var dailyTotals: CounterDailyTotalsResult
    var isLogging: Bool
    var logError: String?
    /// Surfaced when a delete attempt fails — the confirm sheet has already
    /// closed by the time this is shown (mirrors web's close-dialog-on-error
    /// pattern), so it renders on this page itself.
    var deleteError: String?
    var onLog: (Int, CounterLogDirection) -> Void
    /// Fired by the "⋯" overflow menu's "Delete counter…" item AND the
    /// footer's red text link — the container computes the deletion impact
    /// and shows the confirm sheet.
    var onDeleteTap: () -> Void

    @State private var selectedAmount: Int
    @State private var isCustomActive = false
    @State private var customOpen = false
    @State private var customDraft = ""

    init(
        group: SharedCounterGroup,
        dailyTotals: CounterDailyTotalsResult = CounterDailyTotalsResult(days: [], todayTotal: 0),
        isLogging: Bool = false,
        logError: String? = nil,
        deleteError: String? = nil,
        initialSelectedAmount: Int? = nil,
        /// Snapshot-testability seam: forces the "#" custom chip into its
        /// selected (gold, showing the live amount) state without requiring
        /// a real tap sequence. Production call sites never pass this.
        initialCustomActive: Bool = false,
        onLog: @escaping (Int, CounterLogDirection) -> Void = { _, _ in },
        onDeleteTap: @escaping () -> Void = {}
    ) {
        self.group = group
        self.dailyTotals = dailyTotals
        self.isLogging = isLogging
        self.logError = logError
        self.deleteError = deleteError
        self.onLog = onLog
        self.onDeleteTap = onDeleteTap
        _selectedAmount = State(initialValue: initialSelectedAmount ?? group.defaultLogAmount ?? 1)
        _isCustomActive = State(initialValue: initialCustomActive)
    }

    // MARK: - Derived

    private var unitLabel: String { group.unit ?? "" }

    private var activeMembers: [SharedCounterMemberTask] {
        group.tasks.filter { $0.isActive }
    }

    private var inactiveMembers: [SharedCounterMemberTask] {
        group.tasks.filter { !$0.isActive }
    }

    private var milestoneProgress: CounterMilestoneProgress {
        counterMilestoneProgress(group.lifetime)
    }

    private struct AmountChipOption {
        /// `nil` marks the trailing custom "#" chip.
        let value: Int?
        let label: String

        /// Keep-first dedupe by `value` (custom `nil` chip always kept) —
        /// mirrors web `amountChips.dedupeChips`. A fresh counter's default
        /// of 1 (or a default of 25 on Detail) would otherwise duplicate a
        /// fixed chip (device-testing feedback, R3).
        static func dedupingValues(_ chips: [AmountChipOption]) -> [AmountChipOption] {
            var seen = Set<Int>()
            return chips.filter { chip in
                guard let value = chip.value else { return true }
                return seen.insert(value).inserted
            }
        }
    }

    private var chips: [AmountChipOption] {
        let defaultAmount = group.defaultLogAmount ?? 1
        // Keep-first dedupe — see AmountChipOption.dedupingValues (a default
        // of 1 or 25 would otherwise duplicate a fixed chip).
        return AmountChipOption.dedupingValues([
            AmountChipOption(value: 1, label: "1"),
            AmountChipOption(value: defaultAmount, label: "\(defaultAmount)"),
            AmountChipOption(value: 25, label: "25"),
            AmountChipOption(value: nil, label: "#"),
        ])
    }

    private var selectedChipIndex: Int? {
        if isCustomActive { return chips.count - 1 }
        return chips.firstIndex(where: { $0.value == selectedAmount })
    }

    // MARK: - Chip actions

    private func selectChip(_ value: Int) {
        selectedAmount = value
        isCustomActive = false
        customOpen = false
    }

    private func openCustomInput() {
        customDraft = isCustomActive ? "\(selectedAmount)" : ""
        customOpen = true
    }

    private func confirmCustomInput() {
        // R3: validation extracted to `CounterLogAmount.parseCustom` so
        // `RisoCountingStepperSheet`'s board-play "#" chip shares the same rule.
        guard let parsed = CounterLogAmount.parseCustom(customDraft) else { return }
        selectedAmount = parsed
        isCustomActive = true
        customOpen = false
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

                // 3. Log card (amount chips + −/+Add N)
                logCard
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 10)

                // 4. Explainer
                Text("Logged \(unitLabel) count toward every active task and your all-time total.")
                    .font(.risoBody(11, .regular))
                    .foregroundStyle(Color.risoMuted)
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 18)

                // 5. "Counting on N tasks" (active members)
                if !activeMembers.isEmpty {
                    sectionLabel("Counting on \(activeMembers.count) task\(activeMembers.count == 1 ? "" : "s")")
                    activeMembersSection
                        .padding(.bottom, 14)
                }

                // 6. "Recent weeks" — P4 stub
                sectionLabel("Recent weeks")
                recentWeeksCard
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 14)

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
                    Text(group.lifetime.formatted())
                        .font(.risoHead(46, .extraBold))
                        .foregroundStyle(Color.risoBlue)
                        .monospacedDigit()
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                    Text("all-time \(unitLabel)")
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
        .accessibilityLabel("\(group.name), \(group.lifetime) all-time \(unitLabel)")
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
                let heightFraction = max(0.06, Double(day.total) / Double(maxDaily))
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
        .accessibilityLabel("7-day activity — today \(dailyTotals.todayTotal.formatted()) \(unitLabel)")
    }

    private var milestoneBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            RisoProgressBar(value: milestoneProgress.fraction, color: .risoBlue, height: 8)
            (
                Text("\(milestoneProgress.remaining.formatted()) to ")
                    .font(.risoBody(10, .regular))
                    .foregroundStyle(Color.risoMuted)
                + Text(milestoneProgress.next.formatted())
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
            statCard(label: "TODAY", value: dailyTotals.todayTotal.formatted())
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

    // MARK: - Log card

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Log \(unitLabel)")
                    .font(.risoHead(15, .extraBold))
                    .foregroundStyle(Color.risoPaper)
                Text("counts toward \(activeMembers.count) active task\(activeMembers.count == 1 ? "" : "s")")
                    .font(.risoBody(11, .regular))
                    .foregroundStyle(Color.risoPaper.opacity(0.85))
            }

            chipRow

            if customOpen {
                customInputRow
            }

            logActionsRow

            if let logError {
                Text(logError)
                    .font(.risoBody(11, .regular))
                    .foregroundStyle(Color.risoPaper.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Riso.cardPadding)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoBlue))
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
        .risoHardShadow(Riso.Shadow.card, radius: Riso.cardRadius)
    }

    /// Amount chip row: 1 / {default} / 25 / # — selected = gold fill +
    /// `risoInkStatic` (dark-mode-safe content on gold); idle = transparent
    /// with an on-color (`risoPaper`) border/text (content-on-blue-fill
    /// contract).
    private var chipRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                let isSelected = index == selectedChipIndex
                Button {
                    if let value = chip.value {
                        selectChip(value)
                    } else {
                        openCustomInput()
                    }
                } label: {
                    Text(chip.value == nil && isSelected ? "\(selectedAmount)" : chip.label)
                        .font(.risoHead(13, .extraBold))
                        .foregroundStyle(isSelected ? Color.risoInkStatic : Color.risoPaper)
                        .frame(minWidth: 40)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(isSelected ? Color.risoGold : Color.clear))
                        .overlay(
                            Capsule().strokeBorder(
                                isSelected ? Color.risoInk : Color.risoPaper.opacity(0.6),
                                lineWidth: Riso.Keyline.dense
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    private var customInputRow: some View {
        HStack(spacing: 8) {
            RisoNumberField(placeholder: "Amount", text: $customDraft)
            Button("OK", action: confirmCustomInput)
                .font(.risoHead(13, .extraBold))
                .foregroundStyle(Color.risoInkStatic)
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(Capsule().fill(Color.risoGold))
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                .disabled(CounterLogAmount.parseCustom(customDraft) == nil)
                .opacity(CounterLogAmount.parseCustom(customDraft) == nil ? 0.5 : 1)
        }
    }

    private var logActionsRow: some View {
        HStack(spacing: 12) {
            Button {
                onLog(selectedAmount, .remove)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.risoPaper)
                    .frame(width: 52, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .strokeBorder(Color.risoPaper.opacity(0.7), lineWidth: Riso.Keyline.dense)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isLogging || group.lifetime == 0)
            .accessibilityLabel("Remove \(selectedAmount) \(unitLabel)")

            Button {
                onLog(selectedAmount, .add)
            } label: {
                HStack(spacing: 6) {
                    if isLogging {
                        ProgressView()
                            .tint(Color.risoInkStatic)
                            .scaleEffect(0.85)
                    }
                    Text("＋ Add \(selectedAmount)")
                        .font(.risoHead(15, .extraBold))
                }
                .foregroundStyle(Color.risoInkStatic)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                )
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small))
            .disabled(isLogging)
            .accessibilityLabel("Add \(selectedAmount) \(unitLabel)")
        }
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

        return NavigationLink {
            if let boardId = member.boardId {
                BoardPlayView(boardId: boardId)
            }
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
                        Text("\(member.logged.formatted())/\(member.goal.formatted())")
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
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .disabled(member.boardId == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(member.taskTitle) on \(member.boardName ?? "no board"), \(member.logged) of \(member.goal) \(unitLabel), \(caption(for: member))"
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
            return "✓ Goal met · \(member.over.formatted()) over"
        }
        if member.met {
            return "✓ Goal met this window"
        }
        let remaining = max(0, member.goal - member.logged)
        let base = "\(remaining.formatted()) \(unitLabel) to go"
        guard let window = member.window else { return base }
        return "\(base) · ends \(window)"
    }

    // MARK: - Recent weeks (P4 stub)

    private var recentWeeksCard: some View {
        // P4 — build-now-feed-P4: needs closed-window history storage; UI
        // shipped now (this card), real rows land in P4.
        Text("Weekly history will appear here once you've logged for a few weeks.")
            .font(.risoBody(12, .regular))
            .foregroundStyle(Color.risoMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Riso.cardPadding)
            .risoCard()
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
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
                Text(member.boardId == nil
                     ? "Not on any board yet — log from here anytime."
                     : "Starts counting when this board goes live.")
                    .font(.risoBody(10, .regular))
                    .foregroundStyle(Color.risoMuted.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            Text("\(member.logged.formatted())/\(member.goal.formatted())")
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

// MARK: - CounterDeleteConfirmView

/// Destructive confirm sheet for deleting a shared-counter source (P5
/// decision 8: `deleteCounterWithUnlink`). iOS twin of web's
/// `CounterDeleteConfirmDialog` — copy is VERBATIM per CLAUDE.md
/// cross-platform parity rule.
///
/// Structurally mirrors `TaskDeleteConfirmView` (NavigationStack +
/// `.presentationDetents([.medium])` + a gold-toolbar Cancel/red-toolbar
/// destructive-confirm pill) rather than the simpler `.alert` `TaskDetailView`
/// uses elsewhere — the member-unlink list needs a scrollable custom body,
/// which `.alert` can't host and `.confirmationDialog` / `swipeActions`
/// (crash trap — see repo memory) can't either.
///
/// Deleting a source UNLINKS its live members (each keeps its current count
/// as an independent standalone counter) rather than cascade-deleting them —
/// distinct from the ordinary task-delete cascade `TaskDeleteConfirmView` shows.
struct CounterDeleteConfirmView: View {
    let group: SharedCounterGroup
    let impact: AppDatabase.TaskDeletionImpact
    var isDeleting: Bool = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var hasMembers: Bool { impact.counterMemberCount > 0 }

    private func boardName(for memberId: String) -> String? {
        group.tasks.first(where: { $0.taskId == memberId })?.boardName
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    Text("'\(group.name)' and its lifetime total will be deleted.")
                        .font(.risoBody(14, .semibold))
                        .foregroundStyle(Color.risoInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(13)
                        .risoCard(fill: .risoPaper2)
                        .risoHardShadow(Riso.Shadow.small)

                    if hasMembers {
                        membersSection
                    }
                }
                .padding(Riso.gutter)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Delete counter?")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .disabled(isDeleting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    RisoToolbarPill(
                        title: hasMembers
                            ? "Delete counter & unlink \(impact.counterMemberCount) tasks"
                            : "Delete counter",
                        fill: .risoRed,
                        foreground: .risoPaper
                    ) {
                        onConfirm()
                    }
                    .disabled(isDeleting)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Members section

    @ViewBuilder
    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(impact.counterMemberCount) linked task\(impact.counterMemberCount == 1 ? "" : "s") will be unlinked and keep their current counts:")
                .risoSectionLabel()

            VStack(spacing: 7) {
                ForEach(impact.counterMembers, id: \.id) { member in
                    memberRow(member)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.small)
    }

    private func memberRow(_ member: Task) -> some View {
        HStack(spacing: 8) {
            Text(member.title)
                .font(.risoHead(13, .bold))
                .foregroundStyle(Color.risoInk)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let boardName = boardName(for: member.id) {
                Text(boardName)
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Riso.cellRadius)
                .fill(Color.risoPaper)
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cellRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                )
        )
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

#Preview("Delete counter — confirm sheet") {
    let src = SharedCounterMemberTask(
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
    let group = SharedCounterGroup(
        counterId: "src",
        name: "Push-ups",
        action: "Do",
        unit: "reps",
        lifetime: 512,
        tasks: [src],
        taskCount: 1,
        boardCount: 1,
        activeTaskCount: 1
    )
    let now = "2026-02-01T00:00:00.000"
    let member = Task(
        id: "der1", userId: "u1", title: "Push-ups", type: .counting,
        action: "Do", unit: "reps",
        totalCompletions: 0, totalInstances: 0,
        currentCount: 45,
        createdAt: now, updatedAt: now,
        version: 1, isDeleted: false
    )
    let impact = AppDatabase.TaskDeletionImpact(
        boardTaskCount: 1,
        affectedBoardIds: ["bm"],
        affectedBoards: [],
        childLinkCount: 0,
        parentLinkCount: 0,
        counterMemberCount: 1,
        counterMembers: [member]
    )
    CounterDeleteConfirmView(
        group: group,
        impact: impact,
        onConfirm: {},
        onCancel: {}
    )
}
#endif
