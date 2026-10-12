import SwiftUI

// MARK: - RisoMomentConfetti

/// The Greenlog moment's confetti field (kept from the retired
/// `RisoGreenlogOverlay`): a looping fall of paper / gold / red / blue pieces.
/// `intensity` (1-10, default 7 → the original 64-piece burst) scales the
/// count. Non-interactive; the caller hides it under Reduce Motion.
struct RisoMomentConfetti: View {
    var intensity: Int = 7

    private var pieces: [ConfettiPiece] {
        let count = 8 + Swift.max(1, Swift.min(10, intensity)) * 8
        // No green: the field is green.
        let palette: [Color] = [.risoRed, .risoGold, .risoBlue, .risoPaper]
        return (0..<count).map { i -> ConfettiPiece in
            let n = Double(count)
            return ConfettiPiece(
                id: i,
                x: Double(i) / n,
                size: 6 + Double(i % 7) * 2,
                color: palette[i % 4],
                isCircle: i % 3 == 0,
                delay: Double(i) / n * 1.8,
                duration: 1.6 + Double(i % 5) * 0.32
            )
        }
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(pieces) { piece in
                confettiView(piece: piece, containerHeight: geo.size.height)
                    .position(x: piece.x * geo.size.width, y: -20)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func confettiView(piece: ConfettiPiece, containerHeight: CGFloat) -> some View {
        Group {
            if piece.isCircle {
                Circle().fill(piece.color).overlay(Circle().strokeBorder(Color.risoInkStatic, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 2).fill(piece.color)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.risoInkStatic, lineWidth: 1))
            }
        }
        .frame(width: piece.size, height: piece.size)
        .modifier(ConfettiFallModifier(containerHeight: containerHeight, delay: piece.delay, duration: piece.duration))
    }
}

private struct ConfettiPiece: Identifiable {
    let id: Int
    let x: Double       // 0…1 of container width
    let size: Double
    let color: Color
    let isCircle: Bool
    let delay: Double
    let duration: Double
}

private struct ConfettiFallModifier: ViewModifier {
    let containerHeight: CGFloat
    let delay: Double
    let duration: Double
    @State private var offset: CGFloat = 0
    @State private var rotation: Double = 0
    @State private var opacity: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(rotation))
            .offset(y: offset)
            .opacity(opacity)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                        offset = containerHeight + 60
                        rotation = 540
                        opacity = 0.9
                    }
                }
            }
    }
}
