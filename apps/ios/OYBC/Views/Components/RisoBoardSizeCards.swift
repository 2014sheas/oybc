import SwiftUI

/// RisoBoardSizeCards — dot-matrix board-size picker (3×3 / 4×4 / 5×5).
///
/// Board Creation Split (iOS PR A) — extracted from `RisoBoardSetupForm`'s
/// former private `SizeCard` into a standalone reusable component so both
/// the one-off and recurring Setup forms render the identical control
/// (CLAUDE.md "Build real components, not demos" — a component used by
/// more than one surface belongs in `Views/Components/`, not inlined in a
/// single caller).
///
/// Selected card = gold fill + red dots + 3px hard shadow (press-elevated);
/// unselected = flat paper2 fill + paper dots (no shadow).
struct RisoBoardSizeCards: View {
    let selectedSize: Int
    var sizes: [Int] = [3, 4, 5]
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(sizes, id: \.self) { n in
                RisoBoardSizeCard(n: n, isSelected: selectedSize == n) {
                    onSelect(n)
                }
            }
        }
    }
}

/// Single dot-matrix size card — the building block of `RisoBoardSizeCards`.
/// Not `private` so a future surface can render a single card without the
/// row wrapper if ever needed.
struct RisoBoardSizeCard: View {
    let n: Int
    let isSelected: Bool
    let action: () -> Void

    private let dotSize: CGFloat = 7
    private let dotGap: CGFloat = 2

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                dotMatrix
                Text("\(n)×\(n)")
                    .font(.risoHead(14, .extraBold))
                    // Selected card is gold — non-inverting ink for dark mode.
                    .foregroundStyle(isSelected ? Color.risoInkStatic : Color.risoInk)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .risoCard(fill: isSelected ? .risoGold : .risoPaper2)
        }
        .buttonStyle(isSelected ? RisoButtonStyle(offset: Riso.Shadow.button) : RisoButtonStyle(offset: 0))
    }

    /// n×n grid of tiny squares (dot-matrix preview).
    @ViewBuilder
    private var dotMatrix: some View {
        VStack(spacing: dotGap) {
            ForEach(0..<n, id: \.self) { _ in
                HStack(spacing: dotGap) {
                    ForEach(0..<n, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isSelected ? Color.risoRed : Color.risoPaper)
                            .overlay(
                                RoundedRectangle(cornerRadius: 1)
                                    .strokeBorder(Color.risoInk, lineWidth: 1)
                            )
                            .frame(width: dotSize, height: dotSize)
                    }
                }
            }
        }
    }
}
