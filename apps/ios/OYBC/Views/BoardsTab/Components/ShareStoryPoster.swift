import SwiftUI

// MARK: - ShareStoryPoster

/// The share sheet's raster target (handoff §5c / §5d): a 9:16 story card,
/// 236 × 420 pt, drawn ONLY from static colours so the export is identical
/// in both appearances (`ImageRenderer` also forces `.light`). The cells are
/// the board's real end state from `momentPosterCells`; the poster never
/// re-derives completion.
struct ShareStoryPoster: View {
    let content: BoardShareContent
    let cells: [PosterCell]
    var showTaskNames: Bool = true

    static let width: CGFloat = 236
    static let height: CGFloat = 420
    private static let gridSide: CGFloat = 196
    private static let gap: CGFloat = 4

    // Static palette (hex from the handoff Tokens; never `Color.riso*`).
    private static let ink = Color(red: 0x18 / 255, green: 0x12 / 255, blue: 0x0b / 255)
    private static let paper = Color(red: 0xfb / 255, green: 0xf6 / 255, blue: 0xea / 255)
    private static let gold = Color(red: 0xff / 255, green: 0xc2 / 255, blue: 0x1f / 255)
    private static let red = Color(red: 0xeb / 255, green: 0x4d / 255, blue: 0x2e / 255)
    private static let blue = Color(red: 0x2c / 255, green: 0x44 / 255, blue: 0xc9 / 255)
    private static let teal = Color(red: 0x0e / 255, green: 0x8f / 255, blue: 0x96 / 255)
    private static let green = Color(red: 0x1f / 255, green: 0x9b / 255, blue: 0x6b / 255)
    private static let muted = Color(red: 0x7e / 255, green: 0x74 / 255, blue: 0x60 / 255)

    private var fill: Color { content.kind == .bingo ? Self.blue : Self.green }
    private var columns: Int { Swift.max(1, content.boardSize) }
    private var cellSide: CGFloat { (Self.gridSide - Self.gap * CGFloat(columns - 1)) / CGFloat(columns) }

    var body: some View {
        VStack(spacing: 8) {
            topRow
            Text(content.boardName)
                .font(.risoHead(22, .extraBold)).tracking(-0.44)
                .foregroundStyle(Self.paper)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            gridInset
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ForEach(content.stats, id: \.label) { statCard($0) }
            }
            Text(content.tagline)
                .font(.risoHead(10, .bold)).tracking(1.4).textCase(.uppercase)
                .foregroundStyle(Self.paper.opacity(0.7))
        }
        .padding(14)
        .frame(width: Self.width, height: Self.height)
        .background(Rectangle().fill(fill).risoHalftone(tile: 9, layerOpacity: 0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .environment(\.colorScheme, .light)
    }

    private var topRow: some View {
        HStack {
            Text(content.badge)
                .font(.risoHead(11, .extraBold)).tracking(0.88)
                .foregroundStyle(Self.ink)
                .padding(.vertical, 3).padding(.horizontal, 10)
                .background(Capsule().fill(Self.gold))
                .overlay(Capsule().strokeBorder(Self.ink, lineWidth: 1.5))
            Spacer()
            Text("OYBC").font(.risoHead(16, .extraBold)).tracking(-0.16).foregroundStyle(Self.paper)
        }
    }

    private var gridInset: some View {
        VStack(spacing: Self.gap) {
            ForEach(0..<columns, id: \.self) { row in
                HStack(spacing: Self.gap) {
                    ForEach(0..<columns, id: \.self) { col in
                        cellView(at: row * columns + col)
                    }
                }
            }
        }
        .frame(width: Self.gridSide, height: Self.gridSide)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Self.paper))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Self.ink, lineWidth: 1.5))
    }

    @ViewBuilder
    private func cellView(at idx: Int) -> some View {
        if let c = cells.first(where: { $0.idx == idx }) {
            cell(c)
        } else {
            Color.clear.frame(width: cellSide, height: cellSide)
        }
    }

    private func cell(_ c: PosterCell) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        let lit = c.state != .undone
        let background: Color = c.isFree && c.state != .green ? Self.ink : doneFill(c)
        return ZStack {
            shape.fill(c.state == .undone && !c.isFree ? Self.paper : background)
                .modifier(PosterHalftone(on: lit && !(c.isFree && c.state != .green)))
            if c.isFree {
                StarShape().fill(Self.gold).padding(cellSide * 0.2)
            } else if showTaskNames {
                Text(c.label)
                    .font(.risoHead(Swift.min(14, Swift.max(6.5, cellSide * 0.165)), .bold))
                    .foregroundStyle(lit ? Self.paper : Self.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.9)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
            }
        }
        .frame(width: cellSide, height: cellSide)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Self.ink, lineWidth: 1.5))
        .background(
            shape.fill(Self.ink).offset(x: 2, y: 2).opacity(lit ? 1 : 0)
        )
    }

    private func doneFill(_ c: PosterCell) -> Color {
        if c.state == .green { return Self.green }
        switch c.type {
        case .counting: return Self.blue
        case .compound: return Self.teal
        case .normal, .achievement: return Self.red
        }
    }

    private func statCard(_ s: BoardShareContent.Stat) -> some View {
        VStack(spacing: 4) {
            Text(s.value)
                .font(.risoHead(17, .extraBold)).foregroundStyle(Self.ink)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(s.label)
                .font(.risoBody(8.5, .bold)).tracking(1.0).textCase(.uppercase)
                .foregroundStyle(Self.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Self.paper))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Self.ink, lineWidth: 1.5))
    }
}

/// Halftone overprint for lit cells (a no-op when off).
private struct PosterHalftone: ViewModifier {
    let on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.risoHalftone(tile: 5, layerOpacity: 0.55) } else { content }
    }
}
