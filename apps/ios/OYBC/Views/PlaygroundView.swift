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
    /// Features under test - new features will be added here (newest first)
    private let features: [Feature] = [
        Feature(
            id: "unified-task-creation",
            title: "Task Creation (Unified)",
            content: AnyView(UnifiedTaskCreatorPlayground())
        ),
        Feature(
            id: "center-space-free",
            title: "Center Space: True Free Space (5x5)",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Center is auto-completed, shows \"FREE SPACE\", locked (cannot toggle off), counts toward bingo.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58, centerSquareType: .free)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "center-space-custom-free",
            title: "Center Space: Customizable Free Space (5x5)",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Center is auto-completed with custom text, locked, counts toward bingo.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58, centerSquareType: .customFree, centerSquareCustomName: "My Goal!")
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "center-space-chosen",
            title: "Center Space: User-Chosen Center (5x5)",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Center has a fixed task (e.g., \"My Special Task\"), NOT auto-completed, can toggle like any square.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58, centerSquareType: .chosen)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "center-space-none",
            title: "Center Space: No Center Space (5x5)",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Center is an ordinary square, no special treatment.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58, centerSquareType: .none)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "center-space-3x3",
            title: "Center Space: Works on 3x3 Too!",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("True Free Space works on smaller odd-sized boards (center is index 4 on 3x3).")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 3, squareSize: 80, centerSquareType: .free)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "bingo-square",
            title: "Bingo Square",
            content: AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    Text("A single bingo board square that toggles between incomplete and completed states. Tap to toggle.")
                        .font(.body)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading) {
                            BingoSquare()
                            Text("Default (100pt)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading) {
                            BingoSquare(size: 150)
                            Text("Large (150pt)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading) {
                            BingoSquare(initialCompleted: true)
                            Text("Initially Completed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            )
        ),
        Feature(
            id: "bingo-board",
            title: "5x5 Bingo Board Grid",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("A 5x5 bingo board grid with 25 toggleable squares. The center square (Task 13) has special styling with an orange border and star marker.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "bingo-board-3x3",
            title: "3x3 Mini Board",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("A compact 3x3 mini bingo board with 9 toggleable squares. The center square (Task 5) has special styling.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 3, squareSize: 80)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "bingo-board-4x4",
            title: "4x4 Standard Board",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("A 4x4 standard bingo board with 16 toggleable squares. Even-sized grids have no center square.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 4, squareSize: 70)
                        .frame(maxWidth: .infinity)
                }
            )
        )
    ]

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
                DispatchQueue.main.async {
                    clearStatus = .error(error.localizedDescription)
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
