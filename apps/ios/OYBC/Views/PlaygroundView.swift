import SwiftUI

/// Feature item structure for collapsible sections
struct Feature: Identifiable {
    let id: String
    let title: String
    let content: AnyView
}

/// PreferenceKey for communicating pool count from a child playground up to PlaygroundView.
/// Used by BoardTaskSelectionPlayground to float a persistent pool indicator outside the ScrollView.
struct PoolCountPreferenceKey: PreferenceKey {
    static var defaultValue: Int = 0
    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = nextValue()
    }
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

    /// Features under test - new features will be added here (newest first)
    private var features: [Feature] {
        [
        Feature(
            id: "auth-test",
            title: "Authentication & Sync",
            content: AnyView(AuthGateView {
                SyncDashboardPlayground()
            })
        ),
        Feature(
            id: "board-lifecycle",
            title: "Board Lifecycle",
            // BoardLifecyclePlayground gated out until Phase 5 rewrite (compound-tasks unification)
            content: AnyView(Text("Unavailable — awaiting Phase 5 rewrite").foregroundColor(.secondary).padding())
        ),
        Feature(
            id: "board-task-selection",
            title: "Board Task Selection",
            // BoardTaskSelectionPlayground gated out until Phase 5 rewrite (compound-tasks unification)
            content: AnyView(Text("Unavailable — awaiting Phase 5 rewrite").foregroundColor(.secondary).padding())
        ),
        Feature(
            id: "cross-board-rollup",
            title: "Cross-Board Progress Rollup",
            // CrossBoardRollupPlayground gated out until Phase 5 rewrite (TaskType.compound)
            content: AnyView(Text("Unavailable — awaiting Phase 5 rewrite").foregroundColor(.secondary).padding())
        ),
        Feature(
            id: "subtask-derivation",
            title: "Subtask Derivation Engine",
            content: AnyView(SubtaskDerivationPlayground())
        ),
        Feature(
            id: "task-square-actions",
            title: "Task Square Interactions",
            content: AnyView(TaskSquareActionsPlayground())
        ),
        Feature(
            id: "board-generator",
            title: "Board Generator",
            // BoardGeneratorPlayground gated out until Phase 5 rewrite (compound-tasks unification)
            content: AnyView(Text("Unavailable — awaiting Phase 5 rewrite").foregroundColor(.secondary).padding())
        ),
        Feature(
            id: "unified-task-creation",
            title: "Task Creation (Unified)",
            // UnifiedTaskCreatorPlayground gated out until Phase 5 rewrite (TaskType.compound)
            content: AnyView(Text("Unavailable — awaiting Phase 5 rewrite").foregroundColor(.secondary).padding())
        ),
    ]
    }

    @State private var expandedFeatureIds: Set<String> = []
    @State private var clearStatus: ClearStatus = .idle
    @State private var floatingPoolCount: Int = 0
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
            .onPreferenceChange(PoolCountPreferenceKey.self) { count in
                floatingPoolCount = count
            }
            .overlay(alignment: .bottomTrailing) {
                if floatingPoolCount > 0 && expandedFeatureIds.contains("board-task-selection") {
                    Text("Pool: \(floatingPoolCount)")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        .padding(16)
                }
            }
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
