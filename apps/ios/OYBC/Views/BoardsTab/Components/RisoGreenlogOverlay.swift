import SwiftUI

// MARK: - RisoGreenlogOverlay

/// Full-bleed blue celebration overlay triggered when every square on
/// the board is completed (GREENLOG event). Shows a Blip mascot,
/// "GREENLOG!" title, three stat cards, a confetti field, and two
/// action buttons. Dismissible via the "Start a new board" button or
/// by the caller setting `isPresented = false`.
///
/// The confetti loops indefinitely while the overlay is visible.
/// Animations (confetti fall) need user verification since they cannot
/// be snapshot-tested in static mode.
struct RisoGreenlogOverlay: View {

    // MARK: - Data

    let completedTasks: Int
    let totalTasks: Int
    let linesCompleted: Int
    let boardName: String

    // MARK: - Actions

    var onShare: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    // MARK: - Confetti animation

    private let confettiPieces: [ConfettiPiece] = {
        // ~64 pieces (intensity 7 → count = 8 + 7*8 = 64 per spec)
        (0..<64).map { i in
            let rng = Double(i)
            return ConfettiPiece(
                id: i,
                x: Double(i) / 64.0,
                size: 6 + (Double(i % 7) * 2),
                color: [Color.risoRed, Color.risoGold, Color.risoGreen, Color.risoPaper][i % 4],
                isCircle: i % 3 == 0,
                delay: rng / 64.0 * 1.8,
                duration: 1.6 + (Double(i % 5) * 0.32)
            )
        }
    }()

    @State private var confettiOffset: CGFloat = 0
    @State private var confettiVisible = false

    // MARK: - Body

    var body: some View {
        ZStack {
            // Blue background
            Color.risoBlue
                .ignoresSafeArea()

            // Paper grain over the blue
            RisoGrain()
                .ignoresSafeArea()
                .opacity(0.15)

            // Confetti field
            GeometryReader { geo in
                ForEach(confettiPieces) { piece in
                    confettiView(piece: piece, containerHeight: geo.size.height)
                        .position(
                            x: piece.x * geo.size.width,
                            y: -20
                        )
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Main content
            VStack(spacing: 0) {
                Spacer()

                // Blip mascot (cheer mood)
                blipCheer
                    .frame(width: 108, height: 108)
                    .padding(.bottom, 8)

                // Kicker
                Text("BOARD COMPLETE")
                    .risoKicker(.risoGold)
                    .padding(.bottom, 8)

                // "GREENLOG!" title
                Text("GREENLOG!")
                    .font(.risoHead(52, .extraBold))
                    .tracking(-1.56)
                    .foregroundStyle(Color.risoPaper)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.bottom, 14)

                // Subtitle
                Text("Full board. Every single square.\n\(boardName) — crushed.")
                    .font(.risoBody(14, .semibold))
                    .foregroundStyle(Color(red: 0.79, green: 0.81, blue: 0.95))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 240)
                    .padding(.bottom, 4)

                // Stat cards
                HStack(spacing: 10) {
                    greenlogStatCard(value: "\(completedTasks)/\(totalTasks)", label: "SQUARES")
                    greenlogStatCard(value: "\(linesCompleted)", label: "BINGOS")
                    greenlogStatCard(value: "7d", label: "STREAK")
                }
                .padding(.vertical, 20)

                // Action buttons
                VStack(spacing: 11) {
                    // "Share my board" — red primary
                    Button {
                        onShare?()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Share my board")
                                .font(.risoHead(17, .bold))
                        }
                        .foregroundStyle(Color.risoPaper)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.risoRed)
                        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                        )
                        .background(
                            RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .fill(Color.risoInk)
                                .offset(x: Riso.Shadow.button, y: Riso.Shadow.button)
                        )
                    }
                    .buttonStyle(.plain)

                    // "Start a new board" — transparent / cream ghost
                    Button {
                        onDismiss?()
                    } label: {
                        Text("Start a new board")
                            .font(.risoHead(17, .bold))
                            .foregroundStyle(Color.risoPaper)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .overlay(
                                RoundedRectangle(cornerRadius: Riso.cardRadius)
                                    .strokeBorder(Color.risoPaper, lineWidth: Riso.Keyline.container)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 230)

                Spacer()
            }
            .padding(.horizontal, Riso.gutter + 6)
        }
        .onAppear {
            confettiVisible = true
        }
    }

    // MARK: - Stat card

    @ViewBuilder
    private func greenlogStatCard(value: String, label: String) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text(value)
                .font(.risoHead(22, .extraBold))
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
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
        .background(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .fill(Color.risoInk)
                .offset(x: Riso.Shadow.button, y: Riso.Shadow.button)
        )
    }

    // MARK: - Blip (cheer mood)

    /// Overprint sticker character in "cheer" pose — arms-up energy.
    private var blipCheer: some View {
        ZStack {
            // Gold star spark
            StarShape()
                .fill(Color.risoGold)
                .frame(width: 16, height: 16)
                .offset(x: 30, y: -36)

            // Red backing circle (multiply)
            Circle()
                .fill(Color.risoRed.opacity(0.85))
                .blendMode(.multiply)
                .frame(width: 90, height: 90)
                .offset(x: -8, y: 10)

            // Blue halftone body
            Circle()
                .fill(Color.risoBlue)
                .risoHalftone(tile: 6, layerOpacity: 0.35)
                .clipShape(Circle())
                .frame(width: 80, height: 80)

            // Cream eyes
            HStack(spacing: 20) {
                Circle()
                    .fill(Color.risoPaper)
                    .frame(width: 12, height: 14)
                Circle()
                    .fill(Color.risoPaper)
                    .frame(width: 12, height: 14)
            }
            .offset(y: -6)

            // Ink pupils
            HStack(spacing: 20) {
                Circle().fill(Color.risoInk).frame(width: 5, height: 5)
                Circle().fill(Color.risoInk).frame(width: 5, height: 5)
            }
            .offset(y: -6)

            // Gold grin
            Path { path in
                path.move(to: CGPoint(x: 6, y: 10))
                path.addQuadCurve(
                    to: CGPoint(x: 46, y: 10),
                    control: CGPoint(x: 26, y: 26)
                )
            }
            .stroke(Color.risoGold, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 52, height: 30)
            .offset(y: 10)
        }
    }

    // MARK: - Confetti

    @ViewBuilder
    private func confettiView(piece: ConfettiPiece, containerHeight: CGFloat) -> some View {
        Group {
            if piece.isCircle {
                Circle()
                    .fill(piece.color)
                    .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(piece.color)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.risoInk, lineWidth: 1))
            }
        }
        .frame(width: piece.size, height: piece.size)
        .confettiFall(
            containerHeight: containerHeight,
            delay: piece.delay,
            duration: piece.duration
        )
    }
}

// MARK: - Confetti model

private struct ConfettiPiece: Identifiable {
    let id: Int
    let x: Double       // 0…1 of container width
    let size: Double
    let color: Color
    let isCircle: Bool
    let delay: Double
    let duration: Double
}

// MARK: - ConfettiFall modifier

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
                // Staggered start
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
    func confettiFall(containerHeight: CGFloat, delay: Double, duration: Double) -> some View {
        modifier(ConfettiFallModifier(containerHeight: containerHeight, delay: delay, duration: duration))
    }
}

// MARK: - Preview

#Preview("GREENLOG overlay — light") {
    RisoGreenlogOverlay(
        completedTasks: 25,
        totalTasks: 25,
        linesCompleted: 12,
        boardName: "Weekly Wellness"
    )
}

#Preview("GREENLOG overlay — dark") {
    RisoGreenlogOverlay(
        completedTasks: 25,
        totalTasks: 25,
        linesCompleted: 12,
        boardName: "Weekly Wellness"
    )
    .environment(\.colorScheme, .dark)
}
