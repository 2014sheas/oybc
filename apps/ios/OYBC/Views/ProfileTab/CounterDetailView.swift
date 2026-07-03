import SwiftUI

// MARK: - CounterDetailView (container)

/// Profile sub-page — one shared counter's home (Shared Counters P1 + P2).
///
/// Container: loads fresh data on appear/after log, resolves the group from
/// `buildSharedCounterGroups`, then renders `CounterDetailContent`.
///
/// MVP sections (per docs/SHARED_COUNTERS.md P1):
///   1. Hero: action/unit tag + lifetime hero + optional milestone bar.
///   2. Log control: "Log {name}" + ±1 stepper (increment + decrement wired in P2).
///   3. "Appears on" timeframe chips.
///   4. "Shared by N tasks" — one card per active member (tappable → board).
///   5. "Not counting now" — inactive members greyed.
///
/// Deferred (leave seams):
///   - P4: 7-day sparkline, streak, best-window, recent-windows history.
struct CounterDetailView: View {

    let counterId: String

    @EnvironmentObject var authService: AuthService

    // MARK: - Private state

    @State private var group: SharedCounterGroup?
    @State private var isLoaded = false
    @State private var isLogging = false
    @State private var logError: String?

    // MARK: - Body

    var body: some View {
        ZStack {
            RisoPaperBackground()

            if let group {
                CounterDetailContent(
                    group: group,
                    isLogging: isLogging,
                    logError: logError,
                    onIncrement: { handleIncrement(group: group) },
                    onDecrement: { handleDecrement(group: group) },
                    onNavigateToBoard: { _ in /* routed via NavigationLink in content */ }
                )
            } else if isLoaded {
                notFoundState
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
            let groups = buildSharedCounterGroups(tasks: tasks, boardTasks: boardTasks, boards: boards)
            let found = groups.first { $0.counterId == counterId }
            await MainActor.run {
                group = found
                isLoaded = true
            }
        }
    }

    // MARK: - Log increment

    private func handleIncrement(group: SharedCounterGroup) {
        guard !isLogging else { return }
        isLogging = true
        logError = nil
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                _ = try AppDatabase.shared.incrementSharedCounter(sourceTaskId: group.counterId, by: 1)
                await MainActor.run {
                    isLogging = false
                    loadData() // reload to reflect new lifetime
                }
            } catch {
                await MainActor.run {
                    isLogging = false
                    logError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Log decrement (P2)

    /// Decrements the source counter by 1. Silent no-op when `group.lifetime == 0`
    /// (the engine also clamps via `eff = min(by, source.currentCount)`).
    private func handleDecrement(group: SharedCounterGroup) {
        guard !isLogging else { return }
        guard group.lifetime > 0 else { return }  // fast-path guard; engine also clamps
        isLogging = true
        logError = nil
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                _ = try AppDatabase.shared.decrementSharedCounter(sourceTaskId: group.counterId, by: 1)
                await MainActor.run {
                    isLogging = false
                    loadData()
                }
            } catch {
                await MainActor.run {
                    isLogging = false
                    logError = error.localizedDescription
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

// MARK: - CounterDetailContent (pure-props leaf, snapshot-testable)

/// Pure presentational leaf for the Counter Detail page.
/// No environment, no DB, no Firebase — receives plain values.
struct CounterDetailContent: View {

    let group: SharedCounterGroup
    var isLogging: Bool = false
    var logError: String? = nil
    var onIncrement: () -> Void = {}
    var onDecrement: () -> Void = {}
    var onNavigateToBoard: (String) -> Void = { _ in }

    // MARK: - Derived

    private var unitLabel: String { group.unit ?? "units" }

    private var activeMembers: [SharedCounterMemberTask] {
        group.tasks.filter { $0.isActive }
    }

    private var inactiveMembers: [SharedCounterMemberTask] {
        group.tasks.filter { !$0.isActive }
    }

    private var distinctTimeframes: [Timeframe] {
        var seen = Set<Timeframe>()
        return group.tasks.compactMap { m -> Timeframe? in
            guard let tf = m.timeframe, !seen.contains(tf) else { return nil }
            seen.insert(tf)
            return tf
        }
    }

    // Milestone: next round number above lifetime. Mirrors `cnNextMilestone`
    // in the prototype (and web `nextMilestone`) exactly — same step list +
    // the same "next 10k multiple" fallback past the top step.
    private var milestone: Int? {
        let steps = [100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000]
        if let next = steps.first(where: { $0 > group.lifetime }) { return next }
        return (group.lifetime / 10000 + 1) * 10000
    }

    private var milestoneFraction: Double {
        guard let ms = milestone, ms > 0 else { return 1 }
        // Progress from zero toward the next milestone (prototype: lifetime / nextMs).
        return min(1.0, Double(group.lifetime) / Double(ms))
    }

    // MARK: - Body

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                RisoSubPageHeader(title: group.name)
                    .padding(.top, 16)
                    .padding(.bottom, 20)

                // 1. Hero card
                heroCard
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 14)

                // P4: sparkline slot — leave seam
                // P4: stat strip (streak + best window) — leave seam

                // 2. Log control card
                logCard
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 14)

                // 3. "Appears on" timeframe chips
                if !distinctTimeframes.isEmpty {
                    appearsOnSection
                        .padding(.bottom, 18)
                }

                // 4. "Shared by N tasks" (active members)
                if !activeMembers.isEmpty {
                    sectionLabel("Shared by \(activeMembers.count) task\(activeMembers.count == 1 ? "" : "s")")
                    activeMembersSection
                        .padding(.bottom, 14)
                }

                // 5. "Not counting now" (inactive members)
                if !inactiveMembers.isEmpty {
                    sectionLabel("Not counting now")
                    inactiveMembersSection
                        .padding(.bottom, 14)
                }

                // P4: "Recent windows" history — leave seam
                // P4: seam: import the closed-window history rows here once
                //     P4 data storage lands (per-day / per-window increment log).

                Spacer(minLength: 24)
            }
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tag row: "Do · reps" + "Shared counter" label
            HStack(spacing: 8) {
                if let action = group.action {
                    Text("\(action) · \(unitLabel)")
                        .font(.risoHead(11, .bold))
                        .tracking(0.3)
                        .foregroundStyle(Color.risoMuted)
                }
                Spacer()
                Text("Shared counter")
                    .font(.risoHead(10, .bold))
                    .tracking(0.35)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.risoPaper)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(Color.risoBlue))
                    .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            }
            .padding(.horizontal, Riso.cardPadding)
            .padding(.top, Riso.cardPadding)

            // Huge blue lifetime number
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(group.lifetime)")
                    .font(.risoHead(52, .extraBold))
                    .foregroundStyle(Color.risoBlue)
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                Text("all-time \(unitLabel)")
                    .font(.risoHead(15, .bold))
                    .foregroundStyle(Color.risoMuted)
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, Riso.cardPadding)
            .padding(.top, 6)

            // Milestone bar (optional)
            if let ms = milestone {
                milestoneBar(toward: ms)
                    .padding(.horizontal, Riso.cardPadding)
                    .padding(.top, 10)
            }

            // P4: sparkline (7-day trend) — seam
            // P4 seam: insert `SparklineView` here once the per-day increment
            //          log lands. The `recent: [Int]` array from the handoff
            //          comes from a new P4 aggregation query.

            Spacer().frame(height: Riso.cardPadding)
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name), \(group.lifetime) all-time \(unitLabel)")
    }

    private func milestoneBar(toward ms: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RisoProgressBar(value: milestoneFraction, color: .risoBlue, height: 7)
            Text("\(ms - group.lifetime) \(unitLabel) to \(ms)")
                .font(.risoBody(10, .regular))
                .foregroundStyle(Color.risoMuted)
        }
    }

    // MARK: - Log control card

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card header
            VStack(alignment: .leading, spacing: 2) {
                Text("Log \(group.name)")
                    .font(.risoHead(15, .bold))
                    .foregroundStyle(Color.risoPaper)
                if group.activeTaskCount > 0 {
                    Text("Counts on all \(group.activeTaskCount) active task\(group.activeTaskCount == 1 ? "" : "s")")
                        .font(.risoBody(11, .regular))
                        .foregroundStyle(Color.risoPaper.opacity(0.8))
                }
            }

            // ±1 stepper (P2: both + and − are wired)
            HStack(spacing: 12) {
                Spacer()

                // −1 button (disabled at lifetime 0)
                Button {
                    onDecrement()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "minus")
                            .font(.system(size: 16, weight: .bold))
                        Text("−1 \(unitLabel)")
                            .font(.risoHead(15, .bold))
                    }
                    .foregroundStyle(Color.risoPaper)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 18)
                    .background(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .fill(Color.risoPaper.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .strokeBorder(Color.risoPaper.opacity(0.45), lineWidth: Riso.Keyline.dense)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLogging || group.lifetime == 0)

                // +1 button
                Button {
                    onIncrement()
                } label: {
                    HStack(spacing: 6) {
                        if isLogging {
                            ProgressView()
                                .tint(Color.risoPaper)
                                .scaleEffect(0.85)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .bold))
                        }
                        Text("+1 \(unitLabel)")
                            .font(.risoHead(15, .bold))
                    }
                    .foregroundStyle(Color.risoPaper)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 22)
                    .background(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .fill(Color.risoPaper.opacity(0.18))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .strokeBorder(Color.risoPaper.opacity(0.6), lineWidth: Riso.Keyline.dense)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLogging)

                Spacer()
            }

            if let err = logError {
                Text(err)
                    .font(.risoBody(11, .regular))
                    .foregroundStyle(Color.risoPaper.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            // Explainer note
            Text("Every \(unitLabel) you log lands in each active task's window **and your all-time total** at once — each window keeps its own start and finish, so a fresh weekly task can start at 0 while your all-time keeps climbing.")
                .font(.risoBody(11, .regular))
                .foregroundStyle(Color.risoPaper.opacity(0.75))
                .multilineTextAlignment(.leading)
        }
        .padding(Riso.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .fill(Color.risoBlue)
        )
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
        )
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    // MARK: - "Appears on" timeframe chips

    private var appearsOnSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Appears on")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(distinctTimeframes, id: \.self) { tf in
                        timeframeChip(tf)
                    }
                }
                .padding(.horizontal, Riso.gutter)
            }
        }
    }

    private func timeframeChip(_ tf: Timeframe) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tf.risoColor)
                .frame(width: 7, height: 7)
            Text(tf.risoDisplayName.uppercased())
                .font(.risoHead(11, .bold))
                .tracking(0.3)
                .foregroundStyle(Color.risoInk)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Capsule().fill(Color.risoPaper2))
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
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
        let caption: String = {
            if member.met {
                return member.over > 0
                    ? "✓ Goal met · \(member.over) over"
                    : "✓ Goal met this window"
            }
            let remaining = member.goal - member.logged
            let windowLabel = member.window ?? "this window"
            return "\(windowLabel) · \(remaining) \(unitLabel) to go"
        }()

        return NavigationLink {
            if let boardId = member.boardId {
                BoardPlayView(boardId: boardId)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    // Timeframe dot
                    Circle()
                        .fill(member.timeframe?.risoColor ?? Color.risoMuted)
                        .frame(width: 9, height: 9)

                    // Task name + board name
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

                    // logged/goal + chevron
                    HStack(spacing: 6) {
                        Text("\(member.logged)/\(member.goal)")
                            .font(.risoHead(14, .bold))
                            .foregroundStyle(member.met ? Color.risoGreen : Color.risoInk)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.risoMuted)
                    }
                }

                // Window progress bar
                RisoProgressBar(
                    value: progressFraction,
                    color: member.met ? .risoGreen : .risoBlue,
                    height: 6
                )

                // Caption
                Text(caption)
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
            "\(member.taskTitle) on \(member.boardName ?? "no board"), \(member.logged) of \(member.goal) \(unitLabel), \(caption)"
        )
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
            // Muted dot
            Circle()
                .fill(Color.risoMuted.opacity(0.35))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(member.taskTitle)
                    .font(.risoBody(13, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
                Text("Starts counting when this board goes live.")
                    .font(.risoBody(10, .regular))
                    .foregroundStyle(Color.risoMuted.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            Text("\(member.logged)/\(member.goal)")
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
        tasks: [srcMember, weekMember, inactiveMember],
        taskCount: 3,
        boardCount: 2,
        activeTaskCount: 2
    )
    return NavigationStack {
        CounterDetailContent(group: group)
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
    return NavigationStack {
        CounterDetailContent(group: group)
    }
}
#endif
