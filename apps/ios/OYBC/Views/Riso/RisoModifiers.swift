import SwiftUI

// MARK: - Keyline card

extension View {
    /// Paper card surface: fill + hard ink keyline + rounded corners, content
    /// clipped to the radius. No shadow (compose with `.risoHardShadow` or
    /// `RisoButtonStyle` when elevation/press is wanted).
    func risoCard(
        radius: CGFloat = Riso.cardRadius,
        keyline: CGFloat = Riso.Keyline.container,
        fill: Color = .risoPaper2
    ) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.risoInk, lineWidth: keyline)
            )
    }
}

// MARK: - Hard shadow (static, non-pressable)

private struct RisoHardShadow: ViewModifier {
    let offset: CGFloat
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius)
                .fill(Color.risoInk)
                .offset(x: offset, y: offset)
        )
    }
}

extension View {
    /// Hard offset ink shadow (no blur) behind an elevated, non-interactive
    /// element. For tappable elements use `RisoButtonStyle`, which collapses
    /// the shadow on press.
    func risoHardShadow(
        _ offset: CGFloat = Riso.Shadow.card,
        radius: CGFloat = Riso.cardRadius
    ) -> some View {
        modifier(RisoHardShadow(offset: offset, radius: radius))
    }
}

// MARK: - Pressable button style

/// The signature "press into the paper" interaction: a hard offset ink
/// shadow that, on press, collapses to 0 while the label translates by the
/// offset. Apply to any `Button` whose label already carries `.risoCard()`
/// styling (or is otherwise opaque).
struct RisoButtonStyle: ButtonStyle {
    var offset: CGFloat = Riso.Shadow.button
    var radius: CGFloat = Riso.cardRadius

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.risoInk)
                    .offset(x: pressed ? 0 : offset, y: pressed ? 0 : offset)
            )
            .offset(x: pressed ? offset : 0, y: pressed ? offset : 0)
            .animation(.easeOut(duration: Riso.pressDuration), value: pressed)
    }
}

// MARK: - Paper grain background

/// 3px-tile dot grid at ~5% ink, multiply blend — the resting "paper" texture
/// behind every screen. Static; drawn once.
struct RisoGrain: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 3
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1, height: 1))
            let paint = GraphicsContext.Shading.color(Color.risoInk.opacity(0.05))
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(dot.offsetBy(dx: x, dy: y), with: paint)
                    x += step
                }
                y += step
            }
        }
        .blendMode(.multiply)
        .allowsHitTesting(false)
    }
}

/// Full-bleed app background: paper color + grain. Place at the back of a
/// screen's ZStack.
struct RisoPaperBackground: View {
    var body: some View {
        Color.risoPaper
            .overlay(RisoGrain())
            .ignoresSafeArea()
    }
}

// MARK: - Halftone overprint (completed cells)

private struct RisoHalftone: ViewModifier {
    var tile: CGFloat = 7
    /// Opacity of the whole multiply overlay layer. Mirrors `riso.css`: the
    /// dot screen is ink at 0.5 alpha (the `rgba(…, .5)` radial-gradient dots)
    /// painted under a layer at this opacity. The two alphas are intentional
    /// (faithful to the source), not a double-application bug.
    var layerOpacity: Double = 0.55
    func body(content: Content) -> some View {
        content.overlay(
            Canvas { ctx, size in
                let r: CGFloat = tile * 0.27   // dot ≈ 26–28% of the tile
                let paint = GraphicsContext.Shading.color(Color.risoInk.opacity(0.5))
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width {
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                            with: paint
                        )
                        x += tile
                    }
                    y += tile
                }
            }
            .blendMode(.multiply)
            .opacity(layerOpacity)
            .allowsHitTesting(false)
        )
    }
}

extension View {
    /// Radial-dot overprint screen drawn over a completed (ink-filled) cell.
    func risoHalftone(tile: CGFloat = 7, layerOpacity: Double = 0.55) -> some View {
        modifier(RisoHalftone(tile: tile, layerOpacity: layerOpacity))
    }
}
