import SwiftUI

/// Source-board picker for the wizard's `From a board…` filter chip.
/// Renders a vertical list of eligible boards (active + completed
/// within 30 days) as cards with a tiny `BoardThumbnailView` + metadata.
///
/// iOS twin of web's `FromBoardPicker`. The VM precomputes thumbnail
/// states and completion ratios so per-card rendering stays synchronous.
struct FromBoardPickerView: View {
    @Bindable var vm: SourceBoardsViewModel
    let userId: String

    /// Called when the user taps a card. Parent (Tasks step) swaps
    /// the list region to the grid view for the chosen board.
    let onPickBoard: (String) -> Void

    var body: some View {
        Group {
            if vm.eligibleBoards.isEmpty {
                Text(
                    "No boards to browse. Create another board first, or build this one from scratch."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pick a board to browse")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .padding(.top, 8)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)

                    LazyVStack(spacing: 0) {
                        ForEach(vm.eligibleBoards, id: \.id) { board in
                            Button {
                                onPickBoard(board.id)
                            } label: {
                                cardRow(board)
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .onAppear {
            vm.reloadAsync(userId: userId)
        }
    }

    @ViewBuilder
    private func cardRow(_ board: Board) -> some View {
        let states = vm.thumbnailStatesByBoardId[board.id] ?? Array(
            repeating: .empty,
            count: board.boardSize * board.boardSize
        )
        let completion = vm.completionByBoardId[board.id]
            ?? (0, board.boardSize * board.boardSize)

        HStack(spacing: 12) {
            BoardThumbnailView(
                gridSize: board.boardSize,
                cellStates: states,
                pixelSize: 56
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(board.name.isEmpty ? "Untitled board" : board.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(metaLine(board))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text("\(completion.completed) / \(completion.total) complete")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
            }

            Spacer()
            Text("›")
                .font(.title3)
                .foregroundColor(.secondary)
                .padding(.trailing, 4)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private func metaLine(_ board: Board) -> String {
        let timeframeName = board.timeframe.rawValue.capitalized
        let geometry = "\(board.boardSize)×\(board.boardSize)"
        let window: String
        if board.timeframe == .custom {
            window = "Custom"
        } else if let start = parseISO8601Date(board.startDate) {
            window = formatTimeframeLabel(timeframe: board.timeframe, startDate: start)
        } else {
            window = ""
        }
        if window.isEmpty {
            return "\(timeframeName) · \(geometry)"
        }
        return "\(timeframeName) · \(geometry) · \(window)"
    }
}
