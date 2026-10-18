import Foundation

// MARK: - ReviewPromptStore

/// The key-value storage `ReviewPromptPolicy` reads and writes. `UserDefaults`
/// conforms as-is; tests inject an in-memory store.
protocol ReviewPromptStore: AnyObject {
    /// The stored integer for `key`, or 0 when absent.
    func integer(forKey key: String) -> Int
    /// The stored string for `key`, or nil when absent.
    func string(forKey key: String) -> String?
    /// Stores an integer under `key`.
    func set(_ value: Int, forKey key: String)
    /// Stores any property-list value (here: a version string) under `key`.
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: ReviewPromptStore {}

// MARK: - ReviewPromptPolicy

/// When to ask for an App Store review (Track L5): right after a Bingo moment
/// closes via "Back to board", once this device has shown its third earned
/// Bingo moment — never on the app's first launch, and at most once per app
/// version (`CFBundleShortVersionString`). iOS-only; web has no store prompt.
///
/// Pure over an injected store, so the rules are unit-tested without a view.
/// Device-local state (UserDefaults), never synced. Only earned Bingo moments
/// count: a Greenlog moment, a replay from the BINGOS card and the tutorial's
/// sample overlays (which never route through the board play surface) neither
/// count nor prompt. The system still applies its own display throttle.
struct ReviewPromptPolicy {

    /// The earned Bingo moment from which a dismissal may prompt.
    static let bingoMomentThreshold = 3
    /// Launches before a prompt may show — the first launch never prompts.
    static let minimumLaunches = 2

    /// The storage keys (device-local, `oybc-` prefixed like the other
    /// UserDefaults flags).
    enum Keys {
        static let launchCount = "oybc-review-prompt-launch-count"
        static let bingoMoments = "oybc-review-prompt-bingo-moments"
        static let lastPromptedVersion = "oybc-review-prompt-last-version"
    }

    /// The live policy over `UserDefaults.standard`.
    static let live = ReviewPromptPolicy(store: UserDefaults.standard)

    /// Where the counters and the last-prompted version live.
    let store: ReviewPromptStore

    /// The running app's marketing version (`CFBundleShortVersionString`), or
    /// nil when the bundle carries none.
    static var currentAppVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Counts one app launch. Called once per process start.
    func recordLaunch() {
        store.set(store.integer(forKey: Keys.launchCount) + 1, forKey: Keys.launchCount)
    }

    /// Counts a moment that just opened, when it is an earned Bingo.
    ///
    /// - Parameters:
    ///   - kind: The moment's kind; only `.bingo` counts.
    ///   - isReplay: True for a replay of an already-earned moment (BINGOS
    ///     card) — never counted.
    func momentOpened(_ kind: MomentTrigger.Kind, isReplay: Bool) {
        guard kind == .bingo, !isReplay else { return }
        store.set(store.integer(forKey: Keys.bingoMoments) + 1, forKey: Keys.bingoMoments)
    }

    /// Whether a review prompt is due now that a moment was dismissed via
    /// "Back to board". Pure read — call `recordPrompted(appVersion:)` once the
    /// prompt is actually requested.
    ///
    /// - Parameters:
    ///   - kind: The dismissed moment's kind; only an earned `.bingo` prompts.
    ///   - isReplay: True for a BINGOS-card replay — never prompts.
    ///   - appVersion: The running marketing version; nil or empty never prompts.
    /// - Returns: True when every rule passes.
    func isPromptDue(afterDismissing kind: MomentTrigger.Kind, isReplay: Bool, appVersion: String?) -> Bool {
        guard kind == .bingo, !isReplay, let appVersion, !appVersion.isEmpty else { return false }
        return store.integer(forKey: Keys.launchCount) >= Self.minimumLaunches
            && store.integer(forKey: Keys.bingoMoments) >= Self.bingoMomentThreshold
            && store.string(forKey: Keys.lastPromptedVersion) != appVersion
    }

    /// Records that the prompt was requested for `appVersion`, so this
    /// version never asks again.
    ///
    /// - Parameter appVersion: The running marketing version.
    func recordPrompted(appVersion: String) {
        store.set(appVersion, forKey: Keys.lastPromptedVersion)
    }

    /// `isPromptDue` + `recordPrompted` in one step — the call site's single
    /// question.
    ///
    /// - Parameters:
    ///   - kind: The dismissed moment's kind.
    ///   - isReplay: True for a BINGOS-card replay.
    ///   - appVersion: The running marketing version.
    /// - Returns: True when the caller should request a review now (already
    ///   recorded as prompted for `appVersion`).
    func consumePrompt(afterDismissing kind: MomentTrigger.Kind, isReplay: Bool, appVersion: String?) -> Bool {
        guard isPromptDue(afterDismissing: kind, isReplay: isReplay, appVersion: appVersion),
              let appVersion else { return false }
        recordPrompted(appVersion: appVersion)
        return true
    }
}
