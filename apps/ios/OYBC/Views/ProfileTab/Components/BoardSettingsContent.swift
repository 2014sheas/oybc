import SwiftUI

/// BoardSettingsContent — presentational leaf for the Board settings
/// sub-page (Profile reorg PR3, `design_handoff_profile_reorg/README.md`
/// §4 "Board settings (frame #4c) — restructured"). No environment, DB, or
/// Firebase dependency — emits changes through closures so it's snapshot-
/// testable in isolation, the same container/leaf split
/// `NotificationPreferencesView`/`NotificationPreferencesContent` already
/// use.
///
/// Three groups, in order:
/// 1. "EVERY NEW BOARD" — Size / Timeframe (full-width 5-segment row) /
///    Center square / Week starts + helper.
/// 2. "PRE-FILLED TASKS BY TIMEFRAME" — the four core-defaults rows.
/// 3. "REPEATING BOARDS" (trailing "New ›" link) — one composite card,
///    one compact `RecurringTemplateCard` row per template, divided.
/// Footer helper verbatim below the roster.
struct BoardSettingsContent: View {

    let preferences: UserPreferences
    let coreDefaultsByTimeframe: [Timeframe: CoreBoardDefault]
    let poolsById: [String: Pool]
    let tasksById: [String: Task]
    let templates: [RecurringBoardTemplate]
    /// Non-nil entries surface a `RecurringTemplateCard` attention badge.
    let attentionByTemplateId: [String: SpawnAttentionReason]
    /// Current resolved mix count per template — see `RecurringTemplateCard.
    /// poolTaskCount`'s doc for why this can't just be `seedTaskIds.count`.
    var taskCountByTemplateId: [String: Int] = [:]
    var loadError: String? = nil

    var onSetDefaultSize: (DefaultBoardSize) -> Void = { _ in }
    var onSetDefaultTimeframe: (DefaultTimeframe) -> Void = { _ in }
    var onSetCenterType: (DefaultCenterSquareType) -> Void = { _ in }
    var onSetWeekStart: (WeekStartDay) -> Void = { _ in }
    var onTapDefaultsRow: (Timeframe) -> Void = { _ in }
    var onNewRepeatingBoard: () -> Void = {}
    var onTapTemplate: (RecurringBoardTemplate) -> Void = { _ in }
    var onToggleTemplateActive: (RecurringBoardTemplate, Bool) -> Void = { _, _ in }

    /// `.custom` is excluded — same reason as everywhere else in this
    /// feature: a "default" tied to a computed recurring window has no
    /// semantic for a custom-window board.
    private static let coreTimeframes: [Timeframe] = [.daily, .weekly, .monthly, .yearly]

    var body: some View {
        ZStack {
            RisoPaperBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    RisoSubPageHeader(title: "Board settings")
                        .padding(.top, 16)
                        .padding(.bottom, 20)

                    sectionLabel("Every new board")
                    newBoardsCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 20)

                    sectionLabel("Pre-filled tasks by timeframe")
                    VStack(spacing: 10) {
                        ForEach(Self.coreTimeframes, id: \.self) { tf in
                            defaultsRow(tf)
                        }
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 20)

                    repeatingBoardsHeader
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 8)
                    rosterCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 10)

                    Text("Tap a board to edit its pool and cadence. Renewal reminders are under Settings › Notifications.")
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 20)

                    if let loadError {
                        Text(loadError)
                            .font(.risoBody(12, .regular)).foregroundStyle(Color.risoRed)
                            .padding(.horizontal, Riso.gutter).padding(.bottom, 12)
                    }
                }
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Section label

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .risoSectionLabel()
            .padding(.horizontal, Riso.gutter)
            .padding(.bottom, 8)
    }

    // MARK: - "EVERY NEW BOARD" card
    //
    // Ported verbatim from the retired `BoardPreferencesView` (Default size /
    // Center square / Week starts). All controls write through the
    // `onSet*` closures, which the container routes to
    // `AppDatabase.updateUserPreferences`.

    private var newBoardsCard: some View {
        VStack(spacing: 0) {
            segRow(label: "Size",
                   options: [(DefaultBoardSize.three, "3×3"),
                             (DefaultBoardSize.four, "4×4"),
                             (DefaultBoardSize.five, "5×5")],
                   selection: Binding(get: { preferences.defaultBoardSize }, set: onSetDefaultSize))
            rowDivider
            timeframeRow
            rowDivider
            segRow(label: "Center square",
                   options: [(DefaultCenterSquareType.free, "Free"),
                             (DefaultCenterSquareType.none, "None")],
                   selection: Binding(get: { preferences.defaultCenterType }, set: onSetCenterType))
            rowDivider
            VStack(alignment: .leading, spacing: 4) {
                segRow(label: "Week starts",
                       options: [(WeekStartDay.monday, "Mon"),
                                 (WeekStartDay.sunday, "Sun")],
                       selection: Binding(get: { preferences.weekStartDay }, set: onSetWeekStart))
                Text("Sets when weekly boards reset and renew.")
                    .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                    .padding(.horizontal, Riso.cardPadding).padding(.bottom, 10)
            }
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

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
        .contentShape(Rectangle())
    }

    private var rowDivider: some View {
        Divider().background(Color.risoInk.opacity(0.12))
            .padding(.horizontal, Riso.cardPadding)
    }

    /// "Timeframe" — mirrors web's New-board-defaults `<select>`
    /// (`BoardSettingsPage.tsx` "Default timeframe" row) exactly: Custom /
    /// Daily / Weekly / Monthly / Yearly, bound to `UserPreferences.
    /// defaultTimeframe`, which seeds the wizard's one-off Timeframe picker
    /// (`BoardWizardViewModel.resolveTimeframe`). Five segments are too
    /// cramped to sit beside a label in `segRow`'s HStack, so this stacks
    /// the label above a full-width `RisoSegmented` instead — the same
    /// layout the wizard's own timeframe picker uses
    /// (`RisoBoardSetupForm.timeframeSection`).
    private var timeframeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeframe").font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
            RisoSegmented(
                options: [(DefaultTimeframe.custom, "Custom"),
                          (DefaultTimeframe.daily, "Daily"),
                          (DefaultTimeframe.weekly, "Weekly"),
                          (DefaultTimeframe.monthly, "Monthly"),
                          (DefaultTimeframe.yearly, "Yearly")],
                selection: Binding(get: { preferences.defaultTimeframe }, set: onSetDefaultTimeframe)
            )
        }
        .padding(.horizontal, Riso.cardPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - Core-board defaults rows

    private func defaultsRow(_ tf: Timeframe) -> some View {
        let coreDefault = coreDefaultsByTimeframe[tf]
        let resolved = BoardWizardViewModel.resolveCoreBoardDefaultPrefill(
            corePoolIds: coreDefault?.corePoolIds ?? [],
            coreDefaultTaskIds: coreDefault?.coreDefaultTaskIds ?? [],
            poolsById: poolsById,
            tasksById: tasksById
        )
        let poolNames = resolved.pulledPoolIds.compactMap { poolsById[$0]?.name }
        // Per-timeframe size + centre — the suffix appears only when this
        // timeframe explicitly overrides either field; an inheriting row
        // shows no suffix even though it still resolves to a size.
        let setup = hasExplicitCoreBoardSetup(coreDefault)
            ? resolveCoreBoardSetupDefaults(coreDefault: coreDefault, preferences: preferences)
            : nil
        let summary = BoardSettingsView.formatDefaultsSummary(
            resolvedCount: resolved.selectedTaskIds.count, poolNames: poolNames, setup: setup
        )

        return Button { onTapDefaultsRow(tf) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tf.risoDisplayName)
                        .font(.risoHead(15, .bold)).foregroundStyle(Color.risoInk)
                    Text(summary)
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(resolved.selectedTaskIds.isEmpty ? Color.risoMuted : Color.risoInk)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }
            .padding(Riso.cardPadding)
            .contentShape(Rectangle())
            .risoCard()
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        }
        .buttonStyle(.plain)
    }

    // MARK: - "REPEATING BOARDS" header + roster card

    /// Section label + trailing "New ›" link, opening the Create tab's
    /// recurring-board wizard entry (same `enterFreshWizard(startRecurring:
    /// true)` path `CreateHubBoardCTAView(kind: .recurring)` uses).
    private var repeatingBoardsHeader: some View {
        HStack {
            Text("Repeating boards").risoSectionLabel()
            Spacer()
            Button(action: onNewRepeatingBoard) {
                Text("New ›")
                    .font(.risoBody(12, .bold))
                    .foregroundStyle(Color.risoBlue)
                    // 12pt text is well under the 44pt HIG minimum: lay the
                    // hit shape on a padded frame, then give the padding
                    // back so the header's layout is unchanged (same trick
                    // as `ProfileCountersSection`'s "All {n} ›" link).
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                    .padding(.vertical, -14)
                    .padding(.horizontal, -12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New repeating board")
        }
    }

    @ViewBuilder
    private var rosterCard: some View {
        if templates.isEmpty {
            Text("No repeating boards yet — turn one on from a board's \"Repeats\" setting when you create it, or \"Repeat this board…\" from an existing one.")
                .font(.risoBody(12.5, .regular))
                .foregroundStyle(Color.risoMuted)
                .padding(Riso.cardPadding)
                .risoCard()
                .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(templates.enumerated()), id: \.element.id) { index, tpl in
                    RecurringTemplateCard(
                        template: tpl,
                        attentionReason: attentionByTemplateId[tpl.id],
                        poolTaskCount: taskCountByTemplateId[tpl.id],
                        weekStartDay: preferences.weekStartDay,
                        onEdit: { onTapTemplate(tpl) },
                        onToggleActive: { newValue in onToggleTemplateActive(tpl, newValue) }
                    )
                    if index < templates.count - 1 {
                        rowDivider
                    }
                }
            }
            .risoCard()
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        }
    }
}
