import SwiftUI

/// Feature item structure for collapsible sections
struct Feature: Identifiable {
    let id: String
    let title: String
    let content: AnyView
}

private enum ClearStatus: Equatable {
    case idle
    case success
    case error(String)
}

/// Playground View
///
/// A dedicated space for testing new features before integrating them into the main app.
/// Features are displayed in collapsible sections using DisclosureGroup.
struct PlaygroundView: View {
    /// Optional — when provided, playground features that use the
    /// week-start preference (currently `BoardLifecyclePlayground`) use
    /// this value instead of the baked-in default. The production
    /// entrypoint via ProfileView passes `authService.userPreferences.
    /// weekStartDay.rawValue`; standalone previews get the default.
    var weekStartDay: String = UserPreferences.defaults.weekStartDay.rawValue

    /// Features under test — new features added here (newest first).
    ///
    /// The compound-tasks unification retired five playgrounds whose
    /// implementations consumed pre-unification types
    /// (TaskStep / CompositeTask / CompositeNode / TaskType.progress).
    /// They were gated `#if false` during the merge and dropped in
    /// Phase 8. New compound playgrounds will land as their own
    /// entries when needed.
    private var features: [Feature] {
        [
        Feature(
            id: "create-hub",
            title: "Create Hub — full flow (hub + wizard)",
            content: AnyView(CreateHubPlayground())
        ),
        Feature(
            id: "board-wizard-tasks",
            title: "Board Wizard — Tasks Step (spike)",
            content: AnyView(BoardWizardTasksPlayground())
        ),
        Feature(
            id: "auth-test",
            title: "Authentication & Sync",
            content: AnyView(AuthGateView {
                SyncDashboardPlayground()
            })
        ),
        Feature(
            id: "task-square-actions",
            title: "Task Square Interactions",
            content: AnyView(TaskSquareActionsPlayground())
        ),
    ]
    }

    @State private var expandedFeatureIds: Set<String> = []
    @State private var clearStatus: ClearStatus = .idle
    @Environment(\.dismiss) private var dismiss

    private func clearTestData() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.clearAllData()
                DispatchQueue.main.async {
                    clearStatus = .success
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        clearStatus = .idle
                    }
                }
            } catch {
                print("❌ clearAllData failed: \(error)")
                DispatchQueue.main.async {
                    clearStatus = .error(String(describing: error))
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Feature Playground")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("Isolated space for testing features before integrating them into the main app.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 8)

                    // Actions
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Clear Test Data") {
                            clearTestData()
                        }
                        .disabled(clearStatus != .idle)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)

                        switch clearStatus {
                        case .idle:
                            EmptyView()
                        case .success:
                            Text("✅ Test data cleared successfully")
                                .foregroundColor(.green)
                                .font(.subheadline)
                        case .error(let message):
                            Text("❌ Error clearing data: \(message)")
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }
                    }

                    // Features — plain state-driven expand/collapse, no DisclosureGroup gesture overhead
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Features Under Test")
                            .font(.title2)
                            .fontWeight(.semibold)

                        ForEach(features) { feature in
                            VStack(alignment: .leading, spacing: 0) {
                                Button {
                                    if expandedFeatureIds.contains(feature.id) {
                                        expandedFeatureIds.remove(feature.id)
                                    } else {
                                        expandedFeatureIds.insert(feature.id)
                                    }
                                } label: {
                                    HStack {
                                        Text(feature.title)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: expandedFeatureIds.contains(feature.id) ? "chevron.up" : "chevron.down")
                                            .foregroundColor(.secondary)
                                            .font(.subheadline)
                                    }
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if expandedFeatureIds.contains(feature.id) {
                                    feature.content
                                        .padding(.top, 4)
                                        .padding(.horizontal, 4)
                                        .padding(.bottom, 8)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(.systemGray6))
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Playground")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        PlaygroundView()
    }
}
