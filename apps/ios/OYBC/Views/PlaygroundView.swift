import SwiftUI

/// Feature item structure for collapsible sections
struct Feature: Identifiable {
    let id: String
    let title: String
    let content: AnyView
}

/// Playground View
///
/// A dedicated space for testing new features before integrating them into the main app.
/// Features are displayed in collapsible sections using DisclosureGroup.
struct PlaygroundView: View {
    /// Features under test - new features will be added here
    private let features: [Feature] = [
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

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Feature Playground")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("This is a dedicated space for testing new features before integrating them into the main application. Each feature is isolated in its own section below.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 8)

                    // Features Under Test
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Features Under Test")
                            .font(.title2)
                            .fontWeight(.semibold)

                        if features.isEmpty {
                            Text("No features currently under test. Features will be added here as they are developed.")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .italic()
                                .padding(.vertical, 8)

                            Button("Test Button") { }
                        } else {
                            ForEach(features) { feature in
                                DisclosureGroup {
                                    feature.content
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                } label: {
                                    Text(feature.title)
                                        .font(.headline)
                                        .padding(.vertical, 6)
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(.systemGray6))
                                )
                            }
                        }
                    }
                }
                .frame(width: geometry.size.width - 24, alignment: .leading)
                .padding(12)
            }
        }
        .navigationTitle("Playground")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        PlaygroundView()
    }
}
