import Combine
import XCTest
@testable import OYBC

/// The pure halves of the board-log lag fix: the local-ISO parser, the delayed busy
/// look, chip identity and the busy-look flag on the sheet content.
final class BoardLogLagPureTests: XCTestCase {

    // MARK: - parseISO (cached local formatters)

    /// The implementation `DateFormatting.parseISO` had before the cache: fresh
    /// `DateFormatter`s per call for the local shapes.
    private func legacyParseISO(_ iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: iso) { return d }
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            let f = DateFormatter()
            f.calendar = Calendar.current
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = format
            if let d = f.date(from: iso) { return d }
        }
        return nil
    }

    private let samples = [
        "2026-10-18T00:00:00.000", "2026-10-18T23:59:59.999", "2026-10-18T00:00:00", "2026-03-08T02:30:00.000",
        "2026-11-01T01:30:00", "2026-10-18T00:00:00.000Z", "2026-10-18T00:00:00Z", "2026-10-18T09:15:30.250+05:30",
        "2026-10-18T09:15:30-07:00", "2024-02-29T12:00:00.000", "2026-02-30T00:00:00.000", "2026-13-01T00:00:00",
        "2026-10-18", "2026-10-18 00:00:00", "", "garbage", "2026-10-18T00:00:00.000 ", "2026-10-18T25:00:00",
    ]

    private func assertSamplesMatchLegacy(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for s in samples {
            XCTAssertEqual(DateFormatting.parseISO(s), legacyParseISO(s), "\(label): \"\(s)\"", file: file, line: line)
        }
    }

    func test_parseISO_matchesTheLegacyImplementation_forRepresentativeInputs() {
        assertSamplesMatchLegacy("current zone")
        XCTAssertNil(DateFormatting.parseISO("garbage"))
        XCTAssertNotNil(DateFormatting.parseISO("2026-10-18T00:00:00.000"))
    }

    func test_parseISO_followsTimeZoneChanges_likeTheLegacyImplementation() {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        let local = "2026-10-18T00:00:00.000"
        var seen = Set<Double>()
        for id in ["Pacific/Auckland", "America/Los_Angeles", "UTC"] {
            guard let zone = TimeZone(identifier: id) else { return XCTFail("zone \(id)") }
            NSTimeZone.default = zone
            assertSamplesMatchLegacy(id)
            if let d = DateFormatting.parseISO(local) { seen.insert(d.timeIntervalSince1970) }
        }
        // The same wall-clock string is a different instant per zone — the cache must not pin the first.
        if TimeZone.current.identifier == "UTC" { XCTAssertEqual(seen.count, 3) }
    }

    func test_parseISO_reusesItsFormatters_andIsSafeAcrossThreads() {
        // The canonical local/UTC shapes are answered by `ISO8601FastParser`, which never touches
        // `LocalISOParser`; this year is outside the fast path's range, so a local string with it
        // still goes through the cached formatters and exercises the cache.
        let deferred = "2201-06-01T00:00:00.000"
        XCTAssertNil(ISO8601FastParser.parse(deferred), "precondition: the fast path defers, so this input reaches LocalISOParser")
        _ = DateFormatting.parseISO(deferred) // warm
        let before = LocalISOParser.shared.buildCount
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            let input: String
            switch i % 3 {
            case 0: input = deferred
            case 1: input = "2026-10-18T00:00:00.000"
            default: input = "2201-06-01T10:00:00"
            }
            XCTAssertNotNil(DateFormatting.parseISO(input))
        }
        XCTAssertEqual(LocalISOParser.shared.buildCount, before, "no rebuilds while the zone is stable")
    }

    // MARK: - Delayed busy look

    func test_delayedBusyLook_aFastWriteNeverDims_aSlowOneDimsAfterTheDelay_andClearsAtOnce() {
        let busy = PassthroughSubject<Bool, Never>()
        var seen: [Bool] = []
        let sub = busy.delayedBusyLook(after: 0.08).sink { seen.append($0) }
        defer { sub.cancel() }

        busy.send(true)
        busy.send(false) // inside the window
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(seen.contains(true), "a write that finishes inside the delay never dims")

        busy.send(true)
        XCTAssertFalse(seen.contains(true), "not yet")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(seen.last, true, "still in flight after the delay: dims")
        busy.send(false)
        XCTAssertEqual(seen.last, false, "clears immediately, no trailing delay")
    }

    func test_busyLookDelay_isOneConstant() {
        XCTAssertEqual(BusyLook.delay, 0.25, accuracy: 0.0001)
    }

    func test_squareSheetContent_busyLookFollowsBusyUnlessGiven() {
        func content(isBusy: Bool, look: Bool?) -> SquareSheetContent {
            SquareSheetContent(
                boardTaskId: "b", taskId: "t", title: "T", kind: .counting, boardName: "W",
                isBusy: isBusy, busyLook: look, body: .normal(isDone: false, sealBlocked: false)
            )
        }
        XCTAssertTrue(content(isBusy: true, look: nil).showsBusyLook, "unspecified: old behaviour (snapshots)")
        XCTAssertFalse(content(isBusy: true, look: false).showsBusyLook, "inert but not dimmed yet")
        XCTAssertTrue(content(isBusy: true, look: true).showsBusyLook)
        XCTAssertFalse(content(isBusy: false, look: nil).showsBusyLook)
    }

    // MARK: - Chip identity

    func test_chipRowIDs_followRole_notPosition() {
        let early = CounterLogAmount.tapChips(kind: .discrete, goal: 20, windowedCount: 12)
        let later = CounterLogAmount.tapChips(kind: .discrete, goal: 20, windowedCount: 17)
        let done = CounterLogAmount.tapChips(kind: .discrete, goal: 20, windowedCount: 20)
        XCTAssertEqual(Set(early.map(\.rowID)).count, early.count, "ids are unique within a row")
        XCTAssertTrue(early.contains { $0.role == .rest })
        let rest: (CounterLogAmount.TapChip) -> Bool = { $0.role == .rest }
        // The rest chip keeps one identity while its label changes (8 -> 3 to go)...
        XCTAssertEqual(early.first(where: rest)?.rowID, later.first(where: rest)?.rowID)
        XCTAssertNotEqual(early.first(where: rest)?.label, later.first(where: rest)?.label)
        // ...and presets keep theirs when the rest chip appears or disappears between them.
        let presets: ([CounterLogAmount.TapChip]) -> [String] = { $0.filter { $0.role == .preset }.map(\.rowID) }
        XCTAssertEqual(presets(early), presets(later))
        XCTAssertEqual(presets(early), presets(done))
        XCTAssertFalse(done.contains(where: rest))
        XCTAssertEqual(early.last?.rowID, done.last?.rowID, "\"Other…\" is stable")
    }
}
