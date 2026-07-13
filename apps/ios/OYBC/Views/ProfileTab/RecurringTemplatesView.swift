import SwiftUI

/// RecurringTemplatesView — Riso-styled Profile sub-page listing recurring
/// board templates. Design: §5a README + screenshot 09.
///
/// Each template is a keyline card (`RecurringTemplateCard`): name +
/// timeframe color tag + active switch + Delete, plus a "needs
/// attention" badge for empty / invalid pools. Tapping a card opens the
/// board wizard hydrated from that template (edit mode). The dashed
/// "+ New template" button opens the wizard's recurring flow — the same
/// entry as the Create hub's "Create a recurring board" CTA. Both routes
/// go through the shared wizard now; the old inline TemplateEditSheet
/// (which could underfill a pool) was retired to match web's Phase 6.2
/// rework. Paused templates dim the card and show "paused".
struct RecurringTemplatesView: View {

    /// Cross-tab edit route: hop to the Create tab and open the wizard
    /// hydrated from this template id. Wired by the hosting tab shell.
    var onEditTemplate: ((String) -> Void)? = nil
    /// Cross-tab create route: hop to the Create tab and open the
    /// wizard's fresh recurring-template flow. Wired by the tab shell.
    var onNewTemplate: (() -> Void)? = nil
    /// Cross-tab "Add tasks" route (issue #321): hop to the Create tab and
    /// open the wizard hydrated from this template id, landing on the
    /// Tasks step (2) rather than Setup (1). Wired by the tab shell,
    /// mirroring `onEditTemplate`.
    var onAddTasksTemplate: ((String) -> Void)? = nil

    @EnvironmentObject var authService: AuthService

    @State private var templatesVM = RecurringBoardTemplatesViewModel()

    var body: some View {
        ZStack {
            RisoPaperBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    RisoSubPageHeader(title: "Recurring templates")
                        .padding(.top, 16)
                        .padding(.bottom, 16)

                    Text("Templates press a fresh core board each cycle — same pool, reshuffled squares.")
                        .font(.risoBody(13, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 14)

                    if !templatesVM.templates.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(templatesVM.templates, id: \.id) { tpl in
                                RecurringTemplateCard(
                                    template: tpl,
                                    attentionReason: templatesVM.attentionByTemplateId[tpl.id],
                                    poolPreview: templatesVM.poolPreviewByTemplateId[tpl.id] ?? [],
                                    poolPreviewOverflow: templatesVM.poolPreviewOverflowByTemplateId[tpl.id] ?? 0,
                                    onEdit: { onEditTemplate?(tpl.id) },
                                    onToggleActive: { newValue in setActive(tpl, newValue) },
                                    onDelete: { deleteTemplate(id: tpl.id) },
                                    onAddTasks: { onAddTasksTemplate?(tpl.id) }
                                )
                                .padding(.horizontal, Riso.gutter)
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    RisoDashedButton(label: "+ New template") { onNewTemplate?() }
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 16)

                    Text("Pausing a template keeps its pool — it just stops printing new boards.")
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 24)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear { reload() }
    }

    // MARK: - Actions

    /// Pause / activate a template. Mirrors web's `toggleActive`
    /// (`RecurringTemplateRow`): flips `isActive`, bumps version, and
    /// reloads (which recomputes the attention map).
    private func setActive(_ tpl: RecurringBoardTemplate, _ newValue: Bool) {
        guard let userId = authService.currentUser?.id else { return }
        let now = AppDatabase.currentTimestamp()
        var updated = tpl; updated.isActive = newValue
        updated.updatedAt = now; updated.version += 1
        _Concurrency.Task.detached {
            do {
                try AppDatabase.shared.saveRecurringBoardTemplateAndEnqueue(
                    updated, operation: .update, now: now
                )
                await MainActor.run { templatesVM.reloadAsync(userId: userId) }
            } catch { print("[RecurringTemplatesView] toggle failed: \(error)") }
        }
    }

    /// Soft-delete a template. Mirrors web's `handleDelete` — the card
    /// has already confirmed. Spawned boards are intentionally left
    /// untouched (see the card's confirm copy).
    private func deleteTemplate(id: String) {
        guard let userId = authService.currentUser?.id else { return }
        _Concurrency.Task.detached {
            do {
                try AppDatabase.shared.softDeleteRecurringBoardTemplateAndEnqueue(
                    id: id, now: AppDatabase.currentTimestamp()
                )
                await MainActor.run { templatesVM.reloadAsync(userId: userId) }
            } catch { print("[RecurringTemplatesView] deleteTemplate failed: \(error)") }
        }
    }

    private func reload() {
        guard let userId = authService.currentUser?.id else { return }
        templatesVM.reloadAsync(userId: userId)
    }
}

// MARK: - Shared Riso sub-page components

/// Back square button + "PROFILE" kicker + H2 title used by all Profile sub-pages.
struct RisoSubPageHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 40, height: 40)
                    .risoCard(fill: .risoPaper2)
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small))
            VStack(alignment: .leading, spacing: 2) {
                Text("Profile").risoKicker()
                Text(title).risoH2()
            }
            Spacer()
        }
        .padding(.horizontal, Riso.gutter)
    }
}

/// Dashed "+ New ___" button matching the prototype's pp-dashedbtn style.
struct RisoDashedButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.risoHead(14, .bold)).foregroundStyle(Color.risoInk)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
                .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        }.buttonStyle(.plain)
    }
}

/// Keyline pill toggle styled to Riso green accent.
struct RisoPillSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().tint(Color.risoGreen)
    }
}

// MARK: - Timeframe helpers

extension Timeframe {
    /// Short label used in UI tags and segmented controls.
    var risoDisplayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .custom: return "Custom"
        case .indefinite: return "Ongoing"
        }
    }

    /// Riso color for timeframe tags: Daily=gold, Weekly=blue, Monthly=green, Yearly=red.
    var risoColor: Color {
        switch self {
        case .daily: return .risoGold
        case .weekly: return .risoBlue
        case .monthly: return .risoGreen
        case .yearly: return .risoRed
        case .custom: return .risoMuted
        case .indefinite: return .risoMuted
        }
    }
}
