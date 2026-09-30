import SwiftUI

/// Generic tile shell for the two Profile-home tiles (Board settings /
/// Streak) — design handoff §1.2: equal columns, min height 132pt, 14pt
/// padding, 2pt ink border, 7pt radius. Whole-surface tap target
/// (`.contentShape` covers the full frame, not just the opaque glyphs).
///
/// A PASSIVE shell — no `Button` inside, same convention as `RisoProfileRow`
/// (`Views/ProfileTab/Components/RisoProfileRow.swift`): the caller wraps it
/// in whichever navigation primitive it needs (`NavigationLink(value:)` for
/// both Profile-home tiles, which push `ProfileRoute.boardSettings` /
/// `.streaks`) and supplies the matching `RisoProfileTileButtonStyle` for
/// the press/shadow behavior. Nesting an inner `Button` would create the
/// nested-tappable trap `SharedCounterLedgerCard` documents — a
/// `NavigationLink`'s own tap handling must own the whole surface.
///
/// Callers supply the inner layout via the trailing closure — the two tiles
/// differ too much (an icon+chevron header vs. a giant number-on-one-
/// baseline) to share a single "title + summary" API, so this only owns the
/// shell: fill, border (solid or dashed empty-state), and sizing.
struct RisoProfileTile<Content: View>: View {
    var fill: Color = .risoPaper2
    /// `true` for the empty-streak state: dashed `rgba(ink,0.45)` border (no
    /// shadow — pair with `RisoProfileTileButtonStyle(offset: nil)`).
    var dashed: Bool = false
    let content: Content

    private static var minHeight: CGFloat { 132 }

    init(
        fill: Color = .risoPaper2,
        dashed: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.fill = fill
        self.dashed = dashed
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(Riso.cardPadding)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(fill))
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(border)
        .contentShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
    }

    @ViewBuilder
    private var border: some View {
        if dashed {
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(
                    Color.risoInk.opacity(0.45),
                    style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [6, 4])
                )
        } else {
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        }
    }
}

/// Applies `RisoButtonStyle`'s press-into-paper hard shadow (**4×4** offset
/// per the design handoff) when `offset` is non-nil; otherwise renders the
/// label completely unadorned — the dashed empty-streak tile has no shadow
/// or press animation at all.
struct RisoProfileTileButtonStyle: ButtonStyle {
    var offset: CGFloat? = Riso.Shadow.card
    func makeBody(configuration: Configuration) -> some View {
        if let offset {
            RisoButtonStyle(offset: offset, radius: Riso.cardRadius).makeBody(configuration: configuration)
        } else {
            configuration.label
        }
    }
}

// MARK: - Icon tile (34×34, used by both Profile-home tiles)

/// The 34×34 icon square in a tile's top-leading corner — 1.5pt keyline,
/// 7pt radius. `dashed` renders the empty-streak variant (paper fill,
/// dashed muted border).
struct RisoProfileTileIcon: View {
    let systemName: String
    var fill: Color = .risoPaper
    var iconColor: Color = .risoInk
    var borderColor: Color = .risoInk
    var dashed: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(dashed ? Color.risoMuted : iconColor)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(fill))
            .overlay(borderOverlay)
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if dashed {
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(
                    borderColor.opacity(0.45),
                    style: StrokeStyle(lineWidth: Riso.Keyline.dense, dash: [4, 3])
                )
        } else {
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(borderColor, lineWidth: Riso.Keyline.dense)
        }
    }
}

// MARK: - Profile-home tile contents

/// The Board settings tile's inner layout — icon+chevron header, title,
/// two-line summary. Extracted as a concrete props-only view (rather than a
/// private `ProfileView` computed property) so it's directly reusable by
/// `RisoProfileSnapshotTests`' composed-state helper without duplicating
/// markup.
struct ProfileBoardSettingsTileContent: View {
    let defaultsLine: String
    let repeatingLine: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RisoProfileTileIcon(
                    systemName: "slider.horizontal.3",
                    fill: .risoBlue, iconColor: .risoOnColor, borderColor: .risoInk
                )
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text("Board settings")
                    .font(.risoHead(17, .extraBold))
                    .foregroundStyle(Color.risoInk)
                Text(defaultsLine)
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                Text(repeatingLine)
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
            }
        }
    }
}

/// The populated Streak tile's inner layout — headline number + "day
/// streak" on one baseline, "Longest N · N GREENLOGs" below.
struct ProfileStreakTileContent: View {
    let bingoStreak: Int
    let longestStreak: Int
    let greenlogCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RisoProfileTileIcon(
                    systemName: "flame.fill",
                    fill: .risoRed, iconColor: .risoInkStatic, borderColor: .risoInkStatic
                )
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoInkStatic.opacity(0.6))
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(bingoStreak)")
                        .font(.risoHead(28, .extraBold))
                        .foregroundStyle(Color.risoInkStatic)
                    Text("day streak")
                        .font(.risoHead(13, .extraBold))
                        .foregroundStyle(Color.risoInkStatic)
                }
                Text("Longest \(longestStreak) · \(greenlogCount) GREENLOGs")
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoInkStatic.opacity(0.75))
            }
        }
    }
}

/// The empty-streak ("no bingo yet") tile's inner layout — dashed icon
/// tile, muted title + caption, no chevron (there's nothing to drill into
/// yet, though the tile still pushes Streaks).
struct ProfileEmptyStreakTileContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RisoProfileTileIcon(systemName: "flame.fill", dashed: true)
                Spacer()
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text("No streak yet")
                    .font(.risoHead(17, .extraBold))
                    .foregroundStyle(Color.risoMuted)
                Text("Clear a board to start one.")
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
            }
        }
    }
}

#if DEBUG
#Preview("Tiles") {
    ZStack {
        RisoPaperBackground()
        HStack(spacing: 12) {
            NavigationLink(value: Int(0)) {
                RisoProfileTile {
                    ProfileBoardSettingsTileContent(
                        defaultsLine: "Defaults 3×3 · Free · Mon",
                        repeatingLine: "2 repeating boards"
                    )
                }
            }
            .buttonStyle(RisoProfileTileButtonStyle())

            RisoProfileTile(fill: .risoGold) {
                ProfileStreakTileContent(bingoStreak: 12, longestStreak: 24, greenlogCount: 37)
            }
        }
        .padding(20)
    }
}

#Preview("Empty streak tile") {
    ZStack {
        RisoPaperBackground()
        RisoProfileTile(dashed: true) { ProfileEmptyStreakTileContent() }
            .padding(20)
    }
}
#endif
