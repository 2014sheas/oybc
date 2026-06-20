import SwiftUI

/// Full-bleed celebration shown when the user clears all 8 tutorial squares
/// (handoff §0a). A mascot-free variant of `RisoGreenlogOverlay`: a keyline
/// star spark instead of Blip, "Tutorial cleared" / "YOU'RE READY!", two stat
/// cards, and Create / Back actions.
///
/// The confetti machinery is copied (not shared) from `RisoGreenlogOverlay`:
/// those pieces are `private` there, and copying ~30 lines avoids touching the
/// snapshot-tested production overlay.
struct TutorialGreenlogOverlay: View {
    var onCreateBoard: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    private var confettiPieces: [TutorialConfettiPiece] {
        let count = 64
        let palette: [Color] = [.risoRed, .risoGold, .risoGreen, .risoPaper]
        var pieces: [TutorialConfettiPiece] = []
        pieces.reserveCapacity(count)
        for i in 0..<count {
            let x: Double = Double(i) / Double(count)
            let size: Double = 6 + (Double(i % 7) * 2)
            let delay: Double = x * 1.8
            let duration: Double = 1.6 + (Double(i % 5) * 0.32)
            pieces.append(TutorialConfettiPiece(
                id: i, x: x, size: size, color: palette[i % 4],
                isCircle: i % 3 == 0, delay: delay, duration: duration
            ))
        }
        return pieces
    }

    var body: some View {
        ZStack {
            Color.risoBlue.ignoresSafeArea()
            RisoGrain().ignoresSafeArea().opacity(0.15)

            GeometryReader { geo in
                ForEach(confettiPieces) { piece in
                    confettiView(piece: piece, containerHeight: geo.size.height)
                        .position(x: piece.x * geo.size.width, y: -20)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()

                // Keyline star spark (mascot-free)
                ZStack {
                    StarShape()
                        .fill(Color.risoGold)
                        .frame(width: 76, height: 76)
                    StarShape()
                        .stroke(Color.risoInk, lineWidth: 3)
                        .frame(width: 76, height: 76)
                }
                .padding(.bottom, 14)

                Text("TUTORIAL CLEARED")
                    .risoKicker(.risoGold)
                    .padding(.bottom, 8)

                Text("YOU'RE READY!")
                    .font(.risoHead(52, .extraBold))
                    .tracking(-1.56)
                    .foregroundStyle(Color.risoPaper)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.bottom, 14)

                Text("You've learned every move.\nGo build your first real board.")
                    .font(.risoBody(14, .semibold))
                    .foregroundStyle(Color(red: 0.79, green: 0.81, blue: 0.95))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 240)
                    .padding(.bottom, 4)

                HStack(spacing: 10) {
                    statCard(value: "8/8", label: "MOVES LEARNED")
                    statCard(value: "1st", label: "GREENLOG")
                }
                .padding(.vertical, 20)

                VStack(spacing: 11) {
                    Button { onCreateBoard?() } label: {
                        Text("Create my first board")
                            .font(.risoHead(17, .bold))
                            .foregroundStyle(Color.risoPaper)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Color.risoRed)
                            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                            .background(RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .fill(Color.risoInk)
                                .offset(x: Riso.Shadow.button, y: Riso.Shadow.button))
                    }
                    .buttonStyle(.plain)

                    Button { onDismiss?() } label: {
                        Text("Back to boards")
                            .font(.risoHead(17, .bold))
                            .foregroundStyle(Color.risoPaper)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .strokeBorder(Color.risoPaper, lineWidth: Riso.Keyline.container))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 230)

                Spacer()
            }
            .padding(.horizontal, Riso.gutter + 6)
        }
    }

    @ViewBuilder
    private func statCard(value: String, label: String) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text(value)
                .font(.risoHead(22, .extraBold))
                // Card fill is `risoPaper` (adaptive → dark in dark mode), so the
                // value needs adaptive `risoInk` (cream in dark) — NOT
                // risoInkStatic, which would be dark-on-dark. (risoInkStatic is
                // only for content on the always-bright gold.)
                .foregroundStyle(Color.risoInk)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.risoBody(9, .bold))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(Color.risoMuted)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Color.risoPaper)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius)
            .fill(Color.risoInk)
            .offset(x: Riso.Shadow.button, y: Riso.Shadow.button))
    }

    @ViewBuilder
    private func confettiView(piece: TutorialConfettiPiece, containerHeight: CGFloat) -> some View {
        Group {
            if piece.isCircle {
                Circle().fill(piece.color)
                    .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 2).fill(piece.color)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.risoInk, lineWidth: 1))
            }
        }
        .frame(width: piece.size, height: piece.size)
        .tutorialConfettiFall(containerHeight: containerHeight, delay: piece.delay, duration: piece.duration)
    }
}

// MARK: - Confetti (copied from RisoGreenlogOverlay; those types are private there)

private struct TutorialConfettiPiece: Identifiable {
    let id: Int
    let x: Double
    let size: Double
    let color: Color
    let isCircle: Bool
    let delay: Double
    let duration: Double
}

private struct TutorialConfettiFallModifier: ViewModifier {
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

private extension View {
    func tutorialConfettiFall(containerHeight: CGFloat, delay: Double, duration: Double) -> some View {
        modifier(TutorialConfettiFallModifier(containerHeight: containerHeight, delay: delay, duration: duration))
    }
}

#if DEBUG
#Preview("Tutorial GREENLOG") {
    TutorialGreenlogOverlay()
}
#endif
