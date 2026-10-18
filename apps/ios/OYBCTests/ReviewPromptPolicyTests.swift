import XCTest
@testable import OYBC

/// `ReviewPromptPolicy` — the App Store review prompt after early Bingos
/// (Track L5): due after an earned Bingo moment's "Back to board" once the
/// device has shown its third, never on the first launch, at most once per
/// app version; Greenlogs and BINGOS-card replays never count or prompt.
final class ReviewPromptPolicyTests: XCTestCase {

    /// In-memory `ReviewPromptStore`, so the tests never touch UserDefaults.
    private final class MemoryStore: ReviewPromptStore {
        var values: [String: Any] = [:]

        func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
        func string(forKey key: String) -> String? { values[key] as? String }
        func set(_ value: Int, forKey key: String) { values[key] = value }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
    }

    private var store: MemoryStore!
    private var policy: ReviewPromptPolicy!

    override func setUp() {
        super.setUp()
        store = MemoryStore()
        policy = ReviewPromptPolicy(store: store)
    }

    /// Simulates `launches` app launches and `bingos` earned Bingo moments.
    private func seed(launches: Int, bingos: Int) {
        for _ in 0..<launches { policy.recordLaunch() }
        for _ in 0..<bingos { policy.momentOpened(.bingo, isReplay: false) }
    }

    /// `isPromptDue` with the common arguments defaulted (an earned Bingo, v1.0.0).
    private func isDue(_ kind: MomentTrigger.Kind = .bingo, isReplay: Bool = false, version: String? = "1.0.0") -> Bool {
        policy.isPromptDue(afterDismissing: kind, isReplay: isReplay, appVersion: version)
    }

    // MARK: - Threshold

    func testThirdEarnedBingoIsDue() {
        seed(launches: 2, bingos: 2)
        XCTAssertFalse(isDue(), "two Bingos are not enough")
        policy.momentOpened(.bingo, isReplay: false)
        XCTAssertTrue(isDue(), "the third earned Bingo prompts")
    }

    func testLaterBingosStayDueUntilPrompted() {
        seed(launches: 3, bingos: 7)
        XCTAssertTrue(isDue())
    }

    // MARK: - First launch

    func testNeverOnTheFirstLaunch() {
        seed(launches: 1, bingos: 5)
        XCTAssertFalse(isDue(), "the first launch never prompts, however many Bingos")
        policy.recordLaunch()
        XCTAssertTrue(isDue())
    }

    func testNoRecordedLaunchNeverPrompts() {
        seed(launches: 0, bingos: 3)
        XCTAssertFalse(isDue())
    }

    // MARK: - Once per version

    func testAtMostOncePerAppVersion() {
        seed(launches: 2, bingos: 3)
        XCTAssertTrue(policy.consumePrompt(afterDismissing: .bingo, isReplay: false, appVersion: "1.0.0"))
        policy.momentOpened(.bingo, isReplay: false)
        XCTAssertFalse(policy.consumePrompt(afterDismissing: .bingo, isReplay: false, appVersion: "1.0.0"),
                       "the same version never asks twice")
        XCTAssertTrue(policy.consumePrompt(afterDismissing: .bingo, isReplay: false, appVersion: "1.1.0"),
                      "a new version may ask again")
    }

    func testIsPromptDueDoesNotRecord() {
        seed(launches: 2, bingos: 3)
        XCTAssertTrue(isDue())
        XCTAssertTrue(isDue(), "a pure read leaves the prompt due")
        XCTAssertNil(store.string(forKey: ReviewPromptPolicy.Keys.lastPromptedVersion))
    }

    func testMissingOrEmptyVersionNeverPrompts() {
        seed(launches: 2, bingos: 3)
        XCTAssertFalse(isDue(version: nil))
        XCTAssertFalse(isDue(version: ""))
        XCTAssertFalse(policy.consumePrompt(afterDismissing: .bingo, isReplay: false, appVersion: nil))
    }

    // MARK: - What counts

    func testGreenlogNeitherCountsNorPrompts() {
        seed(launches: 2, bingos: 0)
        for _ in 0..<5 { policy.momentOpened(.greenlog, isReplay: false) }
        XCTAssertEqual(store.integer(forKey: ReviewPromptPolicy.Keys.bingoMoments), 0)

        seed(launches: 0, bingos: 3)
        XCTAssertFalse(isDue(.greenlog), "dismissing a Greenlog never prompts")
        XCTAssertTrue(isDue(.bingo))
    }

    func testReplayNeitherCountsNorPrompts() {
        seed(launches: 2, bingos: 0)
        for _ in 0..<5 { policy.momentOpened(.bingo, isReplay: true) }
        XCTAssertEqual(store.integer(forKey: ReviewPromptPolicy.Keys.bingoMoments), 0)

        seed(launches: 0, bingos: 3)
        XCTAssertFalse(isDue(isReplay: true), "dismissing a BINGOS-card replay never prompts")
    }

    // MARK: - Storage

    func testCountersPersistInTheInjectedStore() {
        seed(launches: 2, bingos: 3)
        XCTAssertEqual(store.integer(forKey: ReviewPromptPolicy.Keys.launchCount), 2)
        XCTAssertEqual(store.integer(forKey: ReviewPromptPolicy.Keys.bingoMoments), 3)
        _ = policy.consumePrompt(afterDismissing: .bingo, isReplay: false, appVersion: "2.0")
        XCTAssertEqual(store.string(forKey: ReviewPromptPolicy.Keys.lastPromptedVersion), "2.0")

        // A fresh policy over the same store sees the same state (a relaunch).
        let reread = ReviewPromptPolicy(store: store)
        XCTAssertFalse(reread.isPromptDue(afterDismissing: .bingo, isReplay: false, appVersion: "2.0"))
    }

    func testUserDefaultsConformsAsAStore() throws {
        let suite = "ReviewPromptPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let onDefaults = ReviewPromptPolicy(store: defaults)
        onDefaults.recordLaunch()
        onDefaults.recordLaunch()
        for _ in 0..<3 { onDefaults.momentOpened(.bingo, isReplay: false) }
        XCTAssertTrue(onDefaults.consumePrompt(afterDismissing: .bingo, isReplay: false, appVersion: "1.0.0"))
        XCTAssertEqual(defaults.string(forKey: ReviewPromptPolicy.Keys.lastPromptedVersion), "1.0.0")
        XCTAssertFalse(onDefaults.consumePrompt(afterDismissing: .bingo, isReplay: false, appVersion: "1.0.0"))
    }
}
