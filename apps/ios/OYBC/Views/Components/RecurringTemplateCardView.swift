import SwiftUI

/// RecurringTemplateCard — Riso keyline card for one recurring board
/// template on the Profile "Recurring templates" sub-page. iOS twin of
/// web's `RecurringTemplateRow.tsx`.
///
/// Header row: name + timeframe tag + active toggle. Meta row: board
/// size · pool size · renew cadence (or "paused"), with a trailing
/// Delete affordance (confirm-guarded), matching web's visible Delete
/// button + confirm copy. Below that: an optional pool-preview chip row
/// (first 3 resolved task titles + "+{k} more" overflow) and a trailing
/// "Add tasks" link that deep-links into the wizard's Tasks step — both
/// issue #321. "Add tasks" is its own row rather than packed into
/// `metaRow`, which already runs tight against the meta label group
/// (e.g. "renews Mondays") and would truncate it. An optional "needs
/// attention" badge surfaces an empty / invalid pool (see
/// `attentionReason`), mirroring web's `attentionBadge` semantics + copy.
///
/// Tapping the card opens the board wizard hydrated from this template
/// (edit mode) — the same cross-tab route web's row Edit button used.
/// The card is not wrapped in a `Button` (which would swallow the inner
/// toggle / Delete controls); it uses `.onTapGesture` on the card body
/// so the toggle and Delete keep their own hit targets.
struct RecurringTemplateCard: View {

    let template: RecurringBoardTemplate
    /// Non-nil when this template's pool can't spawn — surfaces a badge.
    /// Strict mirror of web's `attentionReason` (see `RecurringTemplateRow`).
    let attentionReason: SpawnAttentionReason?
    /// First-3 resolved task titles from the pool, in mix order (issue
    /// #321). Empty ⇒ no chip row (e.g. zero resolvable titles).
    var poolPreview: [String] = []
    /// Count of additional resolved titles beyond `poolPreview`'s first 3.
    /// 0 ⇒ no "+{k} more" overflow chip.
    var poolPreviewOverflow: Int = 0
    /// The "N-task pool" meta-row count. P1 (Task Pools + Recurring
    /// Boards Rework) — `template.seedTaskIds.count` goes stale the first
    /// time the legacy-editor write-through edits the linked Pool (see
    /// `RecurringBoardTemplatesViewModel.mixByTemplateId`'s doc), so the
    /// caller should pass the CURRENT resolved mix's count. `nil` (the
    /// default) falls back to `template.seedTaskIds.count` — used by
    /// previews/snapshots that construct a bare template with no live
    /// mix data.
    var poolTaskCount: Int? = nil
    let onEdit: () -> Void
    let onToggleActive: (Bool) -> Void
    let onDelete: () -> Void
    /// Deep-links into the wizard hydrated from this template, landing on
    /// the Tasks step (step 2) instead of Setup (step 1) — issue #321.
    var onAddTasks: () -> Void = {}

    @State private var showDeleteConfirm = false

    private var active: Bool { template.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            metaRow
            poolPreviewRow
            addTasksRow
            if let reason = attentionReason {
                attentionBadge(reason)
            }
        }
        .padding(Riso.cardPadding)
        .risoCard(fill: active ? .risoPaper2 : .risoPaper)
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .opacity(active ? 1.0 : 0.7)
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .confirmationDialog(
            "Delete \"\(template.name)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete template", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Boards spawned from this template will not be deleted.")
        }
    }

    // MARK: - Rows

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(template.name)
                .font(.risoHead(17, .extraBold))
                .foregroundStyle(active ? Color.risoInk : Color.risoMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            timeframeTag
            RisoPillSwitch(isOn: Binding(get: { active }, set: { onToggleActive($0) }))
        }
    }

    private var metaRow: some View {
        HStack(spacing: 4) {
            metaLabelGroup
                .lineLimit(1)
            Spacer(minLength: 6)
            Button { showDeleteConfirm = true } label: {
                Text("Delete")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoRed)
            }
            .buttonStyle(.plain)
        }
    }

    /// "Add tasks" deep-link (issue #321) — its own row rather than crowding
    /// into `metaRow`, which already runs tight against the meta label
    /// group (e.g. "renews Mondays"); packing a second button in there
    /// truncated it.
    private var addTasksRow: some View {
        HStack {
            Spacer()
            Button(action: onAddTasks) {
                Text("Add tasks")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoBlue)
            }
            .buttonStyle(.plain)
        }
    }

    /// Compact pool-preview chip row (issue #321) — up to 3 resolved task
    /// titles, plus a "+{k} more" overflow chip. Empty `poolPreview` ⇒ no
    /// row at all (e.g. every seed id is unresolvable).
    @ViewBuilder
    private var poolPreviewRow: some View {
        if !poolPreview.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(poolPreview, id: \.self) { title in
                    poolPreviewChip(title.isEmpty ? "(untitled)" : title)
                }
                if poolPreviewOverflow > 0 {
                    poolPreviewChip("+\(poolPreviewOverflow) more")
                }
            }
        }
    }

    private func poolPreviewChip(_ text: String) -> some View {
        Text(text)
            .font(.risoBody(11, .regular))
            .foregroundStyle(Color.risoInk)
            .lineLimit(1)
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Capsule().fill(Color.risoPaper2))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    private var metaLabelGroup: some View {
        HStack(spacing: 4) {
            Text("\(template.boardSize)×\(template.boardSize)").font(.risoBody(12, .bold))
                .foregroundStyle(active ? Color.risoInk : Color.risoMuted)
            Text("board").font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
            Text("·").foregroundStyle(Color.risoMuted)
            Text("\(poolTaskCount ?? template.seedTaskIds.count)").font(.risoBody(12, .bold))
                .foregroundStyle(active ? Color.risoInk : Color.risoMuted)
            Text("-task pool").font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
            Text("·").foregroundStyle(Color.risoMuted)
            Text(active ? "renews \(renewText)" : "paused")
                .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
        }
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

    private var renewText: String {
        switch template.timeframe {
        case .weekly: return "Mondays"
        case .monthly: return "the 1st"
        case .daily: return "every morning"
        case .yearly: return "Jan 1"
        case .custom: return "custom"
        case .indefinite: return "ongoing"
        }
    }
}
