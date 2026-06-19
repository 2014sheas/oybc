import SwiftUI
import UserNotifications

/// NotificationPreferencesView — Riso-styled Profile sub-page for the Phase 7
/// local-reminder settings.
///
/// Cards:
///   Notifications (master) — opt-in toggle; flipping it on runs the
///     in-context permission priming. Shows a "denied → Open Settings"
///     affordance when iOS notifications are off.
///   Reminders — per-category toggles (board expiring soon · new recurring
///     window · daily play reminder + time), shown only when the master is on
///     and permission isn't denied.
///
/// The view is split into a thin environment-bound container
/// (`NotificationPreferencesView`) and a presentational leaf
/// (`NotificationPreferencesContent`, props + closures) so the leaf is
/// snapshot-testable without Firebase/DB — the same shape the other Riso leaf
/// views use. All writes go through `AppDatabase.updateUserPreferences`; each
/// change re-runs `NotificationService.reconcile` so the OS schedule tracks the
/// settings immediately.
struct NotificationPreferencesView: View {

    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var notificationService: NotificationService
    @State private var showPriming = false

    private var preferences: UserPreferences { authService.userPreferences }

    var body: some View {
        NotificationPreferencesContent(
            preferences: preferences,
            authorizationStatus: notificationService.authorizationStatus,
            onSetMaster: handleSetMaster,
            onSetExpiring: { setPref(\.expiringReminders, $0) },
            onSetRecurringWindow: { setPref(\.recurringWindowReminders, $0) },
            onSetDailyEnabled: { setPref(\.dailyPlayReminderEnabled, $0) },
            onSetDailyTime: setDailyTime,
            onOpenSettings: openSystemSettings
        )
        .navigationBarHidden(true)
        // Refresh the OS status on appear so a change made in iOS Settings
        // (e.g. the user revoked permission) is reflected immediately.
        .task { await notificationService.refreshAuthorizationStatus() }
        .sheet(isPresented: $showPriming, onDismiss: handlePrimingDismiss) { primingSheet }
    }

    // MARK: - Master toggle handling

    /// Master toggle: persist intent, then drive the permission flow. Only the
    /// first opt-in with an undetermined status shows the priming sheet; a
    /// denied status surfaces the inline "Open Settings" affordance instead.
    /// When priming is shown, the schedule reconcile + any roll-back is handled
    /// by `handlePrimingDismiss` (so dismissing the sheet without granting
    /// doesn't leave the toggle on with nothing scheduled).
    private func handleSetMaster(_ newValue: Bool) {
        setPref(\.notificationsEnabled, newValue, reconcileAfter: false)
        if newValue && notificationService.authorizationStatus == .notDetermined {
            showPriming = true
        } else {
            reconcile() // schedules if authorized, clears if off/denied
        }
    }

    /// Runs when the priming sheet closes by ANY path (Allow, Not now, or
    /// swipe-down). If the user never granted permission (still
    /// `.notDetermined`), roll the master toggle back to off so the UI never
    /// shows an "on" state with nothing actually scheduled. A `.denied` outcome
    /// keeps the toggle on so the inline "Open Settings" affordance shows.
    private func handlePrimingDismiss() {
        if notificationService.authorizationStatus == .notDetermined {
            setPref(\.notificationsEnabled, false) // reconciles (clears)
        } else {
            reconcile()
        }
    }

    // MARK: - Priming sheet

    private var primingSheet: some View {
        ZStack {
            RisoPaperBackground().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("Turn on reminders?")
                    .font(.risoHead(22, .extraBold)).foregroundStyle(Color.risoInk)
                Text("OYBC sends a few local reminders — the morning before a board expires, when a new recurring window opens, and an optional daily nudge. No account or marketing messages.")
                    .font(.risoBody(14, .regular)).foregroundStyle(Color.risoMuted)
                    .fixedSize(horizontal: false, vertical: true)
                // Both buttons just close the sheet; `handlePrimingDismiss`
                // (the sheet's onDismiss) does the reconcile / roll-back based
                // on the resulting authorization status.
                RisoButton(title: "Allow notifications", kind: .primary, fullWidth: true) {
                    _Concurrency.Task {
                        await notificationService.requestAuthorization()
                        showPriming = false
                    }
                }
                RisoButton(title: "Not now", kind: .neutral, fullWidth: true) {
                    showPriming = false
                }
            }
            .padding(24)
        }
        .presentationDetents([.medium])
    }

    // MARK: - Helpers

    /// Converts the picker's `Date` to the stored "HH:mm" string.
    private func setDailyTime(_ date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let str = String(format: "%02d:%02d", c.hour ?? 20, c.minute ?? 0)
        setPref(\.dailyPlayReminderTime, str)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func reconcile() {
        guard let userId = authService.currentUser?.id else { return }
        _Concurrency.Task { await notificationService.reconcile(userId: userId) }
    }

    private func setPref<Value>(
        _ keyPath: WritableKeyPath<UserPreferences, Value>,
        _ newValue: Value,
        reconcileAfter: Bool = true
    ) {
        guard let userId = authService.currentUser?.id else { return }
        do {
            _ = try AppDatabase.shared.updateUserPreferences(userId: userId) { current in
                var next = current
                next[keyPath: keyPath] = newValue
                return next
            }
        } catch {
            print("⚠️ NotificationPreferencesView updateUserPreferences failed: \(error)")
        }
        if reconcileAfter { reconcile() }
    }
}

// MARK: - Presentational content (snapshot-testable leaf)

/// Pure-props rendering of the notification settings. No environment, DB, or
/// Firebase dependency — emits changes through closures so it can be rendered
/// in snapshot tests with a plain `UserPreferences` value.
struct NotificationPreferencesContent: View {

    let preferences: UserPreferences
    let authorizationStatus: UNAuthorizationStatus
    var onSetMaster: (Bool) -> Void = { _ in }
    var onSetExpiring: (Bool) -> Void = { _ in }
    var onSetRecurringWindow: (Bool) -> Void = { _ in }
    var onSetDailyEnabled: (Bool) -> Void = { _ in }
    var onSetDailyTime: (Date) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}

    private var isDenied: Bool { authorizationStatus == .denied }
    private var masterOn: Bool { preferences.notificationsEnabled }
    /// Categories are editable only when the user has opted in and iOS hasn't
    /// denied permission.
    private var showCategories: Bool { masterOn && !isDenied }

    var body: some View {
        ZStack {
            RisoPaperBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    RisoSubPageHeader(title: "Notifications")
                        .padding(.top, 16).padding(.bottom, 20)

                    sectionLabel("Notifications")
                    masterCard.padding(.horizontal, Riso.gutter).padding(.bottom, 18)

                    if showCategories {
                        sectionLabel("Reminders")
                        remindersCard.padding(.horizontal, Riso.gutter).padding(.bottom, 16)
                    }

                    Text("Reminders are scheduled on this device from your boards — no account messages, no marketing.")
                        .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        .padding(.horizontal, Riso.gutter).padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - Master card

    private var masterCard: some View {
        VStack(spacing: 0) {
            toggleRow(icon: "bell", label: "Allow notifications",
                      value: masterOn, onChange: onSetMaster)
            if masterOn && isDenied {
                rowDivider
                deniedRow
            }
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    private var deniedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications are turned off for OYBC in iOS Settings.")
                .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                .fixedSize(horizontal: false, vertical: true)
            RisoButton(title: "Open Settings", kind: .neutral, small: true, action: onOpenSettings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Riso.cardPadding).padding(.vertical, 12)
    }

    // MARK: - Reminders card

    private var remindersCard: some View {
        VStack(spacing: 0) {
            captionedToggle(
                icon: "exclamationmark.circle", label: "Board expiring soon",
                caption: "A reminder the morning before a board's deadline.",
                value: preferences.expiringReminders, onChange: onSetExpiring)
            rowDivider
            captionedToggle(
                icon: "arrow.triangle.2.circlepath", label: "New recurring window",
                caption: "When a new weekly, monthly, or yearly board is ready to set up.",
                value: preferences.recurringWindowReminders, onChange: onSetRecurringWindow)
            rowDivider
            captionedToggle(
                icon: "clock", label: "Daily play reminder",
                caption: "A daily nudge to make progress on your boards.",
                value: preferences.dailyPlayReminderEnabled, onChange: onSetDailyEnabled)
            if preferences.dailyPlayReminderEnabled {
                rowDivider
                timeRow
            }
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    private var timeRow: some View {
        HStack(spacing: 12) {
            iconSquare(systemName: "alarm")
            Text("Reminder time").font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
            Spacer()
            DatePicker("", selection: reminderTimeBinding, displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
        .padding(.horizontal, Riso.cardPadding).padding(.vertical, 12)
    }

    /// Bridges the stored "HH:mm" string to the `DatePicker`'s `Date`. Anchors
    /// the time to today's start-of-day (a time-only `DateComponents` is
    /// underspecified and can yield a stray date) and reuses the canonical
    /// `NotificationPlanner.parseReminderTime` so the parse rules don't drift.
    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                guard let (hour, minute) =
                    NotificationPlanner.parseReminderTime(preferences.dailyPlayReminderTime)
                else { return Date() }
                let base = Calendar.current.startOfDay(for: Date())
                return Calendar.current.date(
                    bySettingHour: hour, minute: minute, second: 0, of: base
                ) ?? Date()
            },
            set: { onSetDailyTime($0) }
        )
    }

    // MARK: - Row helpers (mirror BoardPreferencesView)

    private func sectionLabel(_ title: String) -> some View {
        Text(title).risoSectionLabel()
            .padding(.horizontal, Riso.gutter).padding(.bottom, 8)
    }

    private func toggleRow(
        icon: String, label: String, value: Bool, onChange: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            iconSquare(systemName: icon)
            Text(label).font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
            Spacer()
            RisoPillSwitch(isOn: Binding(get: { value }, set: { onChange($0) }))
        }
        .padding(.horizontal, Riso.cardPadding).padding(.vertical, 12)
    }

    private func captionedToggle(
        icon: String, label: String, caption: String,
        value: Bool, onChange: @escaping (Bool) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            toggleRow(icon: icon, label: label, value: value, onChange: onChange)
            Text(caption)
                .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Riso.cardPadding).padding(.bottom, 8)
        }
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
}

// MARK: - Preview

#Preview("Enabled") {
    var prefs = UserPreferences.defaults
    prefs.notificationsEnabled = true
    prefs.dailyPlayReminderEnabled = true
    return NotificationPreferencesContent(preferences: prefs, authorizationStatus: .authorized)
}

#Preview("Denied") {
    var prefs = UserPreferences.defaults
    prefs.notificationsEnabled = true
    return NotificationPreferencesContent(preferences: prefs, authorizationStatus: .denied)
}
