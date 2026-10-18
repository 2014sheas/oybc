import XCTest
@testable import OYBC

/// #570: `ISO8601FastParser` must answer bit-for-bit what the formatter chain
/// answers, and only ever in place of it - never instead of a verdict the
/// formatters would have reached differently. The oracle here is built from
/// fresh `ISO8601DateFormatter` / `DateFormatter` instances inside the test,
/// independent of the production parse code.
final class ISO8601FastParserTests: XCTestCase {

    // MARK: - Oracle

    /// The pre-fast-path parse chain with an explicit zone: fractional internet
    /// date-time, plain internet date-time, then the two local shapes.
    private struct Oracle {
        let utcFractional: ISO8601DateFormatter
        let utcWhole: ISO8601DateFormatter
        let localFractional: DateFormatter
        let localWhole: DateFormatter

        init(timeZone: TimeZone, calendar: Calendar = Calendar(identifier: .gregorian)) {
            utcFractional = ISO8601DateFormatter()
            utcFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            utcWhole = ISO8601DateFormatter()
            utcWhole.formatOptions = [.withInternetDateTime]
            func local(_ format: String) -> DateFormatter {
                let f = DateFormatter()
                f.calendar = calendar
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = timeZone
                f.dateFormat = format
                return f
            }
            localFractional = local("yyyy-MM-dd'T'HH:mm:ss.SSS")
            localWhole = local("yyyy-MM-dd'T'HH:mm:ss")
        }

        /// What `DateFormatting.parseISO` returned before the fast path existed.
        func parse(_ s: String) -> Date? {
            utcFractional.date(from: s) ?? utcWhole.date(from: s) ?? localFractional.date(from: s) ?? localWhole.date(from: s)
        }
    }

    // MARK: - Deterministic randomness

    /// SplitMix64: a seeded generator so a failure reproduces.
    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func pad(_ value: Int, _ width: Int) -> String {
        let s = String(value)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    private func isLeap(_ y: Int) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }

    private func daysIn(_ month: Int, _ year: Int) -> Int {
        [31, isLeap(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }

    /// A random canonical timestamp: random supported year/month/day (leap years
    /// and year ends included), 0-9 fractional digits, `Z` or zone-less.
    private func randomString(utc: Bool, using rng: inout SeededRandom) -> String {
        let year = Int.random(in: 1970...2200, using: &rng)
        let month = Int.random(in: 1...12, using: &rng)
        let day = Int.random(in: 1...daysIn(month, year), using: &rng)
        var s = "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T"
            + "\(pad(Int.random(in: 0...23, using: &rng), 2)):\(pad(Int.random(in: 0...59, using: &rng), 2)):\(pad(Int.random(in: 0...59, using: &rng), 2))"
        let digits = Int.random(in: 0...9, using: &rng)
        if digits > 0 { s += "." + (0..<digits).map { _ in String(Int.random(in: 0...9, using: &rng)) }.joined() }
        return utc ? s + "Z" : s
    }

    private func assertSame(_ actual: Date?, _ expected: Date?, _ input: String, file: StaticString = #filePath, line: UInt = #line) {
        switch (actual, expected) {
        case (nil, nil):
            break
        case let (a?, e?):
            XCTAssertEqual(a.timeIntervalSinceReferenceDate.bitPattern, e.timeIntervalSinceReferenceDate.bitPattern,
                           "\"\(input)\": \(a.timeIntervalSinceReferenceDate) vs \(e.timeIntervalSinceReferenceDate)", file: file, line: line)
        default:
            XCTFail("\"\(input)\": got \(String(describing: actual)), expected \(String(describing: expected))", file: file, line: line)
        }
    }

    private func requireGregorianCurrentCalendar() throws {
        try XCTSkipUnless(Calendar.current.identifier == .gregorian, "fast path stands down on non-Gregorian calendars by design")
    }

    // MARK: - UTC

    func test_utc_matchesTheFormatters_bitForBit_overRandomStrings_andIsAlwaysHandled() {
        let oracle = Oracle(timeZone: TimeZone(identifier: "UTC")!)
        var rng = SeededRandom(state: 570)
        for _ in 0..<12_000 {
            let s = randomString(utc: true, using: &rng)
            guard let fast = ISO8601FastParser.parse(s, accepting: [.utc, .local]) else {
                XCTFail("a canonical UTC string must be handled: \(s)")
                continue
            }
            assertSame(fast, oracle.parse(s), s)
        }
    }

    func test_utc_anchorsAndFractionRules() {
        let oracle = Oracle(timeZone: TimeZone(identifier: "UTC")!)
        let cases = [
            "1970-01-01T00:00:00Z", "1970-01-01T00:00:00.000Z", "2000-02-29T23:59:59.999Z", "2100-02-28T23:59:59Z",
            "2026-12-31T23:59:59.999Z", "2027-01-01T00:00:00Z", "2200-12-31T23:59:59.999999999Z", "2026-10-18T11:52:05.036Z",
            "2026-10-18T11:52:05.0Z", "2026-10-18T11:52:05.03Z", "2026-10-18T11:52:05.0361Z", "2026-10-18T11:52:05.9999Z",
            "2024-02-29T12:00:00Z",
        ]
        for s in cases {
            guard let fast = ISO8601FastParser.parse(s) else { XCTFail("not handled: \(s)"); continue }
            assertSame(fast, oracle.parse(s), s)
        }
    }

    func test_shapeFlags_gateWhatEachCallerAccepts() throws {
        let whole = "2026-10-18T11:52:05Z"
        let fractional = "2026-10-18T11:52:05.036Z"
        let local = "2026-10-18T11:52:05.036"
        XCTAssertNotNil(ISO8601FastParser.parse(whole, accepting: .utcWholeSeconds))
        XCTAssertNil(ISO8601FastParser.parse(fractional, accepting: .utcWholeSeconds), "the default-options formatter rejects a fraction")
        XCTAssertNotNil(ISO8601FastParser.parse(fractional, accepting: .utc))
        XCTAssertNil(ISO8601FastParser.parse(local, accepting: .utc), "zone-less strings are not UTC")
        XCTAssertNil(ISO8601FastParser.parse(whole, accepting: .local), "a Z string is not a local string")
    }

    // MARK: - Local

    func test_local_matchesDateFormatter_bitForBit_acrossZones() throws {
        try requireGregorianCurrentCalendar()
        let zones = ["America/New_York", "Australia/Sydney", "Australia/Lord_Howe", "Asia/Kolkata", "Pacific/Chatham", "UTC"]
        for id in zones {
            let zone = try XCTUnwrap(TimeZone(identifier: id))
            let oracle = Oracle(timeZone: zone)
            var rng = SeededRandom(state: 571)
            var handled = 0
            let total = 2_500
            for _ in 0..<total {
                let s = randomString(utc: false, using: &rng)
                guard let fast = ISO8601FastParser.parse(s, accepting: .local, timeZone: zone) else { continue }
                handled += 1
                assertSame(fast, oracle.parse(s), "\(id) \(s)")
            }
            XCTAssertGreaterThan(Double(handled) / Double(total), 0.95, "\(id): the fast path stood down too often (\(handled)/\(total))")
        }
    }

    /// Every wall-clock time within ±30h of every DST transition 2020-2035: the
    /// fast path either defers (nil) or agrees with `DateFormatter`; and the
    /// skipped (gap) / repeated (overlap) wall-clock times always defer.
    func test_local_aroundDaylightSavingTransitions_neverDisagrees_andGapsAndOverlapsDefer() throws {
        try requireGregorianCurrentCalendar()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func wallClock(_ naiveSeconds: Int, fraction: String = "") -> String {
            let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: Double(naiveSeconds)))
            return "\(pad(c.year!, 4))-\(pad(c.month!, 2))-\(pad(c.day!, 2))T\(pad(c.hour!, 2)):\(pad(c.minute!, 2)):\(pad(c.second!, 2))\(fraction)"
        }
        let start = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
        let end = Date(timeIntervalSince1970: 2_082_758_400)   // 2036-01-01
        for id in ["America/New_York", "America/Los_Angeles", "Europe/London", "Australia/Sydney", "Australia/Lord_Howe", "Pacific/Chatham", "America/Santiago"] {
            let zone = try XCTUnwrap(TimeZone(identifier: id))
            let oracle = Oracle(timeZone: zone)
            var transition = zone.nextDaylightSavingTimeTransition(after: start)
            var seen = 0, handled = 0, gapOrOverlapSamples = 0
            while let t = transition, t < end {
                seen += 1
                let before = zone.secondsFromGMT(for: t.addingTimeInterval(-1))
                let after = zone.secondsFromGMT(for: t)
                let anchor = Int(t.timeIntervalSince1970) + before
                for step in stride(from: -30 * 3600, through: 30 * 3600, by: 900) {
                    for (offset, fraction) in [(0, ""), (-1, ".999"), (1, ".001")] {
                        let naive = anchor + step + offset
                        let s = wallClock(naive, fraction: fraction)
                        let fast = ISO8601FastParser.parse(s, accepting: .local, timeZone: zone)
                        if let fast {
                            handled += 1
                            assertSame(fast, oracle.parse(s), "\(id) \(s)")
                        }
                        // Skipped (spring-forward) or repeated (fall-back) wall clock.
                        let lo = Int(t.timeIntervalSince1970) + min(before, after)
                        let hi = Int(t.timeIntervalSince1970) + max(before, after)
                        if before != after, naive >= lo, naive < hi {
                            gapOrOverlapSamples += 1
                            XCTAssertNil(fast, "\(id) \(s) is skipped or repeated: the formatter must decide")
                        }
                    }
                }
                transition = zone.nextDaylightSavingTimeTransition(after: t)
            }
            XCTAssertGreaterThan(seen, 0, "\(id): no transitions found")
            XCTAssertGreaterThan(handled, 0, "\(id): the fast path never answered")
            XCTAssertGreaterThan(gapOrOverlapSamples, 0, "\(id): no gap/overlap sample was exercised")
        }
    }

    // MARK: - Out-of-grammar input defers

    func test_inputOutsideTheGrammar_isNotHandled() {
        let notHandled = [
            "", "garbage", "2026-10-18", "2026-10-18T11:52Z", "2026-10-18T11:52:05.Z", "2026-10-18T11:52:05.",
            "2026-10-18T11:52:05.1234567890Z", "2026-10-18T11:52:05z", "2026-10-18t11:52:05Z", "2026-10-18 11:52:05Z",
            "2026-10-18T11:52:05+05:30", "2026-10-18T11:52:05.036-07:00", "2026-10-18T11:52:05+0530", "2026-10-18T11:52:05Zjunk",
            " 2026-10-18T11:52:05Z", "2026-10-18T11:52:05Z ", "2026-10-18T11:52:05 ", "2026-1-8T1:2:3Z", "+2026-10-18T11:52:05Z",
            "2026-02-30T11:52:05Z", "2025-02-29T00:00:00Z", "2026-13-01T00:00:00Z", "2026-00-10T00:00:00Z", "2026-10-00T00:00:00Z",
            "2026-10-32T00:00:00Z", "2026-10-18T24:00:00Z", "2026-10-18T23:60:00Z", "2026-10-18T23:59:60Z", "2026-10-18T-1:00:00Z",
            "1969-12-31T23:59:59Z", "2201-01-01T00:00:00Z", "0001-01-01T00:00:00Z", "1582-10-10T00:00:00Z", "9999-12-31T23:59:59Z",
            "20x6-10-18T11:52:05Z", "2026-10-18T11:5a:05Z", "2026/10/18T11:52:05Z", "2026-10-18T11-52-05Z",
        ]
        for s in notHandled {
            XCTAssertNil(ISO8601FastParser.parse(s, accepting: [.utc, .utcWholeSeconds, .local], timeZone: TimeZone(identifier: "UTC")), "should defer: \"\(s)\"")
        }
    }

    // MARK: - Integrated entry points vs the formatters

    /// Single-character edits, truncations and suffixes of valid strings: whatever
    /// the fast path does with them, `parseISO` must still equal the pre-fast-path
    /// chain (current zone / calendar) - including nil.
    func test_parseISO_equalsTheFormatterChain_forMutatedInput() throws {
        try requireGregorianCurrentCalendar()
        let oracle = Oracle(timeZone: TimeZone.current, calendar: Calendar.current)
        var rng = SeededRandom(state: 572)
        let alphabet = Array("0123456789TZ:-. +zt/x")
        let suffixes = ["", "Z", " ", "+05:30", "-07:00", "+0530", "z", ".", ".5", "junk"]
        for i in 0..<6_000 {
            var chars = Array(randomString(utc: i % 2 == 0, using: &rng))
            switch Int.random(in: 0..<5, using: &rng) {
            case 0:
                chars[Int.random(in: 0..<chars.count, using: &rng)] = alphabet.randomElement(using: &rng)!
            case 1:
                chars.remove(at: Int.random(in: 0..<chars.count, using: &rng))
            case 2:
                chars.insert(alphabet.randomElement(using: &rng)!, at: Int.random(in: 0...chars.count, using: &rng))
            case 3:
                chars = Array(chars.prefix(Int.random(in: 0..<chars.count, using: &rng)))
            default:
                chars += Array(suffixes.randomElement(using: &rng)!)
            }
            let s = String(chars)
            assertSame(DateFormatting.parseISO(s), oracle.parse(s), s)
        }
    }

    func test_parseISO_equalsTheFormatterChain_forTheRealDataShapes() throws {
        try requireGregorianCurrentCalendar()
        let oracle = Oracle(timeZone: TimeZone.current, calendar: Calendar.current)
        // Shapes found in the owner's workspace: Z whole seconds, Z + ms, local + ms.
        for s in ["2026-08-19T19:50:22Z", "2026-10-18T11:52:05.036Z", "2026-06-01T00:00:00.000", "2026-06-30T23:59:59.999",
                  "2026-10-18T00:00:00.000", "2026-03-08T02:30:00.000", "2026-11-01T01:30:00.000", "2026-03-08T02:30:00"] {
            assertSame(DateFormatting.parseISO(s), oracle.parse(s), s)
            assertSame(parseISO8601Date(s), oracle.parse(s), s)
        }
    }

    func test_parseInternetISO_matchesBothFormatterOrders_andRejectsLocalStrings() {
        let utcFractional = ISO8601DateFormatter()
        utcFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let utcWhole = ISO8601DateFormatter()
        var rng = SeededRandom(state: 573)
        for i in 0..<3_000 {
            var s = randomString(utc: i % 3 != 0, using: &rng)
            if i % 7 == 0 { s += "+05:30" }
            let wholeFirst = utcWhole.date(from: s) ?? utcFractional.date(from: s)
            let fractionalFirst = utcFractional.date(from: s) ?? utcWhole.date(from: s)
            assertSame(wholeFirst, fractionalFirst, "orders agree: \(s)")
            assertSame(DateFormatting.parseInternetISO(s), wholeFirst, s)
        }
        XCTAssertNil(DateFormatting.parseInternetISO("2026-10-18T11:52:05.036"), "zone-less is not an internet date-time")
    }

    func test_appDatabaseParseISO8601_keepsRejectingFractionalSeconds() {
        let reference = ISO8601DateFormatter()
        for s in ["2026-10-18T11:52:05Z", "2026-10-18T11:52:05.036Z", "2026-10-18T11:52:05+05:30", "2026-10-18T11:52:05", "bad"] {
            assertSame(AppDatabase.parseISO8601(s), reference.date(from: s), s)
        }
        XCTAssertNil(AppDatabase.parseISO8601("2026-10-18T11:52:05.036Z"))
        let stamp = AppDatabase.currentTimestamp()
        assertSame(AppDatabase.parseISO8601(stamp), reference.date(from: stamp), stamp)
    }

    func test_syncQueueItemIsStale_usesTheSameParse() {
        func item(createdAt: String) -> SyncQueueItem {
            SyncQueueItem(
                id: "q", entityType: "tasks", entityId: "t", operationType: .update, payload: "{}",
                status: .pending, retryCount: 0, lastError: nil, createdAt: createdAt,
                lastAttemptAt: nil, completedAt: nil, priority: 0
            )
        }
        let formatter = ISO8601DateFormatter()
        XCTAssertTrue(item(createdAt: formatter.string(from: Date().addingTimeInterval(-2 * 86_400))).isStale)
        XCTAssertFalse(item(createdAt: AppDatabase.currentTimestamp()).isStale)
        XCTAssertFalse(item(createdAt: "not a date").isStale)
    }

    // MARK: - Concurrency

    func test_parse_isSafeAcrossThreads_andDeterministic() {
        var rng = SeededRandom(state: 574)
        let inputs = (0..<64).map { randomString(utc: $0 % 2 == 0, using: &rng) }
        let expected = inputs.map { DateFormatting.parseISO($0)?.timeIntervalSinceReferenceDate.bitPattern }
        DispatchQueue.concurrentPerform(iterations: 4_000) { i in
            let index = i % inputs.count
            XCTAssertEqual(DateFormatting.parseISO(inputs[index])?.timeIntervalSinceReferenceDate.bitPattern, expected[index])
        }
    }
}
