import SwiftUI

/// CreateView - Create tab entry point for building bingo boards.
///
/// Phase 2 placeholder: describes the board creation workflow that will
/// be fully implemented in a subsequent milestone.
struct CreateView: View {
    var body: some View {
        ContentUnavailableView(
            "Create a Board",
            systemImage: "plus.circle",
            description: Text("Build tasks, assemble your pool, and create a new bingo board.")
        )
        .navigationTitle("Create")
    }
}

#Preview {
    NavigationStack {
        CreateView()
    }
}
