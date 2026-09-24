import XCTest
@testable import OYBC

/// Smoke guard for the derived-counter hot path (final-fix wave F1).
///
/// `resolveWindowStampedDerivedState` runs per derived cell per body pass on
/// the main thread. A board row minted by the wizard carries LOCAL-ISO window
/// bounds (`yyyy-MM-dd'T'HH:mm:ss.SSS`, no zone), which `DateFormatting.parseISO`
/// can only parse by allocating a `DateFormatter`. Re-parsing the bounds per
/// root event turned a root with a few thousand logs into thousands of
/// formatter inits per pass. The bounds must be parsed once per call.
///
/// Machine-independent: the guard is a RATIO against a same-run baseline —
/// a loop that only parses the same 2,000 `occurredAt` strings through
/// `DateFormatting.parseISO` (the cached `ISO8601DateFormatter` path). The
/// hoisted body is that parse plus a compare per event, so it must stay under
/// `maxRatio` × the baseline; the per-event bound re-parse was ~10× (resolve)
/// and ~5× (sealed display) on the iPhone 17 / iOS 26.3.1 simulator, Debug.
/// Slow shared CI runners scale numerator and denominator alike. A loose
/// absolute ceiling (`sanityCeilingMs`) still catches a pathological
/// regression. Best of five runs damps scheduler noise. The count assertions
/// keep it honest — the fast path must still sum exactly the in-window
/// increments.
final class WindowStampedDerivedPerfTests: XCTestCase {

    private let maxRatio = 2.0
    private let sanityCeilingMs = 1_000.0

    /// Best-of-`runs` wall time of `body`, in milliseconds.
    private func bestOf(_ runs: Int = 5, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let start = CFAbsoluteTimeGetCurrent()
            body()
            best = min(best, (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        return best
    }

    /// Same-run baseline: parse every `occurredAt` once, nothing else.
    private func parseBaselineMs(_ events: [TaskEvent]) -> Double {
        var parsed = 0
        let ms = bestOf {
            parsed = 0
            for e in events where DateFormatting.parseISO(e.occurredAt) != nil { parsed += 1 }
        }
        XCTAssertEqual(parsed, events.count, "baseline must parse every event")
        return ms
    }

    /// Asserts `elapsedMs` is within `maxRatio` × `baselineMs` and under the
    /// absolute sanity ceiling; logs both.
    private func assertNearParseCost(_ label: String, elapsedMs: Double, baselineMs: Double) {
        let ratio = elapsedMs / max(baselineMs, 0.001)
        print("[perf] \(label): \(String(format: "%.2f", elapsedMs)) ms vs parse baseline \(String(format: "%.2f", baselineMs)) ms = \(String(format: "%.2f", ratio))x (best of 5)")
        XCTAssertLessThan(ratio, maxRatio, "\(label): bounds must be parsed once per call, not per event")
        XCTAssertLessThan(elapsedMs, sanityCeilingMs, "\(label): pathological slowdown")
    }

    private let rootId = "root"
    /// Local-ISO bounds — the wizard's `wizardLocalISOString` shape.
    private let ws = "2026-09-14T00:00:00.000"
    private let we = "2026-09-20T23:59:59.999"

    private func makeRow() -> Task {
        Task(
            id: "row", userId: "u1", title: "row", type: .counting,
            action: "Read", unit: "pages", maxCount: 1_000,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, currentCount: 0,
            createdAt: ws, updatedAt: ws, version: 1, isDeleted: false,
            startDate: ws, endDate: we,
            sharedCounterId: rootId, baseline: 0,
            createdInWizard: true
        )
    }

    private func inc(_ i: Int, _ at: String) -> TaskEvent {
        TaskEvent(
            id: "e\(i)", userId: "u1", taskId: rootId, kind: .increment, delta: 1,
            occurredAt: at, boardId: nil, createdAt: at, updatedAt: at, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        )
    }

    /// 1,000 increments mid-window (2026-09-17, inside the window in every
    /// time zone) + 1,000 three weeks after it (outside in every time zone).
    private func makeEvents() -> [TaskEvent] {
        var events: [TaskEvent] = []
        events.reserveCapacity(2_000)
        for i in 0..<1_000 {
            let m = i / 60, s = i % 60
            events.append(inc(i, String(format: "2026-09-17T10:%02d:%02d.000Z", m, s)))
            events.append(inc(1_000 + i, String(format: "2026-10-10T10:%02d:%02d.000Z", m, s)))
        }
        return events
    }

    func testResolveOverTwoThousandEventsForLocalISORowIsFast() {
        let row = makeRow()
        let events = makeEvents()

        let state = resolveWindowStampedDerivedState(task: row, rootEvents: events)
        XCTAssertEqual(state.count, 1_000, "only the mid-window increments count")
        XCTAssertTrue(state.isCompleted)

        let baselineMs = parseBaselineMs(events)
        let elapsedMs = bestOf { _ = resolveWindowStampedDerivedState(task: row, rootEvents: events) }
        assertNearParseCost("resolveWindowStampedDerivedState", elapsedMs: elapsedMs, baselineMs: baselineMs)
    }

    func testLinkedDisplayWithSealedAtOverTwoThousandEventsIsFast() {
        let row = makeRow()
        let map = [rootId: makeEvents()]
        // Sealed mid-window at 10:12:00.000: increments 0...720 (10:00:00 up to
        // and including the one AT the seal instant — the bound is inclusive)
        // are kept; the in-window ones after the seal are dropped.
        let sealedAt = "2026-09-17T10:12:00.000Z"

        let shown = resolveLinkedCounterDisplay(task: row, eventsByTaskId: map, sealedAt: sealedAt)
        XCTAssertEqual(shown.displayed, 721, "events after sealedAt are dropped")
        XCTAssertFalse(shown.isCompleted)

        let baselineMs = parseBaselineMs(map[rootId] ?? [])
        let elapsedMs = bestOf { _ = resolveLinkedCounterDisplay(task: row, eventsByTaskId: map, sealedAt: sealedAt) }
        assertNearParseCost("resolveLinkedCounterDisplay(sealedAt:)", elapsedMs: elapsedMs, baselineMs: baselineMs)
    }
}
