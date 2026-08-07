import SwiftUI

/// BoardPreferencesView — Riso-styled Profile sub-page for board-creation
/// defaults and play-feel settings. Design: §5a README + screenshot 08.
///
/// Two keyline cards:
///   New boards — Default size · Center square · Week starts
///   Playing    — Celebration intensity (10-tick strip) · Haptics toggle
///
/// `expiringReminders` moved to `NotificationPreferencesView` in Phase 7 (it's
/// now a live notification toggle, not a dead housekeeping flag). The
/// Housekeeping card's Auto-archive completed toggle was removed — it never
/// had a consumer (no archive logic read it on either platform).
///
/// All controls write through `AppDatabase.updateUserPreferences` via the
/// `bind(_:)` helper. New fields (`celebrationIntensity`, `haptics`) were
/// added to `UserPreferences` as part of this reskin; they decode
/// forward-compatibly via try? fallback.
struct BoardPreferencesView: View {

    @EnvironmentObject var authService: AuthService

    private var preferences: UserPreferences { authService.userPreferences }

    var body: some View {
        ZStack {
            RisoPaperBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    RisoSubPageHeader(title: "Board preferences")
                        .padding(.top, 16).padding(.bottom, 20)

                    sectionLabel("New boards")
                    newBoardsCard.padding(.horizontal, Riso.gutter).padding(.bottom, 18)

                    sectionLabel("Playing")
                    playingCard.padding(.horizontal, Riso.gutter).padding(.bottom, 16)

                    Text("Defaults apply to new boards — existing boards keep their settings.")
                        .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        .padding(.horizontal, Riso.gutter).padding(.bottom, 24)
                }
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Section label

    private func sectionLabel(_ title: String) -> some View {
        Text(title).risoSectionLabel()
            .padding(.horizontal, Riso.gutter).padding(.bottom, 8)
    }

    // MARK: - New Boards card

    private var newBoardsCard: some View {
        VStack(spacing: 0) {
            segRow(label: "Default size",
                   options: [(DefaultBoardSize.three, "3×3"),
                             (DefaultBoardSize.four, "4×4"),
                             (DefaultBoardSize.five, "5×5")],
                   selection: bind(\.defaultBoardSize))
            rowDivider
            segRow(label: "Center square",
                   options: [(DefaultCenterSquareType.free, "Free"),
                             (DefaultCenterSquareType.none, "None")],
                   selection: bind(\.defaultCenterType))
            rowDivider
            VStack(alignment: .leading, spacing: 4) {
                segRow(label: "Week starts",
                       options: [(WeekStartDay.monday, "Mon"),
                                 (WeekStartDay.sunday, "Sun")],
                       selection: bind(\.weekStartDay))
                Text("Sets when weekly boards reset and renew.")
                    .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                    .padding(.horizontal, Riso.cardPadding).padding(.bottom, 10)
            }
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    // MARK: - Playing card

    private var playingCard: some View {
        VStack(spacing: 0) {
            intensityRow
            rowDivider
            toggleRow(icon: "hand.tap", label: "Haptics", binding: bind(\.haptics))
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    private var intensityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                iconSquare(systemName: "sparkles")
                Text("Celebration intensity")
                    .font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
                Spacer()
                Text("\(preferences.celebrationIntensity) · \(intensityWord(preferences.celebrationIntensity))")
                    .font(.risoBody(12, .semibold)).foregroundStyle(Color.risoMuted)
            }
            intensityStrip
            Text("How loud bingos and GREENLOGs get — confetti scales with it.")
                .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
        }
        .padding(.horizontal, Riso.cardPadding)
        .padding(.vertical, 12)
    }

    private var intensityStrip: some View {
        let current = preferences.celebrationIntensity
        let intensityBind = bind(\.celebrationIntensity)
        return HStack(spacing: 5) {
            ForEach(1...10, id: \.self) { tick in
                Button { intensityBind.wrappedValue = tick } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(tickFill(tick: tick, current: current))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Fill color for a single intensity strip tick.
    ///
    /// - Ticks 1–7 up to `current` fill gold.
    /// - Ticks 8–10 up to `current` fill red ("hot").
    /// - Ticks beyond `current` remain paper.
    private func tickFill(tick: Int, current: Int) -> Color {
        guard tick <= current else { return .risoPaper }
        return tick >= 8 ? .risoRed : .risoGold
    }

    /// Human-readable intensity word for caption label (matches prototype).
    private func intensityWord(_ v: Int) -> String {
        switch v {
        case 1, 2: return "Whisper"
        case 3, 4: return "Quiet"
        case 5, 6: return "Steady"
        case 7, 8: return "Full press"
        case 9: return "Loud"
        default: return "Detonate"
        }
    }

    // MARK: - Row helpers

    private func segRow<V: Hashable>(
        label: String,
        options: [(V, String)],
        selection: Binding<V>
    ) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
                .frame(minWidth: 80, alignment: .leading)
            Spacer()
            // Sizes-to-content (not `.fixedSize()`, which collapsed the
            // equal-width layout into mismatched, clipping pills).
            RisoSegmented(options: options.map { (value: $0.0, label: $0.1) },
                          selection: selection,
                          equalWidth: false)
        }
        .padding(.horizontal, Riso.cardPadding)
        .padding(.vertical, 12)
    }

    private func toggleRow(icon: String, label: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            iconSquare(systemName: icon)
            Text(label).font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
            Spacer()
            RisoPillSwitch(isOn: binding)
        }
        .padding(.horizontal, Riso.cardPadding)
        .padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Divider().background(Color.risoInk.opacity(0.12))
            .padding(.horizontal, Riso.cardPadding)
    }

    private func iconSquare(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.risoInk)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.risoPaper))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    // MARK: - Binding helper

    /// Two-way Binding for a UserPreferences field that writes through
    /// AppDatabase.updateUserPreferences (bumps version/updatedAt + enqueues sync).
    private func bind<Value>(
        _ keyPath: WritableKeyPath<UserPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { newValue in
                guard let userId = authService.currentUser?.id else { return }
                do {
                    _ = try AppDatabase.shared.updateUserPreferences(userId: userId) { current in
                        var next = current
                        next[keyPath: keyPath] = newValue
                        return next
                    }
                } catch {
                    dlog("⚠️ BoardPreferencesView updateUserPreferences failed: \(error)")
                }
            }
        )
    }
}

#Preview {
    NavigationStack {
        BoardPreferencesView()
            .environmentObject(AuthService())
    }
}
