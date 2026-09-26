import XCTest
@testable import OYBC

/// Unit coverage for `coreWindowRoute(for:weekStartDay:)` — the resolver
/// that sends a core board opened from ANY entry point into the per-window
/// pager. Mirrors the `coreWindowRouteForBoard` cases in the shared
/// `recurringBoards.test.ts` so the two implementations stay in lockstep
/// (parity rule 6).
final class CoreWindowRouteTests: XCTestCase {

    /// Pinned reference — Wed Sep 16 2026, local noon.
    private var ref: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 16; comps.hour = 12
        return Calendar.current.date(from: comps)!
    }

    /// A board whose `startDate` is the boundary-helper window start for
    /// `timeframe` around `ref` under a Monday week start.
    private func boardForWindow(
        _ timeframe: Timeframe,
        isCore: Bool = true,
        isDeleted: Bool = false,
        status: String = "active",
        startDate: String? = nil
    ) -> Board {
        let window = computeTimeframeBoundaries(
            timeframe: timeframe, referenceDate: ref, weekStartDay: "monday"
        )
        let start = startDate ?? window.map { wizardLocalISOString($0.start) } ?? "2026-09-16T00:00:00.000"
        let end = window.map { wizardLocalISOString($0.end) } ?? start
        let dict: [String: Any] = [
            "id": "b-\(timeframe.rawValue)", "userId": "u1", "name": "B", "status": status,
            "boardSize": 3, "timeframe": timeframe.rawValue,
            "startDate": start, "endDate": end,
            "centerSquareType": "none", "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": start, "updatedAt": start, "version": 1,
            "isDeleted": isDeleted, "isCore": isCore,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    func test_routesCoreBoardOnEachRecurringTimeframeToItsOwnWindow() {
        for tf in [Timeframe.daily, .weekly, .monthly, .yearly] {
            let board = boardForWindow(tf)
            let route = coreWindowRoute(for: board, weekStartDay: "monday")
            XCTAssertEqual(route, CoreWindowRoute(timeframe: tf, windowStart: board.startDate), "\(tf)")
        }
    }

    func test_nilForAdHocBoardOnRecurringTimeframe() {
        XCTAssertNil(coreWindowRoute(for: boardForWindow(.weekly, isCore: false), weekStartDay: "monday"))
    }

    func test_nilForDeletedCoreBoard() {
        XCTAssertNil(coreWindowRoute(for: boardForWindow(.daily, isDeleted: true), weekStartDay: "monday"))
    }

    func test_nilForCustomAndIndefiniteEvenWhenFlaggedCore() {
        for tf in [Timeframe.custom, .indefinite] {
            XCTAssertNil(coreWindowRoute(for: boardForWindow(tf), weekStartDay: "monday"), "\(tf)")
        }
    }

    func test_routesEveryStatusAlike() {
        // The pager shows sealed / completed windows and drafts (resume
        // prompt) itself — status never decides the surface.
        for status in ["active", "completed", "archived", "draft"] {
            XCTAssertNotNil(
                coreWindowRoute(for: boardForWindow(.monthly, status: status), weekStartDay: "monday"),
                status
            )
        }
    }

    func test_nilWhenStoredStartIsNotTheWindowStartThePagerLooksUp() {
        // A weekly core board stamped under a Monday week start, read back
        // under a Sunday preference: the recomputed window start differs,
        // so the pager would show an empty window — stay on the plain route.
        let mondayBoard = boardForWindow(.weekly)
        XCTAssertNil(coreWindowRoute(for: mondayBoard, weekStartDay: "sunday"))
        XCTAssertNotNil(coreWindowRoute(for: mondayBoard, weekStartDay: "monday"))

        // A mid-window startDate (not a boundary) never matches either.
        let offBoundary = boardForWindow(.weekly, startDate: "2026-09-16T12:00:00.000")
        XCTAssertNil(coreWindowRoute(for: offBoundary, weekStartDay: "monday"))
    }

    func test_nilForUnparseableStartDate() {
        XCTAssertNil(coreWindowRoute(for: boardForWindow(.daily, startDate: "not-a-date"), weekStartDay: "monday"))
    }
}
