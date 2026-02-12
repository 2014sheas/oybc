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
        // Example structure - features will be added here as they're developed
        // Feature(
        //     id: "feature-1",
        //     title: "Feature Name",
        //     content: AnyView(FeatureView())
        // )
    ]

    var body: some View {
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
                    } else {
                        ForEach(features) { feature in
                            DisclosureGroup {
                                feature.content
                                    .padding()
                            } label: {
                                Text(feature.title)
                                    .font(.headline)
                                    .padding(.vertical, 8)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(.systemGray6))
                            )
                        }
                    }
                }
            }
            .padding()
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
