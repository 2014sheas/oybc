import SwiftUI

// MARK: - CountersHubView (container)

/// Profile sub-page — "Shared counters" (Shared Counters P1).
///
/// Thin env-bound container: fetches all tasks + boardTasks + boards once on
/// appear, builds the read model via `buildSharedCounterGroups`, then hands
/// plain-value props to `CountersHubContent`.
///
/// Design: Ledger layout only (Tiles / Meters are prototype alternates, deferred).
/// Each counter = one `SharedCounterLedgerCard`; tapping pushes `CounterDetailView`.
struct CountersHubView: View {

    @EnvironmentObject var authService: AuthService

    // MARK: - Private state

    @State private var groups: [SharedCounterGroup] = []
    @State private var isLoaded = false

    // MARK: - Body

    var body: some View {
        CountersHubContent(groups: groups, isLoaded: isLoaded)
            .navigationBarHidden(true)
            .onAppear { loadData() }
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
                isLoaded = true
            }
        }
    }
}

// MARK: - CountersHubContent (pure-props leaf, snapshot-testable)

/// Pure presentational leaf for the Shared Counters hub.
/// No environment, no DB, no Firebase — receives plain values.
struct CountersHubContent: View {

    let groups: [SharedCounterGroup]
    var isLoaded: Bool = true

    var body: some View {
        ZStack {
            RisoPaperBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    RisoSubPageHeader(title: "Shared counters")
                        .padding(.top, 16)
                        .padding(.bottom, 20)

                    // Intro paragraph
                    Text("One activity, one running tally. Log **push-ups** on any board and every task that counts push-ups moves — each keeping its own start and finish.")
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

                    // Footer note
                    Text("Counters are shared automatically — tasks with the same activity and unit link up on their own.")
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.top, 20)
                        .padding(.bottom, 32)
                }
            }
        }
    }

    // MARK: - Ledger section

    @ViewBuilder
    private var ledgerSection: some View {
        VStack(spacing: 14) {
            ForEach(groups) { group in
                NavigationLink {
                    CounterDetailView(counterId: group.counterId)
                } label: {
                    SharedCounterLedgerCard(group: group) { }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Riso.gutter)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.risoMuted.opacity(0.5))
            Text("No shared counters yet")
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoMuted)
            Text("Link counting tasks to a shared counter to see them here.")
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted.opacity(0.7))
                .multilineTextAlignment(.center)
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
        tasks: [src, der],
        taskCount: 2,
        boardCount: 2,
        activeTaskCount: 2
    )
    return NavigationStack {
        CountersHubContent(groups: [group])
    }
}

#Preview("Counters Hub — empty") {
    NavigationStack {
        CountersHubContent(groups: [])
    }
}
#endif
