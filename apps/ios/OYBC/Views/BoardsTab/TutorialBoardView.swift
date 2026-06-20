import SwiftUI

/// The Getting Started tutorial board (handoff §0a, screenshot 18) — a 3×3
/// bingo board where each square is a key flow. Tap a square → lesson sheet →
/// "Try it" deep-links into the real flow and checks the square off. Clearing
/// all 8 fires a mascot-free tutorial GREENLOG.
///
/// Pushed onto the Boards stack (back button + tab bar visible). Reads progress
/// from the injected `TutorialProgressStore`; deep-links bubble up via `onTry`.
struct TutorialBoardView: View {
    @EnvironmentObject private var store: TutorialProgressStore

    /// Called when a lesson's "Try it" fires — routes the deep-link (and the
    /// caller also marks the lesson learned). `onBack` pops the board.
    let onTry: (TutorialLesson) -> Void
    let onBack: () -> Void
    /// Fired once when the board reaches 8/8 — the caller shows the completion
    /// overlay (kept in the parent so it survives this view if needed).
    let onComplete: () -> Void

    @State private var activeLesson: TutorialLesson?

    private var done: Int { store.completedCount }
    private var total: Int { TutorialProgressStore.totalLessons }
    private var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    private var statusLine: String {
        if done == 0 { return "Tap any square to begin" }
        if done >= total { return "Board complete!" }
        let left = total - done
        return "\(left) move\(left == 1 ? "" : "s") to go"
    }

    var body: some View {
        ZStack {
            RisoPaperBackground()
            VStack(spacing: 0) {
                header
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("This board *is* the tutorial. Tap a square to learn the move, try it for real, and check it off. Clear all eight for your first GREENLOG.")
                            .font(.risoBody(14, .semibold))
                            .foregroundStyle(Color.risoMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        statBar
                        grid
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(item: $activeLesson) { lesson in
            TutorialLessonSheet(
                lesson: lesson,
                isLearned: store.isLearned(lesson.id),
                onTry: { l in
                    activeLesson = nil
                    // If this is the move that completes the board, celebrate
                    // instead of deep-linking (avoids navigating away — or
                    // stacking a second overlay — under the GREENLOG).
                    if completingMark(l.id) {
                        onComplete()
                    } else {
                        onTry(l)
                    }
                },
                onMark: { l in
                    activeLesson = nil
                    if completingMark(l.id) { onComplete() }
                }
            )
            .presentationDetents([.medium, .large])
        }
    }

    /// Marks the lesson learned; returns true only on the transition that
    /// completes the board (so the celebration fires exactly once).
    private func completingMark(_ lessonID: String) -> Bool {
        let wasComplete = store.isComplete
        store.markLearned(lessonID)
        return !wasComplete && store.isComplete
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 44, height: 44)
                    .risoCard(fill: .risoPaper2)
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: Riso.cardRadius))
            .accessibilityLabel("Back")

            VStack(alignment: .leading, spacing: 3) {
                Text("Getting started").risoKicker()
                Text("Learn by playing").risoH2()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(done)/\(total)")
                .font(.risoHead(13, .extraBold))
                .monospacedDigit()
                .foregroundStyle(Color.risoPaper)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(Capsule().fill(Color.risoBlue))
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Stat bar

    private var statBar: some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.risoPaper2)
                    Capsule().fill(Color.risoGreen)
                        .frame(width: max(0, min(1, fraction)) * geo.size.width)
                }
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            }
            .frame(height: 10)

            Text(statusLine)
                .font(.risoBody(12, .bold))
                .foregroundStyle(Color.risoMuted)
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: - Grid

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 3)
        return LazyVGrid(columns: columns, spacing: 7) {
            ForEach(0..<9, id: \.self) { i in
                if i == 4 {
                    freeCell
                } else if let lesson = tutorialLessonsByPos[i] {
                    lessonCell(lesson)
                }
            }
        }
    }

    private var freeCell: some View {
        VStack(spacing: 6) {
            StarShape()
                .fill(Color.risoGold)
                .frame(width: 22, height: 22)
            Text("FREE")
                .font(.risoBody(10, .bold))
                .tracking(1.0)
                .foregroundStyle(Color.risoPaper)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 104)
        .background(RoundedRectangle(cornerRadius: Riso.cellRadius).fill(Color.risoInk))
    }

    private func lessonCell(_ lesson: TutorialLesson) -> some View {
        let isDone = store.isLearned(lesson.id)
        return Button {
            activeLesson = lesson
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: lesson.systemImage)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.risoInk)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.risoPaper))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                    Spacer(minLength: 0)
                    cornerChip(isDone: isDone)
                }
                Spacer(minLength: 6)
                Text(lesson.title)
                    .font(.risoBody(12, .bold))
                    .foregroundStyle(isDone ? Color.risoPaper : Color.risoInk)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(height: 104, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Riso.cellRadius).fill(isDone ? Color.risoGreen : Color.risoPaper2))
            .overlay(RoundedRectangle(cornerRadius: Riso.cellRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(lesson.title)\(isDone ? ", done" : "")")
    }

    /// Top-right corner chip: blue → (undone) or gold ✓ (done).
    private func cornerChip(isDone: Bool) -> some View {
        Group {
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.risoInkStatic)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.risoGold))
            } else {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.risoPaper)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.risoBlue))
            }
        }
        .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }
}
