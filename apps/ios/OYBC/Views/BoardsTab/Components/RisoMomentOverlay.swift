import SwiftUI

// MARK: - MomentCellInput

/// One grid slot of the moment's board, in END-state terms. The overlay
/// derives how it LOOKS at a given beat from `momentCellVisual`; this only
/// carries what the cell face needs (title, type, counts).
struct MomentCellInput: Equatable, Identifiable {
    enum Slot: Equatable { case task, free, empty }
    let idx: Int
    var id: Int { idx }
    var slot: Slot = .task
    var title: String = ""
    var taskType: CellTaskType = .normal
    /// Whether the cell is complete in the board's end state (it lands during
    /// the replay). Undone cells never land and keep their current counts.
    var endCompleted: Bool = false
    var currentCount: CountValue = 0
    var maxCount: CountValue = 0
    var countKind: CountKind = .discrete
    var compoundDoneCount: Int = 0
    var compoundChildCount: Int = 0
    var compoundRequiredCount: Int? = nil
}

// MARK: - RisoMomentOverlay

/// The full-screen Bingo / Greenlog moment (handoff §5a / §5b). An opaque
/// field (blue for a bingo, green for a greenlog) over the play surface; the
/// board replays on a static cream frame — squares land in completion order,
/// then lines flip green (bingo) or a diagonal sweep turns the board green
/// (greenlog). One `MomentReplayClock` beat drives every cell. Reduce Motion
/// shows the end state at once. Dismissed only by its buttons (no tap-to-close).
struct RisoMomentOverlay: View {
    let kind: MomentTrigger.Kind
    let replay: BoardMomentReplay
    let cells: [MomentCellInput]
    let boardName: String
    /// Lines the board has completed (the kicker's "n").
    let linesCompleted: Int
    /// The greenlog streak count; the chip shows only for a core timeframe
    /// AND a streak above 1.
    var streak: Int = 0
    var timeframe: Timeframe = .custom
    var isCore: Bool = false
    /// Board Preferences "Celebration intensity" (1–10).
    var celebrationIntensity: Int = 7
    /// Snapshot seam: pins the replay at a beat (no clock, no motion).
    var beatOverride: Int? = nil
    var onShare: () -> Void = {}
    /// Dismisses back to the play board.
    var onBack: () -> Void = {}
    /// Greenlog "Start a new board": dismisses AND opens Create.
    var onNewBoard: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var clock = MomentReplayClock()

    private var finalBeat: Int { momentFinalBeat(replay, kind: kind) }
    private var beat: Int { beatOverride ?? (reduceMotion ? finalBeat : clock.beat) }
    private var field: Color { kind == .bingo ? .risoBlue : .risoGreen }
    private var showsStreakChip: Bool {
        kind == .greenlog && isCore && streak > 1 && !streakUnitLabel(timeframe).isEmpty
    }

    // MARK: Body

    var body: some View {
        ZStack {
            field.ignoresSafeArea()

            if kind == .greenlog && !reduceMotion && beatOverride == nil {
                RisoMomentConfetti(intensity: celebrationIntensity)
            }

            VStack(alignment: .leading, spacing: 0) {
                header
                boardFrame
                if showsStreakChip { streakChip.padding(.top, 22) }
                Spacer(minLength: 16)
                buttons
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 20)
        }
        .onAppear {
            guard beatOverride == nil, !reduceMotion else { return }
            clock.start(finalBeat: finalBeat, kind: kind)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind == .bingo ? "Bingo on \(boardName)" : "Greenlog on \(boardName)")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Header

    private var squaresValue: String { "\(momentCounterAt(beat, replay: replay))" }

    @ViewBuilder
    private var header: some View {
        if kind == .bingo {
            Text("LINE COMPLETE · \(linesCompleted) OF \(BingoDetection.totalLineCount(gridSize: replay.size))")
                .font(.risoHead(13, .bold)).tracking(3.64)
                .foregroundStyle(Color.risoGold)
            HStack(alignment: .bottom) {
                Text("BINGO!")
                    .font(.risoHead(84, .extraBold)).tracking(-4.2)
                    .foregroundStyle(Color.risoOnColor)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .padding(.vertical, -14) // tight line height; a fixed frame would shrink the text
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(squaresValue).font(.risoHead(30, .extraBold)).foregroundStyle(Color.risoGold)
                        Text("/\(replay.totalTasks)").font(.risoHead(15, .bold)).foregroundStyle(Color.risoLavender)
                    }
                    Text("SQUARES").font(.risoHead(10, .bold)).tracking(1.4).foregroundStyle(Color.risoLavender)
                }
                .monospacedDigit()
            }
            .padding(.top, 10).padding(.bottom, 22)
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("BOARD COMPLETE")
                    .font(.risoHead(13, .bold)).tracking(3.64)
                    .foregroundStyle(Color.risoGold)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(squaresValue).font(.risoHead(26, .extraBold)).foregroundStyle(Color.risoGold)
                    Text("/\(replay.totalTasks) squares").font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoOnColor.opacity(0.75))
                }
                .monospacedDigit()
            }
            Text("GREENLOG!")
                .font(.risoHead(66, .extraBold)).tracking(-2.97)
                .foregroundStyle(Color.risoOnColor)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.vertical, -10) // tight line height; a fixed frame would shrink the text
                .padding(.top, 10).padding(.bottom, 22)
        }
    }

    // MARK: Board

    /// Frame width at which a board's cells are 90 pt (3×3 → 311), capped by
    /// the screen so 4×4 / 5×5 fill the width.
    private var frameMaxWidth: CGFloat {
        let n = CGFloat(replay.size)
        return n * 90 + (n - 1) * Riso.cellGap + 2 * 11 + 2 * 2.5
    }

    private var boardFrame: some View {
        RisoBoardGrid(gridSize: replay.size, gap: Riso.cellGap) { _, _, index in
            cellView(cells.first(where: { $0.idx == index }) ?? MomentCellInput(idx: index, slot: .empty))
        }
        .padding(11)
        // Static cream frame in BOTH appearances (green / type fills read on it).
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.risoOnColor))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.risoInkStatic, lineWidth: 2.5))
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.risoInkStatic).offset(x: 8, y: 8))
        .frame(maxWidth: frameMaxWidth)
        .frame(maxWidth: .infinity)
        // The board (frame AND cells) is always the light palette: undone
        // cells stay cream on the cream frame in both appearances.
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cellView(_ input: MomentCellInput) -> some View {
        let v = momentCellVisual(idx: input.idx, beat: beat, replay: replay, kind: kind)
        let done = input.endCompleted && v.landed
        switch input.slot {
        case .free:
            RisoBoardPlayCell(
                title: "FREE", taskType: .normal, isCompleted: false, isCenter: true,
                isInteractionLocked: true, isLineGreen: v.green, popToken: v.popToken
            )
            .animation(.easeOut(duration: 0.18), value: v)
        case .empty:
            RoundedRectangle(cornerRadius: Riso.cellRadius)
                .strokeBorder(Color.risoInkStatic.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .aspectRatio(1, contentMode: .fit)
        case .task:
            // A cell that lands during the replay starts undone, at zero.
            let resting = input.endCompleted && !done
            RisoBoardPlayCell(
                title: input.title, taskType: input.taskType, isCompleted: done,
                isInteractionLocked: true,
                currentCount: resting ? 0 : input.currentCount,
                maxCount: input.maxCount, countKind: input.countKind,
                compoundDoneCount: resting ? 0 : input.compoundDoneCount,
                compoundChildCount: input.compoundChildCount,
                compoundRequiredCount: input.compoundRequiredCount,
                isLineGreen: v.green, popToken: v.popToken
            )
            .animation(.easeOut(duration: 0.18), value: v)
        }
    }

    // MARK: Streak chip + buttons

    private var streakChip: some View {
        HStack(spacing: 10) {
            Image(systemName: "flame").font(.system(size: 18, weight: .bold))
            Text("\(streak)").font(.risoHead(24, .extraBold))
            Text("\(streakUnitLabel(timeframe)) STREAK").font(.risoHead(11, .bold)).tracking(1.32)
        }
        .foregroundStyle(Color.risoInkStatic)
        .padding(.vertical, 10).padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoGold))
        .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInkStatic, lineWidth: 2))
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoInkStatic).offset(x: 3, y: 3))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(streak) \(streakUnitLabel(timeframe).lowercased()) streak")
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            if kind == .bingo {
                RisoButton(title: "Share this bingo", kind: .gold, systemImage: "square.and.arrow.up",
                           fullWidth: true, large: true, action: onShare)
                RisoButton(title: "Back to board", kind: .neutral, fullWidth: true, large: true, action: onBack)
            } else {
                RisoButton(title: "Share my board", kind: .primary, systemImage: "square.and.arrow.up",
                           fullWidth: true, large: true, action: onShare)
                RisoButton(title: "Start a new board", kind: .neutral, fullWidth: true, large: true, action: onNewBoard)
                // Quiet exit (tap-to-close is gone): plain text, no border / fill.
                Button(action: onBack) {
                    Text("Back to board")
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoPaper.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
