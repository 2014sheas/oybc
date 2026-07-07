import XCTest
@testable import OYBC

/// Cross-platform streak enforcement (workstream C1 / issue #267).
///
/// Runs the hand-authored fixture (`packages/shared/tests/fixtures/streaksVectors.json`)
/// through iOS's `computeStreak` / `computeAllStreaks` / `computeLongestStreak` /
/// `compactStreakLabel` in `Services/Streaks.swift`. The SAME fixture is
/// exercised on the shared/web side by `packages/shared/tests/algorithms/streaks.test.ts`
/// against `@oybc/shared`'s `streaks.ts`. Both suites passing against the
/// same vectors is what proves the two hand-mirrored implementations agree,
/// not just an audit claim.
final class StreaksVectorTests: XCTestCase {

    private struct MiniBoard: Decodable {
        let timeframe: String
        let startDate: String
        let endDate: String
        let status: String
        let linesCompleted: Int
        let isCore: Bool
        let isDeleted: Bool
    }

    private struct StreakVector: Decodable {
        let name: String
        let timeframe: String
        let criterion: String
        let boards: [MiniBoard]
        let expected: Int
    }

    private struct AllStreaksExpected: Decodable {
        let daily: StreakPairFixture
        let weekly: StreakPairFixture
        let monthly: StreakPairFixture
        let yearly: StreakPairFixture
    }

    private struct StreakPairFixture: Decodable {
        let bingo: Int
        let greenlog: Int
    }

    private struct AllStreaksVector: Decodable {
        let name: String
        let boards: [MiniBoard]
        let expected: AllStreaksExpected
    }

    private struct LongestStreakVector: Decodable {
        let name: String
        let timeframe: String
        let boards: [MiniBoard]
        let expected: Int
    }

    private struct LabelVector: Decodable {
        let name: String
        let count: Int
        let timeframe: String
        let expected: String
    }

    private struct Fixture: Decodable {
        let now: String
        let computeStreak: [StreakVector]
        let computeAllStreaks: [AllStreaksVector]
        let computeLongestStreak: [LongestStreakVector]
        let compactStreakLabel: [LabelVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: StreaksVectorTests.self).url(
            forResource: "streaksVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "streaksVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func toBoard(_ m: MiniBoard, _ index: Int) -> Board {
        let dict: [String: Any] = [
            "id": "b-\(m.timeframe)-\(m.startDate)-\(index)",
            "userId": "u1",
            "name": "core",
            "status": m.status,
            "boardSize": 5,
            "timeframe": m.timeframe,
            "startDate": m.startDate,
            "endDate": m.endDate,
            "centerSquareType": "free",
            "isRandomized": true,
            "totalTasks": 25,
            "completedTasks": 0,
            "linesCompleted": m.linesCompleted,
            "createdAt": "2026-01-01T00:00:00.000",
            "updatedAt": "2026-01-01T00:00:00.000",
            "version": 1,
            "isDeleted": m.isDeleted,
            "isCore": m.isCore,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func now(_ fixture: Fixture) -> Date {
        wizardParseFixtureDate(fixture.now)
    }

    func testComputeStreakVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.computeStreak.isEmpty)
        let ref = now(fixture)
        for v in fixture.computeStreak {
            let boards = v.boards.enumerated().map { toBoard($1, $0) }
            let timeframe = Timeframe(rawValue: v.timeframe)!
            let criterion = AchievementTrigger(rawValue: v.criterion)!
            let result = computeStreak(
                timeframe: timeframe, criterion: criterion, boards: boards,
                weekStartDay: "monday", now: ref
            )
            XCTAssertEqual(result, v.expected, "Vector '\(v.name)' expected \(v.expected) but got \(result)")
        }
    }

    func testComputeAllStreaksVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.computeAllStreaks.isEmpty)
        let ref = now(fixture)
        for v in fixture.computeAllStreaks {
            let boards = v.boards.enumerated().map { toBoard($1, $0) }
            let all = computeAllStreaks(boards: boards, weekStartDay: "monday", now: ref)
            XCTAssertEqual(all[.daily], StreakPair(bingo: v.expected.daily.bingo, greenlog: v.expected.daily.greenlog), v.name)
            XCTAssertEqual(all[.weekly], StreakPair(bingo: v.expected.weekly.bingo, greenlog: v.expected.weekly.greenlog), v.name)
            XCTAssertEqual(all[.monthly], StreakPair(bingo: v.expected.monthly.bingo, greenlog: v.expected.monthly.greenlog), v.name)
            XCTAssertEqual(all[.yearly], StreakPair(bingo: v.expected.yearly.bingo, greenlog: v.expected.yearly.greenlog), v.name)
        }
    }

    func testComputeLongestStreakVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.computeLongestStreak.isEmpty)
        let ref = now(fixture)
        for v in fixture.computeLongestStreak {
            let boards = v.boards.enumerated().map { toBoard($1, $0) }
            let timeframe = Timeframe(rawValue: v.timeframe)!
            let result = computeLongestStreak(timeframe: timeframe, boards: boards, weekStartDay: "monday", now: ref)
            XCTAssertEqual(result, v.expected, "Vector '\(v.name)' expected \(v.expected) but got \(result)")
        }
    }

    func testCompactStreakLabelVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.compactStreakLabel.isEmpty)
        for v in fixture.compactStreakLabel {
            let timeframe = Timeframe(rawValue: v.timeframe)!
            XCTAssertEqual(compactStreakLabel(v.count, timeframe: timeframe), v.expected, v.name)
        }
    }
}

/// Parses the fixture's local-ISO `now` string (`yyyy-MM-dd'T'HH:mm:ss.SSS`)
/// into a `Date` using the device's local calendar/timezone — matches how
/// `wizardLocalISOString` writes these strings and how the TS side's
/// `new Date('...')` (no `Z` suffix) parses them as local time.
private func wizardParseFixtureDate(_ string: String) -> Date {
    let f = DateFormatter()
    f.calendar = Calendar.current
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
    return f.date(from: string)!
}
