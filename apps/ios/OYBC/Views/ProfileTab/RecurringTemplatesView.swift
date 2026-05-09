import SwiftUI

/// RecurringTemplatesView — Profile sub-page that lists the user's
/// recurring board templates with edit / pause / delete affordances.
/// iOS twin of web's `RecurringTemplatesPage`.
///
/// Per the Phase 6.2 UX rework (2026-05-08), templates moved out of
/// the Create tab. Creation flows exclusively through the board wizard
/// — there's no "+ New template" button here. The empty-state copy
/// points the user to the wizard.
///
/// Edit handler bubbles up via `onEditTemplate(templateId)` so
/// `MainTabView` can switch to the Create tab and stash the id for
/// `CreateHubView` to consume. Same cross-tab pattern as Phase 6.1's
/// `pendingRecurringTimeframe`.
struct RecurringTemplatesView: View {

    // MARK: - Inputs

    /// Invoked when the user taps Edit on a row. Optional so the
    /// SwiftUI `#Preview` and any tests can mount the view in isolation
    /// without cross-tab plumbing.
    var onEditTemplate: ((String) -> Void)?

    // MARK: - Dependencies

    @EnvironmentObject var authService: AuthService

    // MARK: - State

    @State private var templatesVM = RecurringBoardTemplatesViewModel()
    @State private var libraryTasks: [Task] = []

    // MARK: - Derived

    /// Synchronous validation against the library, surfacing "needs
    /// attention" badges on rows whose pool has issues. Mirrors the
    /// web `attentionByTemplateId` memo. The actual spawn driver in
    /// `RecurringBoardSpawn.swift` produces the authoritative reason
    /// when it next runs; this is for immediate feedback while
    /// browsing the templates list.
    private var attentionByTemplateId: [String: SpawnAttentionReason] {
        var out: [String: SpawnAttentionReason] = [:]
        let tasksById = Dictionary(uniqueKeysWithValues: libraryTasks.map { ($0.id, $0) })
        for t in templatesVM.templates {
            var pool: [Task] = []
            var hasMissingFromLibrary = false
            for id in t.seedTaskIds {
                if let found = tasksById[id] { pool.append(found) }
                else { hasMissingFromLibrary = true }
            }
            if hasMissingFromLibrary {
                out[t.id] = .hasDeletedTasks
                continue
            }
            if case .failure(let reason) = validateSpawnPool(template: t, poolTasks: pool) {
                out[t.id] = SpawnAttentionReason(reason)
            }
        }
        return out
    }

    // MARK: - Body

    var body: some View {
        Group {
            if templatesVM.templates.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(templatesVM.templates, id: \.id) { tpl in
                        RecurringTemplateRowView(
                            template: tpl,
                            attentionReason: attentionByTemplateId[tpl.id],
                            onEdit: { onEditTemplate?(tpl.id) },
                            onTemplatesChanged: {
                                if let userId = authService.currentUser?.id {
                                    templatesVM.reloadAsync(userId: userId)
                                }
                            }
                        )
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Recurring templates")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let userId = authService.currentUser?.id {
                templatesVM.reloadAsync(userId: userId)
                reloadLibraryTasks(userId: userId)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No recurring templates yet.")
                .font(.headline)
            Text("To create one, head to the **Create** tab → **Start a new board** → toggle **\"Make recurring\"** in the Setup step.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reloadLibraryTasks(userId: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tasks = try AppDatabase.shared.fetchTasks(userId: userId)
                DispatchQueue.main.async { libraryTasks = tasks }
            } catch {
                DispatchQueue.main.async { libraryTasks = [] }
            }
        }
    }
}
