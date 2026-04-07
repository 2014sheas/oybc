import SwiftUI

/// BoardListView - Primary boards tab showing the user's bingo boards.
///
/// Phase 2 placeholder: displays an empty state message prompting the user
/// to create their first board from the Create tab.
struct BoardListView: View {
    var body: some View {
        ContentUnavailableView(
            "No Boards Yet",
            systemImage: "square.grid.3x3",
            description: Text("Head to the Create tab to build your first board!")
        )
        .navigationTitle("Boards")
    }
}

#Preview {
    NavigationStack {
        BoardListView()
    }
}
