import SwiftUI

/// BoardPlayView — Placeholder for the interactive board gameplay screen.
///
/// Phase 3 will replace this with the live bingo board, task completion
/// interactions, and progress tracking.
///
/// - Parameter boardId: The ID of the board to display.
struct BoardPlayView: View {

    // MARK: - Parameters

    let boardId: String

    // MARK: - Body

    var body: some View {
        VStack(spacing: 8) {
            Text("Board play view coming in Phase 3")
                .font(.body)
                .foregroundStyle(.secondary)
            Text(boardId)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .navigationTitle("Play")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        BoardPlayView(boardId: "example-board-id-123")
    }
}
