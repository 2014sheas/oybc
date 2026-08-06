import SwiftUI

// MARK: - RisoBoardPlayCell

/// The Riso-styled play-board cell used by `BoardPlayView`.
///
/// Handles five visual variants — resting, done (normal/counting/compound),
/// FREE/center, and bingo-line-highlighted — all driven purely by props.
/// Tap routing is the caller's responsibility; this component is
/// presentation-only so it can be snapshot-tested without a DB.
///
/// - Note: This cell is play-board–specific and implements the full Riso
///   treatment; it is the canonical board-cell renderer.
struct RisoBoardPlayCell: View {

    // MARK: - Input

    let title: String
    let taskType: CellTaskType
    let isCompleted: Bool
    var isBingoLine: Bool = false
    var isCenter: Bool = false
    var isLocked: Bool = false

    // Counting cells
    var currentCount: Int = 0
    var maxCount: Int = 0
    /// True when this counting square belongs to a shared-counter group (source or linked).
    /// Renders the ↔ shared marker (two stacked dots) on not-yet-completed counting cells.
    var isSharedCounter: Bool = false

    // Compound cells
    var compoundDoneCount: Int = 0
    var compoundChildCount: Int = 0
    /// Operator-aware completion target for the compound progress bar
    /// (AND → child count, OR → 1, M_OF_N → threshold), mirroring web's
    /// DetailModal fractions in `interactiveTaskSquareUtils.progressFraction`.
    /// `nil` falls back to `compoundChildCount` (AND semantics) so preview/
    /// fixture call sites that predate the operator-aware bar are unaffected.
    var compoundRequiredCount: Int? = nil

    var onTap: (() -> Void)? = nil

    // MARK: - Animation

    /// Animate the pop when the cell transitions from incomplete → complete.
    @State private var popScale: CGFloat = 1.0

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            cellContent(size: size)
                .frame(width: size, height: size)
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: isCompleted) { old, new in
            if !old && new {
                triggerCompletionPop()
            }
        }
    }

    // MARK: - Cell rendering

    @ViewBuilder
    private func cellContent(size: CGFloat) -> some View {
        ZStack {
            // ── Background layer ──
            RoundedRectangle(cornerRadius: Riso.cellRadius)
                .fill(cellFill)

            // ── Halftone overprint on done cells ──
            if isCompleted && !isCenter {
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .fill(Color.clear)
                    .risoHalftone()
                    .clipShape(RoundedRectangle(cornerRadius: Riso.cellRadius))
            }

            // ── Cell content ──
            if isCenter {
                centerCellContent
            } else {
                taskCellContent(size: size)
            }

            // ── Keyline (outermost, drawn last so it clips nothing) ──
            keylineOverlay
        }
        .scaleEffect(popScale)
        .offset(x: doneOffset, y: doneOffset)
        .background(
            // Hard ink shadow behind done cells (only on completed non-center cells)
            Group {
                if isCompleted && !isCenter {
                    RoundedRectangle(cornerRadius: Riso.cellRadius)
                        .fill(Color.risoInk)
                        .offset(x: 2.5, y: 2.5)
                }
            }
        )
        // Bingo-line gold outer ring — drawn via .overlay so it renders outside the cell bounds
        .overlay(
            Group {
                if isBingoLine {
                    RoundedRectangle(cornerRadius: Riso.cellRadius)
                        .stroke(Color.risoGold, lineWidth: 3)
                        .padding(-3)
                }
            }
        )
        .zIndex(isBingoLine ? 3 : isCompleted ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isLocked, !isCenter else { return }
            onTap?()
        }
        // Accessibility: collapse the cell's text/badges into one element with
        // a descriptive label + button trait, so VoiceOver announces and
        // activates it as a button (the `.onTapGesture` alone exposes no
        // actionable element).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits((isCenter || isLocked) ? [] : .isButton)
        .accessibilityAddTraits(isCompleted ? .isSelected : [])
    }

    /// VoiceOver label: task name + type-appropriate progress/state.
    private var accessibilityLabel: String {
        if isCenter { return title.isEmpty ? "Free space" : "\(title), free space" }
        switch taskType {
        case .counting:
            let sharedSuffix = isSharedCounter ? ", shared counter" : ""
            return "\(title), counting, \(currentCount) of \(maxCount)\(sharedSuffix)"
        case .compound:
            // Same operator-aware target as the visual bar, so VoiceOver
            // never contradicts it (e.g. "1 of 4" on a complete Any-of cell).
            let required = compoundRequiredCount ?? compoundChildCount
            return "\(title), compound, \(min(compoundDoneCount, required)) of \(required) needed subtasks done"
        case .achievement:
            return "\(title), achievement, \(isCompleted ? "earned" : "not yet earned")"
        case .normal:
            return "\(title), \(isCompleted ? "completed" : "not completed")"
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var centerCellContent: some View {
        VStack(spacing: 3) {
            // Gold star shape
            StarShape()
                .fill(Color.risoGold)
                .frame(width: 17, height: 17)
            // Render the passed-in title, falling back to "FREE" when empty.
            // Scale/clamp so a longer title still fits the small cell.
            Text(title.isEmpty ? "FREE" : title)
                .font(.risoHead(9, .extraBold))
                .tracking(1.0)
                .foregroundStyle(Color.risoGold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
        }
    }

    @ViewBuilder
    private func taskCellContent(size: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Main label — vertically centered
            Text(title)
                .font(.risoBody(9, .bold))
                .tracking(-0.09)
                .lineLimit(isCompleted ? 2 : 3)
                .multilineTextAlignment(.center)
                // Incomplete bingo-line cells fill gold — use non-inverting ink
                // so the title stays readable in dark mode.
                .foregroundStyle(
                    isCompleted
                        ? Color.risoPaper
                        : (isBingoLine ? Color.risoInkStatic : Color.risoInk)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 4)
                .padding(.top, hasTopTag ? 20 : 6)
                .padding(.bottom, hasBottomBar ? 18 : 6)

            // Type tag — top-left (counting or compound; hidden on done counting → blue bg)
            if taskType == .counting {
                Text("×\(maxCount)")
                    .font(.risoHead(7, .extraBold))
                    .foregroundStyle(Color.risoPaper)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.risoBlue)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                    )
                    .padding(.top, 3)
                    .padding(.leading, 4)

            } else if taskType == .compound {
                Text("C")
                    .font(.risoHead(7, .extraBold))
                    .foregroundStyle(Color.risoPaper)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.risoGreen)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                    )
                    .padding(.top, 3)
                    .padding(.leading, 4)
            }

            // Gold check circle — top-right, done cells only
            if isCompleted {
                ZStack {
                    Circle()
                        .fill(Color.risoGold)
                        .frame(width: 15, height: 15)
                    Circle()
                        .strokeBorder(Color.risoInk, lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(Color.risoInk)
                }
                .padding(.top, 3)
                .padding(.trailing, 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            // ↔ Shared-counter marker — top-right, not-done shared counting cells only.
            // Two stacked dots (handoff `.cn-link`) indicate this square feeds a shared
            // counter. Hidden once completed (check takes over the slot).
            if isSharedCounter && !isCompleted && taskType == .counting {
                VStack(spacing: 2) {
                    Circle()
                        .fill(Color.risoBlue)
                        .frame(width: 3, height: 3)
                    Circle()
                        .fill(Color.risoBlue)
                        .frame(width: 3, height: 3)
                }
                .padding(.top, 4)
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            // Bottom progress bar for counting / compound
            if hasBottomBar {
                bottomProgressBar
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private var bottomProgressBar: some View {
        let (cur, max, color): (Int, Int, Color) = {
            switch taskType {
            case .counting:
                return (currentCount, maxCount, Color.risoBlue)
            case .compound:
                // Denominator = the operator's completion target, so an
                // "Any of" square reads 1/1 (not 1/4) once any child is done.
                let required = compoundRequiredCount ?? compoundChildCount
                return (min(compoundDoneCount, required), required, Color.risoGreen)
            default:
                return (0, 1, Color.risoBlue)
            }
        }()
        let fraction = max > 0 ? Double(min(cur, max)) / Double(max) : 0

        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.risoPaper)
            if fraction > 0 {
                GeometryReader { geo in
                    Capsule()
                        .fill(color)
                        .frame(width: fraction * geo.size.width)
                }
            }
            Text("\(cur)/\(max)")
                .font(.system(size: 6, weight: .black, design: .default))
                .foregroundStyle(Color.risoInk)
                .frame(maxWidth: .infinity)
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: 1.5))
        .frame(height: 9)
    }

    // MARK: - Computed style helpers

    private var cellFill: Color {
        if isCenter { return Color.risoInk }
        if !isCompleted {
            return isBingoLine ? Color.risoGold : Color.risoPaper2
        }
        // Done — color by type
        switch taskType {
        case .counting: return Color.risoBlue
        case .compound: return Color.risoGreen
        default: return Color.risoRed
        }
    }

    private var keylineOverlay: some View {
        RoundedRectangle(cornerRadius: Riso.cellRadius)
            .strokeBorder(Color.risoInk, lineWidth: isCompleted ? 2.0 : Riso.Keyline.dense)
    }

    /// Translate done cells by −1pt to pair with the +2.5pt ink shadow.
    private var doneOffset: CGFloat {
        isCompleted && !isCenter ? -1 : 0
    }

    private var hasTopTag: Bool {
        taskType == .counting || taskType == .compound
    }

    private var hasBottomBar: Bool {
        (taskType == .counting && maxCount > 0) ||
        (taskType == .compound && compoundChildCount > 0)
    }

    // MARK: - Completion pop

    private func triggerCompletionPop() {
        // .9 → 1.12 → 1 over ~340ms
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) {
            popScale = 0.9
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            withAnimation(.spring(response: 0.20, dampingFraction: 0.45)) {
                popScale = 1.12
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            withAnimation(.spring(response: 0.15, dampingFraction: 0.7)) {
                popScale = 1.0
            }
        }
    }
}

// MARK: - CellTaskType

/// Lightweight cell-type enum for `RisoBoardPlayCell`. Separate from the full
/// `TaskType` so the component can be used in previews + snapshot tests without
/// importing the full model graph.
enum CellTaskType {
    case normal
    case counting
    case compound
    case achievement // renders like normal (read-only)
}

// MARK: - Star shape helper

/// Polygon star used for the FREE-cell star and the Bingos stat card.
struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerR = min(rect.width, rect.height) / 2
        let innerR = outerR * 0.4
        var path = Path()
        for i in 0..<10 {
            let angle = Double(i) * .pi / 5 - .pi / 2
            let r: CGFloat = i.isMultiple(of: 2) ? outerR : innerR
            let pt = CGPoint(
                x: center.x + CGFloat(Foundation.cos(angle)) * r,
                y: center.y + CGFloat(Foundation.sin(angle)) * r
            )
            if i == 0 { path.move(to: pt) }
            else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

#Preview("Play cells — all states") {
    ZStack {
        RisoPaperBackground()
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 5), spacing: 7) {
            RisoBoardPlayCell(title: "Meditate", taskType: .normal, isCompleted: false)
            RisoBoardPlayCell(title: "Read 30 minutes every day", taskType: .normal, isCompleted: true)
            RisoBoardPlayCell(title: "Run", taskType: .counting, isCompleted: false, currentCount: 3, maxCount: 5)
            RisoBoardPlayCell(title: "Steps", taskType: .counting, isCompleted: true, currentCount: 10, maxCount: 10)
            RisoBoardPlayCell(title: "Morning routine", taskType: .compound, isCompleted: false, compoundDoneCount: 2, compoundChildCount: 3)
            RisoBoardPlayCell(title: "Compound done", taskType: .compound, isCompleted: true, compoundDoneCount: 3, compoundChildCount: 3)
            RisoBoardPlayCell(title: "FREE", taskType: .normal, isCompleted: false, isCenter: true)
            RisoBoardPlayCell(title: "Bingo line", taskType: .normal, isCompleted: false, isBingoLine: true)
            RisoBoardPlayCell(title: "Bingo done", taskType: .normal, isCompleted: true, isBingoLine: true)
            RisoBoardPlayCell(title: "Journal", taskType: .normal, isCompleted: false)
            // P2: shared-counter marker
            RisoBoardPlayCell(title: "Push-ups", taskType: .counting, isCompleted: false, currentCount: 20, maxCount: 30, isSharedCounter: true)
            RisoBoardPlayCell(title: "Push-ups", taskType: .counting, isCompleted: true, currentCount: 30, maxCount: 30, isSharedCounter: true)
        }
        .padding(Riso.gutter)
    }
}
