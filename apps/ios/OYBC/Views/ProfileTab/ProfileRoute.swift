import Foundation

/// Profile-tab pushes (sub-pages) carried by `MainTabView`'s bound
/// `profilePath`.
///
/// P7 (Task Pools + Recurring Boards Rework): the former `.recurringTemplates`
/// and `.defaultPools` cases collapsed into one `.boardSettings` case — both
/// pages retired in favor of the single `BoardSettingsView`.
enum ProfileRoute: Hashable {
    case boardSettings
    /// Streaks & history page (handoff §5e).
    case streaks
    /// Settings sub-page (Profile reorg PR1) — Appearance/Preferences/Sign
    /// Out, pushed from the gear button on Profile.
    case settings
    /// Notifications sub-page (Profile reorg PR1) — moved off Profile,
    /// now reachable only from Settings.
    case notifications
    /// Help & getting started sub-page (Profile reorg PR1) — new.
    case help
}
