import XCTest
@testable import OYBC

/// #570 timing: the fast path against the formatter chain it fronts, on
/// synthetic canonical strings and (when `OYBC_OWNER_DUMP` points at the
/// owner's anonymised workspace export, kept outside the repo) on every
/// timestamp string actually present in that data.
///
/// The numbers print as `[iso-bench] ...` lines; the only assertions are
/// bit-for-bit agreement and a deliberately lenient "faster" floor (the test
/// target is a Debug build, where the fast path's win is smallest).
final class ISO8601ParseBenchmarkTests: XCTestCase {

    /// The parse chain before #570: cached internet-date-time formatters, then
    /// `LocalISOParser` (cached `DateFormatter`s behind a lock).
    private struct FormatterChain {
        let fractional = ISO8601DateFormatter()
        let whole = ISO8601DateFormatter()

        init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            whole.formatOptions = [.withInternetDateTime]
        }

        func parse(_ s: String) -> Date? {
            fractional.date(from: s) ?? whole.date(from: s) ?? LocalISOParser.shared.parse(s)
        }
    }

    /// Wall-clock seconds for `repeats` passes of `parse` over `inputs`, plus a
    /// checksum so the work cannot be optimised away.
    private func time(_ inputs: [String], repeats: Int, _ parse: (String) -> Date?) -> (seconds: Double, checksum: Double) {
        var checksum = 0.0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<repeats {
            for s in inputs { checksum += parse(s)?.timeIntervalSinceReferenceDate ?? 0 }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        return (seconds, checksum)
    }

    private func report(_ label: String, inputs: [String], repeats: Int) {
        let chain = FormatterChain()
        _ = time(Array(inputs.prefix(200)), repeats: 1, chain.parse) // warm formatters + caches
        _ = time(Array(inputs.prefix(200)), repeats: 1, DateFormatting.parseISO)
        let old = time(inputs, repeats: repeats, chain.parse)
        let new = time(inputs, repeats: repeats, DateFormatting.parseISO)
        let parses = Double(inputs.count * repeats)
        let oldMicros = old.seconds / parses * 1e6
        let newMicros = new.seconds / parses * 1e6
        print(String(format: "[iso-bench] %@: %d parses  formatters %.2f us/parse  fast path %.3f us/parse  ratio %.1fx",
                     label, Int(parses), oldMicros, newMicros, oldMicros / newMicros))
        XCTAssertEqual(old.checksum, new.checksum, "\(label): the fast path changed a result")
        XCTAssertGreaterThan(oldMicros / newMicros, 3, "\(label): the fast path should beat the formatters comfortably even in Debug")
    }

    /// 60% `...Z`, 10% `....SSSZ`, 30% local `....SSS` - roughly the owner data's mix.
    func test_benchmark_syntheticCanonicalMix() {
        var inputs: [String] = []
        for i in 0..<5_000 {
            let day = 1 + i % 28, hour = i % 24, minute = i % 60, second = (i * 7) % 60
            let stamp = String(format: "2026-%02d-%02dT%02d:%02d:%02d", 1 + (i / 28) % 12, day, hour, minute, second)
            switch i % 10 {
            case 0..<6: inputs.append(stamp + "Z")
            case 6: inputs.append(stamp + String(format: ".%03dZ", i % 1000))
            default: inputs.append(stamp + String(format: ".%03d", i % 1000))
            }
        }
        report("synthetic mix", inputs: inputs, repeats: 4)
    }

    func test_benchmark_ownerWorkspaceTimestamps() throws {
        guard let path = ProcessInfo.processInfo.environment["OYBC_OWNER_DUMP"] else {
            throw XCTSkip("OYBC_OWNER_DUMP not set")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        var inputs: [String] = []
        func collect(_ value: Any) {
            if let s = value as? String {
                if s.count >= 19, s.hasPrefix("20"), s.contains("T"), DateFormatting.parseISO(s) != nil { inputs.append(s) }
            } else if let array = value as? [Any] {
                array.forEach(collect)
            } else if let dictionary = value as? [String: Any] {
                dictionary.values.forEach(collect)
            }
        }
        collect(object)
        try XCTSkipIf(inputs.isEmpty, "no timestamp strings found in the dump")
        let local = inputs.filter { !$0.hasSuffix("Z") }.count
        print("[iso-bench] owner workspace: \(inputs.count) timestamp strings (\(local) local, \(inputs.count - local) UTC)")
        report("owner workspace", inputs: inputs, repeats: max(1, 100_000 / inputs.count))
    }
}
