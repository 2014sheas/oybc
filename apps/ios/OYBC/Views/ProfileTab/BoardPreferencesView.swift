import SwiftUI

/// BoardPreferencesView — Dedicated sub-page for board-creation defaults.
///
/// Split out from the top-level Profile surface so the primary settings
/// screen stays focused on account + app-level controls. Every control
/// here governs the new-board form and belongs together. Mirrors the web
/// `/profile/board-preferences` page.
struct BoardPreferencesView: View {
    @EnvironmentObject var authService: AuthService

    /// Local draft for free-form text fields so every keystroke doesn't
    /// bump `version` and enqueue a sync item. Commits on submit/blur via
    /// `@FocusState`.
    @State private var centerCustomNameDraft: String = ""
    @FocusState private var centerCustomNameFocused: Bool

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
                customCenterNameRow
            }

            // Phase 6.1 — Recurring boards. Independent section because
            // these toggles drive the Boards-tab banner, not new-board
            // defaults.
            Section {
                Text("When enabled, the Boards tab will prompt you to create a board for each new window. Detection runs only when you open the app — no background notifications.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Recurring Boards")
            }
            .listRowBackground(Color.clear)

            Section {
                Toggle(isOn: bind(\.recurringDailyEnabled)) {
                    Text("Prompt for daily board")
                }
                if authService.userPreferences.recurringDailyEnabled {
                    browseRow(timeframe: .daily, label: "Daily")
                }
                Toggle(isOn: bind(\.recurringWeeklyEnabled)) {
                    Text("Prompt for weekly board")
                }
                if authService.userPreferences.recurringWeeklyEnabled {
                    browseRow(timeframe: .weekly, label: "Weekly")
                }
                Toggle(isOn: bind(\.recurringMonthlyEnabled)) {
                    Text("Prompt for monthly board")
                }
                if authService.userPreferences.recurringMonthlyEnabled {
                    browseRow(timeframe: .monthly, label: "Monthly")
                }
                Toggle(isOn: bind(\.recurringYearlyEnabled)) {
                    Text("Prompt for yearly board")
                }
                if authService.userPreferences.recurringYearlyEnabled {
                    browseRow(timeframe: .yearly, label: "Yearly")
                }
            }
        }
        .navigationTitle("Board Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Phase B — open the per-timeframe core-board browser. Pushed
    /// directly onto the ProfileTab's NavigationStack via
    /// `NavigationLink(value:)`; the destination is registered on
    /// ProfileView so back returns to this preferences screen.
    @ViewBuilder
    private func browseRow(timeframe: Timeframe, label: String) -> some View {
        NavigationLink(value: CoreBrowserRoute(timeframe: timeframe)) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(.tint)
                Text("Browse \(label) boards")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityLabel("Browse \(label) core boards")
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

    private var customCenterNameRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Default custom center name")
            TextField("e.g., Wild Card", text: $centerCustomNameDraft)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .focused($centerCustomNameFocused)
                .submitLabel(.done)
                .onSubmit { commitCenterCustomNameDraft() }
                .onAppear { centerCustomNameDraft = preferences.defaultCenterCustomName }
                .onChange(of: preferences.defaultCenterCustomName) { _, newValue in
                    // Keep the local draft in sync when the underlying
                    // preference changes externally (e.g. pulled from
                    // another device) but the field isn't currently being
                    // edited.
                    if !centerCustomNameFocused {
                        centerCustomNameDraft = newValue
                    }
                }
                .onChange(of: centerCustomNameFocused) { wasFocused, isFocused in
                    if wasFocused && !isFocused {
                        commitCenterCustomNameDraft()
                    }
                }
        }
        .padding(.vertical, 4)
    }

    /// Writes the draft through to synced preferences only if it actually
    /// differs from the current stored value — prevents a no-op write
    /// (and its attendant version bump + sync item) when the user tabs
    /// through the field without changing anything.
    private func commitCenterCustomNameDraft() {
        let trimmed = centerCustomNameDraft
        guard trimmed != preferences.defaultCenterCustomName,
              let userId = authService.currentUser?.id else { return }
        do {
            _ = try AppDatabase.shared.updateUserPreferences(userId: userId) { current in
                var next = current
                next.defaultCenterCustomName = trimmed
                return next
            }
        } catch {
            print("⚠️ updateUserPreferences(defaultCenterCustomName) failed: \(error)")
        }
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
