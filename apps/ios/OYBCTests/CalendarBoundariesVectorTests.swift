import XCTest
@testable import OYBC

/// Cross-platform calendar-boundaries enforcement (workstream C1 / issue #267).
///
/// Runs the hand-authored fixture (`packages/shared/tests/fixtures/calendarBoundariesVectors.json`)
/// through iOS's mirrors in `Utils/TimeframeBoundaries.swift` +
/// `Utils/TimeframeFormatting.swift`. The SAME fixture is exercised on the
/// shared/web side by `packages/shared/tests/algorithms/calendarBoundaries.test.ts`
/// against `@oybc/shared`'s `calendarBoundaries.ts`. Both suites passing
/// against the same vectors is what proves the two hand-mirrored
/// implementations agree, not just an audit claim.
///
/// `isTimeframeExpired(endDate:now:)` has NO standalone Swift twin — the
/// closest analog, `isBoardExpired(_:Board)` in `TimeframeFormatting.swift`,
/// reads `Date()` internally (not injectable) and takes a whole `Board`, not
/// a bare `(endDate, now)` pair, so it isn't a drop-in match for these
/// vectors. Per the C1 scope note ("skip with a report note when a Swift
/// twin lacks a function"), `isTimeframeExpired` vectors are exercised ONLY
/// on the TS/Jest side (`calendarBoundaries.test.ts`) — this file has no
/// corresponding test.
final class CalendarBoundariesVectorTests: XCTestCase {

    private struct BoundariesExpected: Decodable {
        let ok: Bool
        let startDate: String?
        let endDate: String?
    }

    private struct GetBoundariesVector: Decodable {
        let name: String
        let timeframe: String
        let referenceDate: String
        let weekStartDay: String?
        let expected: BoundariesExpected
    }

    private struct StepWindowVector: Decodable {
        let name: String
        let timeframe: String
        let currentStart: String
        let step: Int
        let weekStartDay: String?
        let expected: BoundariesExpected
    }

    private struct IsWithinVector: Decodable {
        let name: String
        let candidate: String
        let startDate: String
        let endDate: String?
        let expected: Bool
    }

    private struct CadenceVector: Decodable {
        let name: String
        let timeframe: String
        let expected: String
    }

    private struct LabelVector: Decodable {
        let name: String
        let timeframe: String
        let startDate: String
        let expected: String
    }

    private struct Fixture: Decodable {
        let getTimeframeBoundaries: [GetBoundariesVector]
        let stepWindow: [StepWindowVector]
        let isWithinTimeframe: [IsWithinVector]
        let formatRecurringCadence: [CadenceVector]
        let formatTimeframeLabel: [LabelVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: CalendarBoundariesVectorTests.self).url(
            forResource: "calendarBoundariesVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "calendarBoundariesVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func parseLocal(_ string: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f.date(from: string)!
    }

    func testGetTimeframeBoundariesVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.getTimeframeBoundaries.isEmpty)
        for v in fixture.getTimeframeBoundaries {
            let timeframe = Timeframe(rawValue: v.timeframe)!
            let ref = parseLocal(v.referenceDate)
            let result = computeTimeframeBoundaries(
                timeframe: timeframe, referenceDate: ref, weekStartDay: v.weekStartDay ?? "monday"
            )
            if !v.expected.ok {
                XCTAssertNil(result, "Vector '\(v.name)' expected nil (not computable)")
                continue
            }
            guard let result else {
                XCTFail("Vector '\(v.name)' expected a boundary result but got nil")
                continue
            }
            if let expStart = v.expected.startDate {
                XCTAssertEqual(wizardLocalISOString(result.start), expStart, "Vector '\(v.name)' startDate")
            }
            if let expEnd = v.expected.endDate {
                XCTAssertEqual(wizardLocalISOString(result.end), expEnd, "Vector '\(v.name)' endDate")
            }
        }
    }

    func testStepWindowVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.stepWindow.isEmpty)
        for v in fixture.stepWindow {
            let timeframe = Timeframe(rawValue: v.timeframe)!
            let result = stepCoreBoardWindow(
                timeframe: timeframe, fromStartIso: v.currentStart, step: v.step, weekStartDay: v.weekStartDay ?? "monday"
            )
            if !v.expected.ok {
                XCTAssertNil(result, "Vector '\(v.name)' expected nil (not steppable)")
                continue
            }
            guard let result else {
                XCTFail("Vector '\(v.name)' expected a stepped window but got nil")
                continue
            }
            if let expStart = v.expected.startDate {
                XCTAssertEqual(wizardLocalISOString(result.start), expStart, "Vector '\(v.name)' startDate")
            }
            if let expEnd = v.expected.endDate {
                XCTAssertEqual(wizardLocalISOString(result.end), expEnd, "Vector '\(v.name)' endDate")
            }
        }
    }

    func testIsWithinTimeframeVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.isWithinTimeframe.isEmpty)
        for v in fixture.isWithinTimeframe {
            let result = DateFormatting.isWithinTimeframe(v.candidate, startDate: v.startDate, endDate: v.endDate)
            XCTAssertEqual(result, v.expected, "Vector '\(v.name)'")
        }
    }

    func testFormatRecurringCadenceVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.formatRecurringCadence.isEmpty)
        for v in fixture.formatRecurringCadence {
            let timeframe = Timeframe(rawValue: v.timeframe)!
            XCTAssertEqual(formatRecurringCadence(timeframe: timeframe), v.expected, "Vector '\(v.name)'")
        }
    }

    func testFormatTimeframeLabelVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.formatTimeframeLabel.isEmpty)
        for v in fixture.formatTimeframeLabel {
            let timeframe = Timeframe(rawValue: v.timeframe)!
            let date = parseLocal(v.startDate)
            XCTAssertEqual(formatTimeframeLabel(timeframe: timeframe, startDate: date), v.expected, "Vector '\(v.name)'")
        }
    }
}
