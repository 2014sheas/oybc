import SwiftUI

// MARK: - RisoMiniBoardArt

/// Mini bingo-board motif — the kit-level replacement for the retired
/// `BlipPlaceholder` shape-mascot (Blip-retirement handoff, 2026-09-10).
/// A framed grid of Riso cells whose styles are lifted from
/// `OnboardingView.OnboardingPosterGrid.cell(for:)`, with a staggered
/// cell pop-in on appear.
///
/// States map surfaces to art: `.empty` (Boards empty state), `.started`
/// (core setup prompt), `.draft` (board-play draft guard), `.bingo(cells)`
/// (onboarding sign-in, bingo toast), `.greenlog` (greenlog overlay).
///
/// The FREE cell fills with `risoInkStatic` — never `risoInk`, which flips
/// to cream in dark mode and would swallow the gold star.
struct RisoMiniBoardArt: View {

    enum ArtState: Equatable {
        /// All paper cells.
        case empty
        /// Top-left + bottom-right lit.
        case started
        /// Dashed muted cells (handoff pattern; defined for 3×3, other
        /// grids alternate).
        case draft
        /// The given cell indices lit (reading order, 0-based).
        case bingo(Set<Int>)
        /// Every non-FREE cell lit.
        case greenlog
    }

    /// OUTER edge, frame included.
    var size: CGFloat = 72
    /// 3 · 4 · 5.
    var grid: Int = 3
    var state: ArtState = .empty
    /// False renders the bare cell grid (bingo toast's on-blue slot).
    var framed: Bool = true
    /// Applied after the pop-in completes (greenlog passes −4°).
    var tilt: Angle = .zero
    /// One-shot pop-in on appear; renders the final state immediately
    /// under Reduce Motion. Never loops.
    var popsInOnAppear: Bool = true
    /// On-blue variant (toast/greenlog surfaces drawn on `risoBlue`):
    /// unlit cells go translucent-paper with no stroke; lit/FREE strokes
    /// use `risoInkStatic` at 1pt.
    var onBlue: Bool = false

    @State private var popped = false
    @State private var currentTilt: Angle = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Same convention as `OYBCApp.isRunningTests`: under XCTest the pop-in
    /// renders its FINAL state immediately, so surface snapshots (empty
    /// state, prompts, overlay, toast) stay deterministic instead of
    /// capturing frame 0 of the scale animation (cells at ~0).
    private static let isRunningTests = NSClassFromString("XCTest") != nil

    // MARK: Geometry (handoff §Geometry)

    private var framePadding: CGFloat { framed ? 6 : 0 }
    private var gap: CGFloat { grid >= 5 ? 3 : 4 }
    private var cellEdge: CGFloat {
        let inner = size - framePadding * 2
        return (inner - gap * CGFloat(grid - 1)) / CGFloat(grid)
    }
    private var cellRadius: CGFloat { cellEdge >= 16 ? 4 : 3 }
    /// FREE cell = center index, odd grids only.
    private var freeIndex: Int? { grid % 2 == 1 ? grid * grid / 2 : nil }
    private var cellCount: Int { grid * grid }

    private var motionEnabled: Bool {
        popsInOnAppear && !reduceMotion && !Self.isRunningTests
    }
    private var stagger: Double { state == .greenlog ? 0.030 : 0.055 }
    private var popDuration: Double { 0.34 }
    /// Time until the last cell's pop finishes (FREE pops last).
    private var totalPopTime: Double {
        Double(cellCount - 1) * stagger + popDuration
    }

    var body: some View {
        Group {
            if framed {
                cellsGrid
                    .padding(framePadding)
                    .background(Color.risoPaper2)
                    .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                    )
                    .risoHardShadow(Riso.Shadow.button, radius: Riso.cardRadius)
            } else {
                cellsGrid
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(motionEnabled ? currentTilt : tilt)
        .onAppear(perform: startMotion)
    }

    private var cellsGrid: some View {
        VStack(spacing: gap) {
            ForEach(0..<grid, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<grid, id: \.self) { col in
                        let index = row * grid + col
                        cell(for: index)
                            .frame(width: cellEdge, height: cellEdge)
                            // With motion disabled the FIRST frame is final —
                            // never rely on onAppear having fired (snapshot
                            // capture can precede it).
                            .scaleEffect(popped || !motionEnabled ? 1 : 0.001)
                            .animation(
                                motionEnabled
                                    ? Animation.timingCurve(0.2, 0.9, 0.3, 1.4, duration: popDuration)
                                        .delay(popDelay(for: index))
                                    : nil,
                                value: popped
                            )
                    }
                }
            }
        }
    }

    // MARK: Cell resolution

    private enum CellKind { case paper, lit, free, dashed }

    private func kind(for index: Int) -> CellKind {
        if index == freeIndex { return .free }
        switch state {
        case .empty:
            return .paper
        case .started:
            return (index == 0 || index == cellCount - 1) ? .lit : .paper
        case .draft:
            return draftDashedIndices.contains(index) ? .dashed : .paper
        case .bingo(let lit):
            return lit.contains(index) ? .lit : .paper
        case .greenlog:
            return .lit
        }
    }

    /// Handoff draft pattern (3×3, reading order):
    /// dashed dashed paper / paper FREE dashed / dashed paper dashed.
    /// Other grids (unused today) alternate even-index dashed.
    private var draftDashedIndices: Set<Int> {
        if grid == 3 { return [0, 1, 5, 6, 8] }
        return Set(stride(from: 0, to: cellCount, by: 2)).subtracting([freeIndex ?? -1])
    }

    @ViewBuilder
    private func cell(for index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: cellRadius)
        switch kind(for: index) {
        case .paper:
            if onBlue {
                shape.fill(Color.risoPaper.opacity(0.35))
            } else {
                shape.fill(Color.risoPaper2)
                    .overlay(shape.strokeBorder(Color.risoInk, lineWidth: 1.5))
            }
        case .lit:
            shape.fill(Color.risoRed)
                .risoHalftone(tile: 5, layerOpacity: 0.45)
                .clipShape(shape)
                .overlay(
                    onBlue
                        ? shape.strokeBorder(Color.risoInkStatic, lineWidth: 1)
                        : shape.strokeBorder(Color.risoInk, lineWidth: 1.5)
                )
        case .free:
            freeCell(shape: shape)
        case .dashed:
            shape.strokeBorder(
                Color.risoMuted,
                style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
            )
        }
    }

    @ViewBuilder
    private func freeCell(shape: RoundedRectangle) -> some View {
        // On-blue FREE sitting on a lit line reads gold (handoff §On-blue);
        // everywhere else the FREE cell is ink-static with a gold star.
        if onBlue, freeOnLitLine {
            shape.fill(Color.risoGold)
                .overlay(shape.strokeBorder(Color.risoInkStatic, lineWidth: 1))
                .overlay(
                    Image(systemName: "star.fill")
                        .font(.system(size: cellEdge * 0.55, weight: .bold))
                        .foregroundStyle(Color.risoInkStatic)
                )
        } else {
            shape.fill(Color.risoInkStatic)
                .overlay(
                    Image(systemName: "star.fill")
                        .font(.system(size: cellEdge * 0.55, weight: .bold))
                        .foregroundStyle(Color.risoGold)
                )
        }
    }

    private var freeOnLitLine: Bool {
        guard let free = freeIndex else { return false }
        switch state {
        case .bingo(let lit): return lit.contains(free)
        case .greenlog: return true
        default: return false
        }
    }

    // MARK: Motion

    /// Reading-order stagger with the FREE cell popping last.
    private func popDelay(for index: Int) -> Double {
        guard let free = freeIndex else { return Double(index) * stagger }
        let position: Int
        if index == free {
            position = cellCount - 1
        } else if index > free {
            position = index - 1
        } else {
            position = index
        }
        return Double(position) * stagger
    }

    private func startMotion() {
        guard !popped else { return } // plays once; never loops
        if motionEnabled {
            popped = true
            if tilt != .zero {
                withAnimation(.easeInOut(duration: 0.32).delay(totalPopTime)) {
                    currentTilt = tilt
                }
            }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                popped = true
                currentTilt = tilt
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("States") {
    ZStack {
        RisoPaperBackground()
        VStack(spacing: 24) {
            HStack(spacing: 24) {
                RisoMiniBoardArt(size: 72, state: .empty)
                RisoMiniBoardArt(size: 72, state: .started)
                RisoMiniBoardArt(size: 72, state: .draft)
            }
            HStack(spacing: 24) {
                RisoMiniBoardArt(size: 84, state: .bingo([0, 1, 2]))
                RisoMiniBoardArt(size: 108, grid: 5, state: .greenlog, tilt: .degrees(-4))
            }
        }
    }
}

#Preview("On blue (toast slot)") {
    ZStack {
        Color.risoBlue.ignoresSafeArea()
        RisoMiniBoardArt(
            size: 42, grid: 5, state: .bingo([10, 11, 12, 13, 14]),
            framed: false, onBlue: true
        )
    }
}
#endif
