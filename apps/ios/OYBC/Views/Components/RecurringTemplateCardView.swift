import SwiftUI

/// RecurringTemplateCard — compact one-line row for one repeating board
/// template on `BoardSettingsView`'s "REPEATING BOARDS" card (Profile reorg
/// PR3, `design_handoff_profile_reorg/README.md` §4). iOS twin of web's
/// `components/boardSettings/RepeatingBoardRow.tsx` (meta line helpers ↔
/// its `repeatingBoardMeta.ts`).
///
/// Row 1: name (muted when paused) + timeframe tag, trailing active toggle
/// + chevron. Row 2 (meta): `{size} board · {n}-task pool · renews {day}`
/// or `… · paused`. An optional "needs attention" badge surfaces an empty /
/// invalid pool (see `attentionReason`), mirroring web's `attentionBadge`
/// semantics + copy.
///
/// Profile reorg PR3 dropped the pool-preview chip row, the "Add tasks"
/// link, and the inline "Delete" affordance that this component used to
/// render (issue #321 / Board Creation Split PR B) — those stayed useful
/// while this WAS the only place to manage a repeating board, but the
/// design now routes editing entirely through the wizard's "EDIT RECURRING
/// BOARD" mode (`onEdit`), and the card chrome (border/shadow/background)
/// moved OUT to the single composite card `BoardSettingsContent` wraps
/// every row in — this component is now a plain row, not its own card.
/// Delete now lives in the editor: the "Delete repeating board" row on the
/// wizard's Setup step (`BoardWizardSetupStepView` → `BoardWizardView`'s
/// `.alert` → `deleteEditedRecurringTemplate`, the same soft-delete op
/// this row used to call).
///
/// Tapping the row opens the board wizard hydrated from this template
/// (edit mode) — the same cross-tab route web's row Edit button used. The
/// row is not wrapped in a `Button` (which would swallow the inner
/// toggle), so it uses `.onTapGesture` + `.contentShape(Rectangle())` on
/// the row body instead.
struct RecurringTemplateCard: View {

    let template: RecurringBoardTemplate
    /// Non-nil when this template's pool can't spawn — surfaces a badge.
    /// Strict mirror of web's `attentionReason` (see `RepeatingBoardRow`).
    let attentionReason: SpawnAttentionReason?
    /// The "N-task pool" meta-row count. P1 (Task Pools + Recurring
    /// Boards Rework) — `template.seedTaskIds.count` goes stale the first
    /// time the legacy-editor write-through edits the linked Pool (see
    /// `RecurringBoardTemplatesViewModel.mixByTemplateId`'s doc), so the
    /// caller should pass the CURRENT resolved mix's count. `nil` (the
    /// default) falls back to `template.seedTaskIds.count` — used by
    /// previews/snapshots that construct a bare template with no live
    /// mix data.
    var poolTaskCount: Int? = nil
    /// User's week-start preference (Mon/Sun) — a weekly template's
    /// "renews {day}" text honors this instead of assuming Monday.
    /// Defaults to `.monday` for call sites (previews/snapshots) that
    /// don't otherwise care.
    var weekStartDay: WeekStartDay = .monday
    let onEdit: () -> Void
    let onToggleActive: (Bool) -> Void

    private var active: Bool { template.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            metaLabelGroup
            if let reason = attentionReason {
                attentionBadge(reason)
            }
        }
        .padding(.horizontal, Riso.cardPadding)
        .padding(.vertical, 12)
        .opacity(active ? 1.0 : 0.7)
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
    }

    // MARK: - Rows

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(template.name)
                .font(.risoHead(16, .extraBold))
                .foregroundStyle(active ? Color.risoInk : Color.risoMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            timeframeTag
            RisoPillSwitch(isOn: Binding(get: { active }, set: { onToggleActive($0) }))
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.risoMuted)
                .accessibilityHidden(true) // decorative — the row itself is the affordance
        }
    }

    private var metaLabelGroup: some View {
        Text(Self.formatMetaLine(
            boardSize: template.boardSize,
            taskCount: poolTaskCount ?? template.seedTaskIds.count,
            isActive: active,
            timeframe: template.timeframe,
            weekStartDay: weekStartDay
        ))
        .font(.risoBody(12, .regular))
        .foregroundStyle(Color.risoMuted)
        .lineLimit(1)
    }

    // MARK: - Attention badge

    private func attentionBadge(_ reason: SpawnAttentionReason) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
                .padding(.top, 1)
            Text(Self.attentionCopy(reason))
                .font(.risoBody(11, .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Color.risoRed)
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.risoRed.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.risoRed.opacity(0.5), lineWidth: Riso.Keyline.dense))
    }

    /// Copy for each attention reason — mirrors web's `ATTENTION_COPY`
    /// (`RepeatingBoardRow.tsx`). Sources-native roster health (loose-ends
    /// sweep 2026-09-09) can surface the full attention set here,
    /// `sourceBoardMissing` included. No "template"/"spawn" in copy — the
    /// rework's copy rules.
    static func attentionCopy(_ reason: SpawnAttentionReason) -> String {
        switch reason {
        case .poolTooSmall:
            return "Mix is too small for the current configuration. Edit tasks to add more."
        case .hasDeletedTasks:
            return "A task in this mix was deleted. Edit tasks to refresh it."
        case .unsupportedTimeframe:
            return "This board's timeframe is no longer supported."
        case .unsupportedCenter:
            return "This board's center cell is no longer supported."
        case .noPoolTasksResolved:
            return "None of this board's tasks could be loaded. Edit tasks to refresh it."
        case .spawnFailed:
            return "Couldn't make the next board. Try editing tasks to refresh it."
        case .sourceBoardMissing:
            return "It pulls from a board that was deleted or archived. Edit tasks to remove that source."
        }
    }

    // MARK: - Sub-views / helpers

    private var timeframeTag: some View {
        Text(template.timeframe.risoDisplayName.uppercased())
            .font(.risoHead(9, .bold))
            .tracking(0.4)
            .foregroundStyle(Color.risoPaper)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Capsule().fill(template.timeframe.risoColor))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    // MARK: - Pure, testable meta-line helpers (RecurringTemplateMetaTests)

    /// Renewal-day copy for a repeating board's meta line. Weekly honors
    /// the user's `WeekStartDay` preference (Mon/Sun); the other
    /// timeframes are fixed. `.custom` / `.indefinite` are excluded from
    /// repeating-board creation at the form layer but handled here too so
    /// the switch stays exhaustive.
    static func renewalDayText(timeframe: Timeframe, weekStartDay: WeekStartDay) -> String {
        switch timeframe {
        case .weekly: return weekStartDay == .monday ? "Mondays" : "Sundays"
        case .monthly: return "the 1st"
        case .daily: return "every morning"
        case .yearly: return "Jan 1"
        case .custom: return "custom"
        case .indefinite: return "ongoing"
        }
    }

    /// Full meta line: `"{size}×{size} board · {n}-task pool · renews
    /// {day}"`, or `"… · paused"` when the template is inactive (paused
    /// state never shows a renewal day — there isn't one until resumed).
    static func formatMetaLine(
        boardSize: Int,
        taskCount: Int,
        isActive: Bool,
        timeframe: Timeframe,
        weekStartDay: WeekStartDay
    ) -> String {
        let base = "\(boardSize)×\(boardSize) board · \(taskCount)-task pool"
        guard isActive else { return "\(base) · paused" }
        return "\(base) · renews \(renewalDayText(timeframe: timeframe, weekStartDay: weekStartDay))"
    }
}
