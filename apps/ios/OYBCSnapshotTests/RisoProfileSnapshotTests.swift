import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Riso Profile tab (Phase 5).
///
/// Snapshots the leaf presentational pieces — account card, theme
/// segmented rows, preferences rows (with and without count badge),
/// and the sign-out card (resting and confirm states) — each in
/// light and dark mode.
///
/// These views are all pure-props and need no environment objects,
/// which makes them hostable without AuthService/SyncService stubs.
///
/// `record: .missing` auto-records baselines on the first run.
/// CI overrides with `SNAPSHOT_TESTING_RECORD=never`.
final class RisoProfileSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Account Card

    func testAccountCardLight() {
        let view = accountCardView(
            displayName: "OYBC User",
            email: "you@example.com"
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 96)),
            record: recordMode
        )
    }

    func testAccountCardDark() {
        let view = accountCardView(
            displayName: "OYBC User",
            email: "you@example.com"
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 353, height: 96),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    func testAccountCardNoEmailLight() {
        let view = accountCardView(displayName: "Jane Doe", email: nil)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 96)),
            record: recordMode
        )
    }

    // MARK: - Theme Segmented (App card)

    func testThemeSegmentedSystemLight() {
        let view = themeSegmentedView(selected: .system)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 58)),
            record: recordMode
        )
    }

    func testThemeSegmentedLightModeLight() {
        let view = themeSegmentedView(selected: .light)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 58)),
            record: recordMode
        )
    }

    func testThemeSegmentedDarkModeDark() {
        let view = themeSegmentedView(selected: .dark)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 353, height: 58),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Preferences Row (with and without count badge)

    func testPreferencesRowNoBadgeLight() {
        let view = preferencesRowView(
            icon: "square.grid.3x3",
            label: "Board preferences",
            countBadge: nil
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 54)),
            record: recordMode
        )
    }

    func testPreferencesRowWithBadgeLight() {
        let view = preferencesRowView(
            icon: "calendar.badge.clock",
            label: "Recurring templates",
            countBadge: 3
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 54)),
            record: recordMode
        )
    }

    func testPreferencesRowWithBadgeDark() {
        let view = preferencesRowView(
            icon: "tray.full",
            label: "Default pools",
            countBadge: 2
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 353, height: 54),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Sign Out row — resting

    func testSignOutRowRestingLight() {
        let view = signOutCardView(confirmShown: false)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 54)),
            record: recordMode
        )
    }

    func testSignOutRowRestingDark() {
        let view = signOutCardView(confirmShown: false)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 353, height: 54),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Sign Out confirm

    func testSignOutConfirmLight() {
        let view = signOutCardView(confirmShown: true)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 130)),
            record: recordMode
        )
    }

    func testSignOutConfirmDark() {
        let view = signOutCardView(confirmShown: true)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 353, height: 130),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Composed Profile layout (light + dark)

    func testProfileComposedLight() {
        let view = composedProfileView()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 760)),
            record: recordMode
        )
    }

    func testProfileComposedDark() {
        let view = composedProfileView()
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 760),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Helpers

    private func accountCardView(displayName: String, email: String?) -> some View {
        ZStack {
            Color.risoPaper
            RisoProfileAccountCard(
                displayName: displayName,
                email: email,
                onEditName: {}
            )
            .padding(20)
        }
    }

    /// Renders a static theme row inside a Riso card (no binding mutation).
    private func themeSegmentedView(selected: ThemePreference) -> some View {
        ZStack {
            Color.risoPaper
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.risoInk)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.risoPaper))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))

                    Text("Theme")
                        .font(.risoBody(14, .bold))
                        .foregroundStyle(Color.risoInk)

                    Spacer()

                    // Static (non-binding) segmented for snapshot
                    HStack(spacing: 6) {
                        ForEach([
                            (ThemePreference.system, "System"),
                            (ThemePreference.light, "Light"),
                            (ThemePreference.dark, "Dark"),
                        ], id: \.0) { opt in
                            Text(opt.1)
                                .font(.risoHead(13, .bold))
                                .foregroundStyle(selected == opt.0 ? Color.risoPaper : Color.risoInk)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                                        .fill(selected == opt.0 ? Color.risoBlue : Color.risoPaper2)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                                )
                        }
                    }
                    .fixedSize()
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
            }
            .risoCard()
            .padding(20)
        }
    }

    private func preferencesRowView(icon: String, label: String, countBadge: Int?) -> some View {
        ZStack {
            Color.risoPaper
            RisoProfileRow(
                icon: icon,
                label: label,
                countBadge: countBadge,
                chevron: true
            )
            .risoCard()
            .padding(20)
        }
    }

    /// Renders the sign-out card in either resting or confirm state.
    /// Mirrors the production ProfileView's two branches exactly.
    private func signOutCardView(confirmShown: Bool) -> some View {
        ZStack {
            Color.risoPaper
            Group {
                if confirmShown {
                    signOutConfirmContent
                } else {
                    signOutRestingContent
                }
            }
            .padding(20)
        }
    }

    private var signOutRestingContent: some View {
        RisoProfileRow(
            icon: "escape",
            label: "Sign Out",
            danger: true
        )
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    private var signOutConfirmContent: some View {
        VStack(spacing: 12) {
            Text("Sign out?")
                .font(.risoBody(14, .bold))
                .foregroundStyle(Color.risoRed)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 14)

            HStack(spacing: 10) {
                // Cancel
                Text("Cancel")
                    .font(.risoHead(15, .bold))
                    .foregroundStyle(Color.risoInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .risoCard(fill: .risoPaper2)

                // Sign Out (primary red)
                Text("Sign Out")
                    .font(.risoHead(15, .bold))
                    .foregroundStyle(Color.risoPaper)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .risoCard(fill: .risoRed)
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 14)
        // Dashed-red card border — no solid keyline wrapper (matches production)
        .background(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .fill(Color.risoPaper2)
        )
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(
                    Color.risoRed.opacity(0.6),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        )
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    /// Composed profile layout — header + all cards — without environment
    /// objects. Uses static placeholder values for all live data.
    @ViewBuilder
    private func composedProfileView() -> some View {
        ZStack(alignment: .top) {
            RisoPaperBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Account").risoKicker()
                        Text("Profile").risoH1()
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 16)
                    .padding(.bottom, 18)

                    // Account card
                    RisoProfileAccountCard(
                        displayName: "OYBC User",
                        email: "you@example.com",
                        onEditName: {}
                    )
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 18)

                    // App section label
                    Text("App")
                        .risoSectionLabel()
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 8)

                    // App card — static theme + static sync row
                    VStack(spacing: 0) {
                        themeRowStatic(selected: .system)
                        Divider()
                            .background(Color.risoInk.opacity(0.12))
                            .padding(.horizontal, 14)
                        syncRowStatic
                    }
                    .risoCard()
                    .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 18)

                    // Preferences section label
                    Text("Preferences")
                        .risoSectionLabel()
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 8)

                    // Preferences card
                    VStack(spacing: 0) {
                        RisoProfileRow(
                            icon: "square.grid.3x3",
                            label: "Board preferences",
                            chevron: true
                        )
                        Divider()
                            .background(Color.risoInk.opacity(0.12))
                            .padding(.horizontal, 14)
                        RisoProfileRow(
                            icon: "calendar.badge.clock",
                            label: "Recurring templates",
                            countBadge: 3,
                            chevron: true
                        )
                        Divider()
                            .background(Color.risoInk.opacity(0.12))
                            .padding(.horizontal, 14)
                        RisoProfileRow(
                            icon: "tray.full",
                            label: "Default pools",
                            countBadge: 2,
                            chevron: true
                        )
                    }
                    .risoCard()
                    .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 18)

                    // Sign Out card (resting)
                    RisoProfileRow(
                        icon: "escape",
                        label: "Sign Out",
                        danger: true
                    )
                    .risoCard()
                    .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 14)

                    // Version footer
                    Text("OYBC · v1.0 (1)")
                        .font(.risoBody(11, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 24)
                }
            }
        }
    }

    private func themeRowStatic(selected: ThemePreference) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.risoPaper))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))

            Text("Theme")
                .font(.risoBody(14, .bold))
                .foregroundStyle(Color.risoInk)

            Spacer()

            HStack(spacing: 6) {
                ForEach([
                    (ThemePreference.system, "System"),
                    (ThemePreference.light, "Light"),
                    (ThemePreference.dark, "Dark"),
                ], id: \.0) { opt in
                    Text(opt.1)
                        .font(.risoHead(13, .bold))
                        .foregroundStyle(selected == opt.0 ? Color.risoPaper : Color.risoInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .fill(selected == opt.0 ? Color.risoBlue : Color.risoPaper2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                        )
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    private var syncRowStatic: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.risoPaper))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))

            Text("Sync")
                .font(.risoBody(14, .bold))
                .foregroundStyle(Color.risoInk)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Circle()
                    .fill(Color.risoGreen)
                    .frame(width: 7, height: 7)
                // Mirrors RisoSyncRow's minimal states: "Up to date" /
                // "Syncing…" / "Offline" (no raw errors or timestamps).
                Text("Up to date")
                    .risoSub()
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }
}
