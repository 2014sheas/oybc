import SwiftUI

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
