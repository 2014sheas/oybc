import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `SettingsView` (Profile reorg PR1).
///
/// `SettingsView` is `@EnvironmentObject`-bound to `AuthService` (Firebase-
/// backed), so — same convention as `RisoProfileSnapshotTests`' composed
/// Profile mock and the CLAUDE.md snapshot-testing sharp edge on
/// `@EnvironmentObject AuthService` — this renders a STATIC reconstruction
/// of the screen with hardcoded values rather than hosting the real
/// environment-bound view.
///
/// `record: .missing` auto-records baselines on the first run.
/// CI overrides with `SNAPSHOT_TESTING_RECORD=never`.
final class SettingsSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Signed-in

    func testSignedInLight() {
        assertSnapshot(
            of: composedSettingsView(isGuest: false),
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    func testSignedInDark() {
        assertSnapshot(
            of: composedSettingsView(isGuest: false),
            as: .image(
                layout: .fixed(width: 393, height: 700),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Guest (docs/GUEST_MODE.md §Phase 3/5)

    func testGuestLight() {
        assertSnapshot(
            of: composedSettingsView(isGuest: true),
            as: .image(layout: .fixed(width: 393, height: 780)),
            record: recordMode
        )
    }

    // MARK: - Composed Settings layout

    /// Static reconstruction of `SettingsView`'s body. Mirrors the
    /// production layout: kicker/title header → APPEARANCE card (Theme) →
    /// PREFERENCES card (Notifications w/ caption, Account & security
    /// [signed-in only], Help & getting started) → Sign Out / guest cards
    /// → version footer.
    @ViewBuilder
    private func composedSettingsView(isGuest: Bool) -> some View {
        ZStack(alignment: .top) {
            RisoPaperBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Header (back chevron omitted — no live NavigationStack
                    // in a snapshot host; RisoSubPageHeader itself is
                    // covered by other sub-page snapshots).
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Profile").risoKicker()
                        Text("Settings").risoH2()
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 20)

                    sectionLabel("Appearance")
                    appearanceCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)

                    sectionLabel("Preferences")
                    preferencesCard(isGuest: isGuest)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)

                    if isGuest {
                        guestUpgradeCard
                            .padding(.horizontal, Riso.gutter)
                            .padding(.bottom, 12)
                        discardGuestDataCard
                            .padding(.horizontal, Riso.gutter)
                            .padding(.bottom, 14)
                    } else {
                        signOutRestingCard
                            .padding(.horizontal, Riso.gutter)
                            .padding(.bottom, 14)
                    }

                    Text("OYBC · v1.0 (1)")
                        .font(.risoBody(11, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 24)
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .risoSectionLabel()
            .padding(.horizontal, Riso.gutter)
            .padding(.bottom, 8)
    }

    private var appearanceCard: some View {
        HStack(spacing: 12) {
            iconSquare("sun.max")
            Text("Theme").font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
            Spacer()
            HStack(spacing: 6) {
                ForEach([("System", true), ("Light", false), ("Dark", false)], id: \.0) { opt in
                    Text(opt.0)
                        .font(.risoHead(13, .bold))
                        .foregroundStyle(opt.1 ? Color.risoPaper : Color.risoInk)
                        .padding(.vertical, 10).padding(.horizontal, 14)
                        .background(RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .fill(opt.1 ? Color.risoBlue : Color.risoPaper2))
                        .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, Riso.cardPadding)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    private func preferencesCard(isGuest: Bool) -> some View {
        VStack(spacing: 0) {
            RisoProfileRow(
                icon: "bell",
                label: "Notifications",
                caption: "Reminders on · 8:00 PM · Renewals on",
                chevron: true
            )
            if !isGuest {
                rowDivider
                RisoProfileRow(icon: "lock.shield", label: "Account & security", chevron: true)
            }
            rowDivider
            RisoProfileRow(icon: "checkmark.circle", label: "Help & getting started", chevron: true)
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    private var signOutRestingCard: some View {
        RisoProfileRow(icon: "escape", label: "Sign Out", danger: true)
            .risoCard()
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    // MARK: - Guest cards (ported verbatim from RisoProfileSnapshotTests'
    // sign-out reference — same shape, guest copy)

    private var guestUpgradeCard: some View {
        Text("Save your account")
            .font(.risoHead(17, .bold))
            .foregroundStyle(Color.risoPaper)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .risoCard(fill: .risoRed)
        .padding(Riso.cardPadding)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    private var discardGuestDataCard: some View {
        RisoProfileRow(icon: "trash", label: "Discard guest data", danger: true)
            .risoCard()
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    private func iconSquare(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.risoInk)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.risoPaper))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    private var rowDivider: some View {
        Divider().background(Color.risoInk.opacity(0.12)).padding(.horizontal, Riso.cardPadding)
    }
}
