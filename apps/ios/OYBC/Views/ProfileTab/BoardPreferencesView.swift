import SwiftUI

/// BoardPreferencesView — Dedicated sub-page for board-creation defaults.
///
/// Split out from the top-level Profile surface so the primary settings
/// screen stays focused on account + app-level controls. Every control
/// here governs the new-board form and belongs together. Mirrors the web
/// `/profile/board-preferences` page.
struct BoardPreferencesView: View {
    @EnvironmentObject var authService: AuthService

    private var preferences: UserPreferences { authService.userPreferences }

    var body: some View {
        List {
            Section {
                Text("These defaults apply to new boards you create. You can override any of them on a per-board basis.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            Section {
                weekStartRow
                boardSizeRow
                timeframeRow
                centerTypeRow
                randomizeRow
                customCenterNameRow
            }
        }
        .navigationTitle("Board Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Rows

    private var weekStartRow: some View {
        Picker(selection: bind(\.weekStartDay)) {
            Text("Monday").tag(WeekStartDay.monday)
            Text("Sunday").tag(WeekStartDay.sunday)
        } label: {
            Text("Week starts on")
        }
    }

    private var boardSizeRow: some View {
        Picker(selection: bind(\.defaultBoardSize)) {
            Text("3 × 3").tag(DefaultBoardSize.three)
            Text("4 × 4").tag(DefaultBoardSize.four)
            Text("5 × 5").tag(DefaultBoardSize.five)
        } label: {
            Text("Default board size")
        }
    }

    private var timeframeRow: some View {
        Picker(selection: bind(\.defaultTimeframe)) {
            Text("Custom").tag(DefaultTimeframe.custom)
            Text("Daily").tag(DefaultTimeframe.daily)
            Text("Weekly").tag(DefaultTimeframe.weekly)
            Text("Monthly").tag(DefaultTimeframe.monthly)
            Text("Yearly").tag(DefaultTimeframe.yearly)
        } label: {
            Text("Default timeframe")
        }
    }

    private var centerTypeRow: some View {
        Picker(selection: bind(\.defaultCenterType)) {
            Text("Free").tag(DefaultCenterSquareType.free)
            Text("None").tag(DefaultCenterSquareType.none)
        } label: {
            Text("Default center square")
        }
    }

    private var randomizeRow: some View {
        Toggle(isOn: bind(\.defaultRandomize)) {
            Text("Randomize tasks by default")
        }
    }

    private var customCenterNameRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Default custom center name")
            TextField("e.g., Wild Card", text: bind(\.defaultCenterCustomName))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Binding helper

    /// Builds a two-way `Binding` for a single `UserPreferences` field that
    /// writes through `AppDatabase.updateUserPreferences` — which bumps
    /// version/updatedAt and enqueues a sync-queue UPDATE atomically. The
    /// published `currentUser` picks up the change via the
    /// `AuthService` row observation, so no manual refresh is needed.
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
                    // Surface via log — inline alerting would be noisy for
                    // per-keystroke writes. Phase 5 polish can add toast UX.
                    print("⚠️ updateUserPreferences failed: \(error)")
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
