import SwiftUI

/// One square of the tutorial board (handoff 02): available, in progress (a
/// counting-style step bar), done (green, halftone, gold check), Pro-locked, or
/// on the middle-row Bingo line (gold ring). Props-only so it snapshots; the
/// board view owns taps.
struct TutorialBoardCell: View {
    let info: TutorialLessonInfo
    let state: TutorialLessonState
    /// The middle row is complete — done cells on it carry the gold Bingo ring.
    var ringed: Bool = false
    /// Changes when the cell should play the done pop (.9 → 1.12 → 1).
    var popToken: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popScale: CGFloat = 1

    /// A Pro square stays a locked placeholder until its (later) lesson is done.
    private var isPro: Bool { !info.isFree && state != .done }
    private var isDone: Bool { state == .done }
    private var stepsTotal: Int { info.steps.count }

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                // Fill, then the halftone overprint — both UNDER the content so
                // the icon tile and chip stay clean (as in the play cell).
                ZStack {
                    RoundedRectangle(cornerRadius: Riso.cellRadius).fill(fill)
                    if isDone {
                        RoundedRectangle(cornerRadius: Riso.cellRadius)
                            .fill(Color.clear)
                            .risoHalftone()
                            .clipShape(RoundedRectangle(cornerRadius: Riso.cellRadius))
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Riso.cellRadius).strokeBorder(keyline, lineWidth: isDone ? 2 : Riso.Keyline.dense))
            .scaleEffect(popScale)
            .offset(x: isDone ? -1 : 0, y: isDone ? -1 : 0)
            .background(
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .fill(Color.risoInk)
                    .offset(x: 2.5, y: 2.5)
                    .opacity(isDone ? 1 : 0)
            )
            .overlay {
                if ringed && isDone {
                    RoundedRectangle(cornerRadius: Riso.cellRadius)
                        .stroke(Color.risoGold, lineWidth: 3)
                        .padding(-3)
                }
            }
            .zIndex(ringed && isDone ? 1 : 0)
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
            .onChange(of: popToken) { _, _ in playPop() }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(isPro ? "Comes with Pro" : (isDone ? "Replays this lesson" : "Starts this lesson"))
    }

    // MARK: Layout

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                if isPro {
                    proTag
                } else if let glyph = info.glyph {
                    iconTile(glyph)
                }
                Spacer(minLength: 0)
                chip
            }
            Spacer(minLength: 4)
            Text(info.title)
                .font(.risoBody(12, .bold))
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .inProgress(let step) = state, stepsTotal > 0 {
                stepBar(step: step)
                    .padding(.top, 4)
            }
        }
    }

    private func iconTile(_ glyph: String) -> some View {
        Image(systemName: glyph)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Color.risoInk)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.risoPaper))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    private var proTag: some View {
        Text("PRO")
            .font(.risoHead(9, .bold))
            .tracking(0.72)
            .foregroundStyle(Color.risoPaper)
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .background(Capsule().fill(Color.risoInk))
    }

    @ViewBuilder
    private var chip: some View {
        if isPro {
            Image(systemName: "lock")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.risoPaper2))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        } else if isDone {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Color.risoInkStatic)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.risoGold))
                .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.risoPaper)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.risoBlue))
                .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        }
    }

    /// The counting-style bar: the step the lesson is on, over the total — the
    /// same number the board's status line shows ("step 2 of 5" ↔ "2/5").
    private func stepBar(step: Int) -> some View {
        let current = min(step + 1, stepsTotal)
        let fraction = stepsTotal > 0 ? min(max(Double(current) / Double(stepsTotal), 0), 1) : 0
        return ZStack {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.risoPaper)
                    Capsule().fill(Color.risoBlue).frame(width: geo.size.width * fraction)
                }
            }
            Text("\(current)/\(stepsTotal)")
                .font(.risoHead(10, .extraBold))
                .monospacedDigit()
                .foregroundStyle(Color.risoInk)
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        .frame(height: 15)
    }

    // MARK: Style

    private var fill: Color {
        if isDone { return .risoGreen }
        return isPro ? .risoPaper : .risoPaper2
    }

    private var keyline: Color {
        isPro ? Color.risoInk.opacity(0.45) : Color.risoInk
    }

    private var titleColor: Color {
        if isDone { return .risoPaper }
        return isPro ? .risoMuted : .risoInk
    }

    private var accessibilityLabel: String {
        switch state {
        case _ where isPro: return "\(info.title), Pro lesson, locked"
        case .done: return "\(info.title), done"
        case .inProgress(let step): return "\(info.title), step \(min(step + 1, stepsTotal)) of \(stepsTotal)"
        case .notStarted, .unrecognized: return info.title
        }
    }

    // MARK: Pop

    /// The play-cell completion pop (.9 → 1.12 → 1 over ~340ms); a plain fill
    /// under Reduce Motion.
    private func playPop() {
        guard !reduceMotion else { return }
        popScale = 0.9
        withAnimation(.easeOut(duration: 0.17)) { popScale = 1.12 }
        withAnimation(.easeOut(duration: 0.17).delay(0.17)) { popScale = 1 }
    }
}
