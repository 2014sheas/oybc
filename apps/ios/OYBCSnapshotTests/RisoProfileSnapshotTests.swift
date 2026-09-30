import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Profile-home screen (Profile reorg PR2,
/// `design_handoff_profile_reorg/README.md` §1: identity header, day-one
/// hero / tiles / Getting-started row, Shared counters).
///
/// `ProfileView` itself is `@EnvironmentObject`-bound to `AuthService`
/// (Firebase-backed) AND owns a `@StateObject ProfileHomeViewModel` that
/// reads the live DB on `.onAppear` — same reason `SettingsSnapshotTests`
/// gives for not hosting `SettingsView` directly. This composes the SAME
/// pure-props components `ProfileView` itself renders
/// (`RisoProfileIdentityHeader`, `RisoProfileTile` + its three tile-content
/// views, `RisoGettingStartedHero`, `RisoProfileRow`,
/// `ProfileCountersSection`) with static fixture data, so a change to any
/// of those components is picked up here automatically — this is NOT a
/// hand-duplicated markup copy the way the old (PR1-era) composed-Profile
/// snapshot was.
///
/// `record: .missing` auto-records baselines on the first run.
/// CI overrides with `SNAPSHOT_TESTING_RECORD=never`.
final class RisoProfileSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Fixture counters (matches the design handoff's own example values)

    private var pushUps: SharedCounterGroup {
        SharedCounterGroup(
            counterId: "push-ups", name: "Push-ups", action: "Do", unit: "reps",
            lifetime: 512, tasks: [], taskCount: 2, boardCount: 2, activeTaskCount: 2
        )
    }

    private var pagesRead: SharedCounterGroup {
        SharedCounterGroup(
            counterId: "pages-read", name: "Pages read", action: "Read", unit: "pages",
            lifetime: 1240, tasks: [], taskCount: 1, boardCount: 1, activeTaskCount: 1
        )
    }

    // MARK: - Populated (light + dark)

    func testPopulatedLight() {
        assertSnapshot(
            of: composedProfileHome(),
            as: .image(layout: .fixed(width: 393, height: 640)),
            record: recordMode
        )
    }

    func testPopulatedDark() {
        assertSnapshot(
            of: composedProfileHome(),
            as: .image(
                layout: .fixed(width: 393, height: 640),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Day-one (completedCount == 0 — gold hero above the tiles)

    func testDayOneHeroLight() {
        let view = composedProfileHome(
            boardSummary: .init(defaultsLine: "Defaults 3×3 · Free · Mon", repeatingLine: "No repeating boards yet"),
            streak: nil,
            gettingStarted: .dayOneHero,
            tutorialDone: 0,
            counters: [],
            totalCounterCount: 0
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 820)),
            record: recordMode
        )
    }

    func testDayOneHeroDark() {
        let view = composedProfileHome(
            boardSummary: .init(defaultsLine: "Defaults 3×3 · Free · Mon", repeatingLine: "No repeating boards yet"),
            streak: nil,
            gettingStarted: .dayOneHero,
            tutorialDone: 0,
            counters: [],
            totalCounterCount: 0
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 820),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Tutorial complete (isComplete == true — no row, no hero)

    func testTutorialCompleteLight() {
        let view = composedProfileHome(gettingStarted: .hidden)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 560)),
            record: recordMode
        )
    }

    func testTutorialCompleteDark() {
        let view = composedProfileHome(gettingStarted: .hidden)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 560),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Empty streak + empty counters

    func testEmptyStreakAndCountersLight() {
        let view = composedProfileHome(
            boardSummary: .init(defaultsLine: "Defaults 3×3 · Free · Mon", repeatingLine: "No repeating boards yet"),
            streak: nil,
            gettingStarted: .hidden,
            counters: [],
            totalCounterCount: 0
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 560)),
            record: recordMode
        )
    }

    func testEmptyStreakAndCountersDark() {
        let view = composedProfileHome(
            boardSummary: .init(defaultsLine: "Defaults 3×3 · Free · Mon", repeatingLine: "No repeating boards yet"),
            streak: nil,
            gettingStarted: .hidden,
            counters: [],
            totalCounterCount: 0
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 560),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Guest

    func testGuestLight() {
        let view = composedProfileHome(displayName: "OYBC User", email: nil, isGuest: true)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 640)),
            record: recordMode
        )
    }

    // MARK: - Composed Profile-home helper

    /// Assembles the same pure-props components `ProfileView` composes, in
    /// the same order, with static fixture data standing in for
    /// `AuthService`/`TutorialProgressStore`/`ProfileHomeViewModel`.
    @ViewBuilder
    private func composedProfileHome(
        displayName: String = "Alex Rivera",
        email: String? = "alex@example.com",
        isGuest: Bool = false,
        boardSummary: ProfileHomeViewModel.BoardSettingsTileSummary = .init(
            defaultsLine: "Defaults 3×3 · Free · Mon", repeatingLine: "2 repeating boards"
        ),
        streak: ProfileHomeViewModel.StreakStats? = .init(bingoStreak: 12, longestStreak: 24, greenlogCount: 37),
        gettingStarted: ProfileHomeViewModel.GettingStartedDisplay = .row,
        tutorialDone: Int = 3,
        nextLessonTitle: String? = "Score a bingo",
        counters: [SharedCounterGroup]? = nil,
        totalCounterCount: Int = 3
    ) -> some View {
        let resolvedCounters = counters ?? [pushUps, pagesRead]
        ZStack(alignment: .top) {
            RisoPaperBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    identityRow(displayName: displayName, email: email, isGuest: isGuest)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.top, 16)
                        .padding(.bottom, 18)

                    if gettingStarted == .dayOneHero {
                        RisoGettingStartedHero(
                            done: tutorialDone, total: TutorialProgressStore.totalLessons, onStart: {}
                        )
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)
                    }

                    tilesRow(boardSummary: boardSummary, streak: streak)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)

                    if gettingStarted == .row {
                        Button {} label: {
                            RisoProfileRow(
                                icon: "checkmark.circle",
                                label: "Getting started",
                                caption: nextLessonTitle.map { "Next: \($0)" },
                                value: "\(tutorialDone)/\(TutorialProgressStore.totalLessons)",
                                chevron: true
                            )
                        }
                        .buttonStyle(.plain)
                        .risoCard()
                        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)
                    }

                    ProfileCountersSection(
                        groups: resolvedCounters,
                        totalCount: totalCounterCount,
                        onOpenHub: {}, onOpenDetail: { _ in }, onNewCounter: {}, onLog: { _ in }
                    )
                    .padding(.bottom, 32)
                }
            }
        }
    }

    private func identityRow(displayName: String, email: String?, isGuest: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RisoProfileIdentityHeader(
                displayName: displayName, email: email, isGuest: isGuest, onEditName: {}
            )
            Button {} label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 40, height: 40)
                    .risoCard(fill: .risoPaper2)
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small))
        }
    }

    /// `streak == nil` renders the dashed empty-streak tile.
    private func tilesRow(
        boardSummary: ProfileHomeViewModel.BoardSettingsTileSummary,
        streak: ProfileHomeViewModel.StreakStats?
    ) -> some View {
        HStack(spacing: 12) {
            Button {} label: {
                RisoProfileTile {
                    ProfileBoardSettingsTileContent(
                        defaultsLine: boardSummary.defaultsLine, repeatingLine: boardSummary.repeatingLine
                    )
                }
            }
            .buttonStyle(RisoProfileTileButtonStyle())

            Button {} label: {
                if let streak {
                    RisoProfileTile(fill: .risoGold) {
                        ProfileStreakTileContent(
                            bingoStreak: streak.bingoStreak,
                            longestStreak: streak.longestStreak,
                            greenlogCount: streak.greenlogCount
                        )
                    }
                } else {
                    RisoProfileTile(dashed: true) { ProfileEmptyStreakTileContent() }
                }
            }
            .buttonStyle(RisoProfileTileButtonStyle(offset: streak != nil ? Riso.Shadow.card : nil))
        }
    }
}
