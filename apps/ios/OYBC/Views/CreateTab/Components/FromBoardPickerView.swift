import SwiftUI

/// Source-board picker for the wizard's `From a board…` filter chip.
/// Renders a vertical list of eligible boards (active + completed
/// within 30 days) as Riso-styled card rows with a `RisoMiniGrid`
/// thumbnail + metadata.
///
/// Presentation-only reskin of the pre-Riso implementation. All
/// logic, callbacks, and data flow are preserved unchanged.
///
/// iOS twin of web's `FromBoard` (proto/library.jsx).
struct FromBoardPickerView: View {
    @Bindable var vm: SourceBoardsViewModel
    let userId: String

    /// Called when the user taps a card. Parent (Tasks step) swaps
    /// the list region to the grid view for the chosen board.
    let onPickBoard: (String) -> Void

    var body: some View {
        Group {
            if vm.eligibleBoards.isEmpty {
                emptyState
            } else {
                boardList
            }
        }
        .onAppear {
            vm.reloadAsync(userId: userId)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No boards to browse.")
                .font(.risoHead(13, .bold))
                .foregroundStyle(Color.risoInk)
            Text("Create another board first, or build this one from scratch.")
                .font(.risoBody(11, .semibold))
                .foregroundStyle(Color.risoMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }

    // MARK: - Board list

    private var boardList: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section kicker — matches Riso section label pattern
            Text("PICK A BOARD TO BROWSE")
                .font(.risoBody(11, .bold))
                .tracking(0.22 * 11)
                .foregroundStyle(Color.risoMuted)

            LazyVStack(spacing: 7) {
                ForEach(vm.eligibleBoards, id: \.id) { board in
                    boardRow(board)
                }
            }
        }
    }

    // MARK: - Board row card

    @ViewBuilder
    private func boardRow(_ board: Board) -> some View {
        let completion = vm.completionByBoardId[board.id]
            ?? (0, board.boardSize * board.boardSize)

        Button {
            onPickBoard(board.id)
        } label: {
            HStack(spacing: 12) {
                // Mini-grid thumbnail — the TRUE board (bugfix/board-preview-real-cells).
                RisoBoardPreviewGrid(board: board, size: 46)

                // Board meta
                VStack(alignment: .leading, spacing: 3) {
                    Text(board.name.isEmpty ? "Untitled board" : board.name)
                        .font(.risoHead(13.5, .bold))
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)

                    Text(metaLine(board))
                        .font(.risoBody(10.5, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)

                    Text("\(completion.completed) / \(completion.total) complete")
                        .font(.risoBody(10, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Disclosure chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }
            .padding(12)
            .background(Color.risoPaper2)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
            )
        }
        .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small))
    }

    // MARK: - Helpers

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
