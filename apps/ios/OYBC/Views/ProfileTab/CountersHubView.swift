import SwiftUI

// MARK: - CountersHubView (container)

/// Profile sub-page — "Counters" (Shared Counters P1, R2 Counters UX refresh).
///
/// Thin env-bound container: fetches all tasks + boardTasks + boards once on
/// appear, builds the read model via `buildSharedCounterGroups`, then hands
/// plain-value props to `CountersHubContent`. Also owns the one-tap "+ Log"
/// pill's write + the shared `CounterLogToastView`/Undo flow — the toast is
/// page-level (only one lives at a time), so it's owned here rather than by
/// the leaf card.
///
/// Design (R2 Counters UX refresh — design handoff §Counters Hub): Ledger
/// layout only (Tiles / Meters are prototype alternates, deferred). Each
/// counter = one `SharedCounterLedgerCard`; tapping the card pushes
/// `CounterDetailView`, tapping its "+ Log" pill logs in place.
struct CountersHubView: View {

    @EnvironmentObject var authService: AuthService

    // MARK: - Private state

    @State private var groups: [SharedCounterGroup] = []
    @State private var isLoaded = false
    @State private var tasksForDedupe: [OYBC.Task] = []

    /// Counter ids with an in-flight "+ Log" write — disables that card's pill.
    @State private var loggingCounterIds: Set<String> = []
    @State private var toast: HubToastState?

    /// "+ New counter" sheet presentation (P5). `deleteImpact`-style Binding
    /// derivation isn't needed here — the sheet always dismisses via either
    /// Cancel or a successful create/promote/view-counter callback.
    @State private var isNewCounterSheetPresented = false
    /// Set by the sheet's `onNavigateToCounter` callback (create success,
    /// promote success, or an established match's "View counter" tap) OR by
    /// a direct ledger-card tap — drives the push to `CounterDetailView`.
    @State private var navigateToCounterId: String? = nil

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            CountersHubContent(
                groups: groups,
                isLoaded: isLoaded,
                loggingCounterIds: loggingCounterIds,
                onNewCounter: { isNewCounterSheetPresented = true },
                onOpenDetail: { counterId in navigateToCounterId = counterId },
                onLog: { group in handleLog(group: group) }
            )

            if let toast {
                CounterLogToastView(
                    amount: toast.amount,
                    unit: toast.unit,
                    verb: toast.verb,
                    onUndo: { handleUndo(counterId: toast.counterId) },
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
        .sheet(isPresented: $isNewCounterSheetPresented, onDismiss: { loadData() }) {
            if let userId = authService.currentUser?.id {
                NewCounterSheetView(
                    userId: userId,
                    tasks: tasksForDedupe,
                    onNavigateToCounter: { counterId in
                        isNewCounterSheetPresented = false
                        navigateToCounterId = counterId
                    }
                )
            }
        }
        .navigationDestination(item: $navigateToCounterId) { counterId in
            CounterDetailView(counterId: counterId)
        }
    }

    // MARK: - Data loading

    private func loadData() {
        guard let userId = authService.currentUser?.id else { return }
        _Concurrency.Task.detached(priority: .userInitiated) {
            let tasks = (try? AppDatabase.shared.fetchTasks(userId: userId)) ?? []
            let boards = (try? AppDatabase.shared.fetchBoards(userId: userId)) ?? []
            let boardTasks = (try? AppDatabase.shared.fetchAllBoardTasks()) ?? []
            let result = buildSharedCounterGroups(tasks: tasks, boardTasks: boardTasks, boards: boards)
            await MainActor.run {
                groups = result
                tasksForDedupe = tasks
                isLoaded = true
            }
        }
    }

    // MARK: - "+ Log" pill

    private func handleLog(group: SharedCounterGroup) {
        guard !loggingCounterIds.contains(group.counterId) else { return }
        let amount = group.defaultLogAmount ?? 1
        let counterId = group.counterId
        let unit = group.unit ?? ""
        loggingCounterIds.insert(counterId)
        _Concurrency.Task.detached(priority: .userInitiated) {
            _ = try? AppDatabase.shared.incrementSharedCounter(sourceTaskId: counterId, by: amount)
            await MainActor.run {
                loggingCounterIds.remove(counterId)
                toast = HubToastState(
                    counterId: counterId, amount: amount, unit: unit,
                    verb: .logged, toastKey: UUID().uuidString
                )
                loadData()
            }
        }
    }

    private func handleUndo(counterId: String) {
        _Concurrency.Task.detached(priority: .userInitiated) {
            _ = try? AppDatabase.shared.undoLastCounterLog(sourceTaskId: counterId)
            await MainActor.run {
                toast = nil
                loadData()
            }
        }
    }
}

/// Page-level toast state for the Counters Hub's "+ Log" pill / Undo flow.
private struct HubToastState {
    let counterId: String
    let amount: Int
    let unit: String
    let verb: CounterLogToastView.Verb
    let toastKey: String
}

// MARK: - CountersHubContent (pure-props leaf, snapshot-testable)

/// Pure presentational leaf for the Shared Counters hub.
/// No environment, no DB, no Firebase — receives plain values.
struct CountersHubContent: View {

    let groups: [SharedCounterGroup]
    var isLoaded: Bool = true
    var loggingCounterIds: Set<String> = []
    /// Fired by the header's trailing button (and the empty-state CTA) to
    /// open the "+ New counter" sheet. Defaults to a no-op so previews and
    /// other non-interactive callers don't need to supply one.
    var onNewCounter: () -> Void = {}
    /// Fired by a card tap (anywhere except its "+ Log" pill) with the
    /// tapped counter's id.
    var onOpenDetail: (String) -> Void = { _ in }
    /// Fired by a card's "+ Log" pill.
    var onLog: (SharedCounterGroup) -> Void = { _ in }

    var body: some View {
        ZStack {
            RisoPaperBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    // Header row — "New counter" hides entirely when the
                    // list is empty (design handoff §Counters Hub).
                    HStack(spacing: 8) {
                        RisoSubPageHeader(title: "Counters")
                        if !groups.isEmpty {
                            RisoButton(title: "New counter", kind: .blue, small: true) {
                                onNewCounter()
                            }
                            .padding(.trailing, Riso.gutter)
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 20)

                    // Intro (one line)
                    Text("One tally per activity — every task counting it moves together.")
                        .font(.risoBody(13, .regular))
                        .foregroundStyle(Color.risoInk)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 20)

                    if isLoaded {
                        if groups.isEmpty {
                            emptyState
                        } else {
                            ledgerSection
                        }
                    } else {
                        // Loading placeholder — same card height as content.
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }

                    Spacer(minLength: 32)
                }
            }
        }
    }

    // MARK: - Ledger section

    @ViewBuilder
    private var ledgerSection: some View {
        VStack(spacing: 14) {
            ForEach(groups) { group in
                SharedCounterLedgerCard(
                    group: group,
                    isLogging: loggingCounterIds.contains(group.counterId),
                    onOpenDetail: { onOpenDetail(group.counterId) },
                    onLog: { onLog(group) }
                )
                .padding(.horizontal, Riso.gutter)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("↔")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.risoMuted.opacity(0.5))
            Text("No counters yet")
                .font(.risoHead(18, .extraBold))
                .foregroundStyle(Color.risoInk)
            Text("Track one activity — push-ups, pages, miles — across every board it appears on.")
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted)
                .multilineTextAlignment(.center)
            RisoButton(title: "+ New counter", kind: .blue, small: true) {
                onNewCounter()
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, Riso.gutter)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Counters Hub — populated") {
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
    let der = SharedCounterMemberTask(
        taskId: "der",
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
    let group = SharedCounterGroup(
        counterId: "src",
        name: "Push-ups",
        action: "Do",
        unit: "reps",
        lifetime: 512,
        defaultLogAmount: 10,
        tasks: [src, der],
        taskCount: 2,
        boardCount: 2,
        activeTaskCount: 2
    )
    NavigationStack {
        CountersHubContent(groups: [group])
    }
}

#Preview("Counters Hub — empty") {
    NavigationStack {
        CountersHubContent(groups: [])
    }
}
#endif
