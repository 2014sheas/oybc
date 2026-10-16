import XCTest
@testable import OYBC

/// `TaskCountDisplay.windowCaptionLines` — Task Detail's window / linked-
/// counter kind lines (web twin `taskWindowCaptionLines`, jest-pinned).
final class TaskWindowCaptionTests: XCTestCase {
    private let now = DateFormatting.parseISO("2026-10-16T17:30:00.000Z")!

    private func task(
        type: TaskType = .counting, timeframe: Timeframe? = nil, startDate: String? = nil,
        endDate: String? = nil, sharedCounterId: String? = nil, createdInWizard: Bool = false
    ) -> Task {
        Task(
            id: "t", userId: "u", title: "t", type: type, totalCompletions: 0, totalInstances: 0,
            createdAt: "2026-05-01T00:00:00.000Z", updatedAt: "2026-05-01T00:00:00.000Z", version: 1,
            isDeleted: false, timeframe: timeframe, startDate: startDate, endDate: endDate,
            sharedCounterId: sharedCounterId, createdInWizard: createdInWizard
        )
    }

    func test_plainTask_hasNoLines() {
        XCTAssertEqual(TaskCountDisplay.windowCaptionLines(for: task(type: .normal), now: now), [])
    }

    func test_dailyWindow_isNamed_andMarkedEndedOncePast() {
        let t = task(timeframe: .daily, startDate: "2026-10-13T00:00:00", endDate: "2026-10-13T23:59:59.999", createdInWizard: true)
        XCTAssertEqual(TaskCountDisplay.windowCaptionLines(for: t, now: now), ["Window · Oct 13, 2026 · ended"])
    }

    func test_openWindow_notEnded_andOpenEndedNever() {
        let open = task(timeframe: .monthly, startDate: "2026-10-01T00:00:00", endDate: "2026-10-31T23:59:59.999")
        XCTAssertEqual(TaskCountDisplay.windowCaptionLines(for: open, now: now), ["Window · October 2026"])
        let ongoing = task(timeframe: .indefinite, startDate: "2026-02-15T00:00:00")
        XCTAssertEqual(TaskCountDisplay.windowCaptionLines(for: ongoing, now: now), ["Window · Ongoing"])
    }

    func test_customOrTimeframeLessWindow_showsBareDates() {
        let custom = task(timeframe: .custom, startDate: "2026-10-01T00:00:00", endDate: "2026-10-20T23:59:59.999")
        XCTAssertEqual(TaskCountDisplay.windowCaptionLines(for: custom, now: now), ["Window · Oct 1, 2026 – Oct 20, 2026"])
        XCTAssertEqual(TaskCountDisplay.windowCaptionLines(for: task(startDate: "2026-10-01T00:00:00"), now: now), ["Window · Oct 1, 2026"])
    }

    func test_linkedCounter_perWindowCopy_vsFollowsEachBoard() {
        let stamped = task(timeframe: .daily, startDate: "2026-10-13T00:00:00", endDate: "2026-10-13T23:59:59.999", sharedCounterId: "root", createdInWizard: true)
        XCTAssertEqual(
            TaskCountDisplay.windowCaptionLines(for: stamped, now: now),
            ["Window · Oct 13, 2026 · ended", "Linked counter · per-window copy"]
        )
        let hubLinked = task(sharedCounterId: "root", createdInWizard: true)
        XCTAssertEqual(TaskCountDisplay.windowCaptionLines(for: hubLinked, now: now), ["Linked counter · follows each board's window"])
    }

    func test_linkLine_isCountingOnly() {
        XCTAssertEqual(TaskCountDisplay.windowCaptionLines(for: task(type: .normal, sharedCounterId: "root"), now: now), [])
    }
}
