import XCTest
@testable import OYBC

/// Parity tests for the iOS entitlement mirror — kept aligned with
/// `packages/shared/tests/types/entitlement.test.ts` +
/// `.../tests/constants/proGating.test.ts`.
final class EntitlementTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-08-23T12:00:00Z")!
    private let day: TimeInterval = 24 * 60 * 60

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func decode(_ json: [String: Any]) throws -> Entitlement {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(Entitlement.self, from: data)
    }

    // MARK: - Tolerant decode

    func testUnknownTierFallsBackToFree() throws {
        let e = try decode(["tier": "platinum", "isPro": true])
        XCTAssertEqual(e.tier, .free)
        XCTAssertFalse(e.isPro)
        XCTAssertEqual(e.source, .defaultSource)
    }

    func testRecomputesIsProFromTier() throws {
        // tier:free but isPro:true (spoof) → forced false
        let free = try decode(["tier": "free", "isPro": true])
        XCTAssertFalse(free.isPro)
        // tier:pro but isPro:false → forced true
        let pro = try decode(["tier": "pro", "isPro": false, "product": "yearly"])
        XCTAssertTrue(pro.isPro)
    }

    func testLifetimeForcesNilExpiry() throws {
        let e = try decode([
            "tier": "pro",
            "product": "lifetime",
            "expiresAt": "2026-09-23T00:00:00.000Z", // must be dropped
            "source": "revenuecat-webhook",
        ])
        XCTAssertEqual(e.product, .lifetime)
        XCTAssertNil(e.expiresAt)
    }

    func testFreeStripsMetadata() throws {
        let e = try decode([
            "tier": "free",
            "product": "monthly",
            "expiresAt": "2026-09-23T00:00:00.000Z",
            "willRenew": true,
        ])
        XCTAssertEqual(e, Entitlement.free)
    }

    func testDropsInvalidProductAndStore() throws {
        let e = try decode([
            "tier": "pro",
            "product": "weekly",   // invalid
            "store": "paypal",     // invalid
            "source": "revenuecat-webhook",
        ])
        XCTAssertEqual(e.tier, .pro)
        XCTAssertNil(e.product)
        XCTAssertNil(e.store)
    }

    // MARK: - Gating

    private func activePro() -> Entitlement {
        Entitlement(
            tier: .pro, isPro: true, product: .monthly,
            expiresAt: iso(now.addingTimeInterval(30 * day)),
            willRenew: true, store: .appStore,
            updatedAt: iso(now), source: .revenueCatWebhook
        )
    }

    func testIsProAcrossStates() {
        XCTAssertFalse(ProGating.isPro(.free, now: now))
        XCTAssertTrue(ProGating.isPro(activePro(), now: now))

        let lifetime = Entitlement(tier: .pro, isPro: true, product: .lifetime,
                                   expiresAt: nil, willRenew: nil, store: .stripe,
                                   updatedAt: iso(now), source: .revenueCatWebhook)
        XCTAssertTrue(ProGating.isPro(lifetime, now: now))
    }

    func testGraceWindow() {
        var e = activePro()
        e.expiresAt = iso(now.addingTimeInterval(-1 * day)) // 1 day past → within 3-day grace
        XCTAssertTrue(ProGating.isPro(e, now: now))
        e.expiresAt = iso(now.addingTimeInterval(-TimeInterval(ProGating.gracePeriodDays + 1) * day))
        XCTAssertFalse(ProGating.isPro(e, now: now))
    }

    func testFailsOpenOnMalformedExpiry() {
        var e = activePro()
        e.expiresAt = "not-a-date"
        XCTAssertTrue(ProGating.isPro(e, now: now)) // never hard-lock a payer
    }

    func testBoardCapAndFeatureGates() {
        let cap = ProGating.maxActiveBoardsFree
        XCTAssertFalse(ProGating.isOverFreeLimit(.unlimitedBoards, currentCount: cap - 1, .free, now: now))
        XCTAssertTrue(ProGating.isOverFreeLimit(.unlimitedBoards, currentCount: cap, .free, now: now))
        XCTAssertFalse(ProGating.isOverFreeLimit(.unlimitedBoards, currentCount: 999, activePro(), now: now))
        XCTAssertTrue(ProGating.canCreateBoard(activeBoardCount: cap - 1, .free, now: now))
        XCTAssertFalse(ProGating.canCreateBoard(activeBoardCount: cap, .free, now: now))

        for f in [ProFeature.recurringBoards, .achievementTasks, .compoundTasks] {
            XCTAssertTrue(ProGating.isFeatureGated(f, .free, now: now))
            XCTAssertFalse(ProGating.isFeatureGated(f, activePro(), now: now))
        }
    }
}
