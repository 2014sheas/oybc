import SwiftUI

/// Bottom sheet shown when a tutorial square is tapped (handoff §0a,
/// screenshot 19). Explains the move, lists a 3-step how-to, then a primary
/// "Try it" button that deep-links into the real flow (and marks it learned)
/// plus a quiet "Mark as learned". Props-only / snapshot-testable.
struct TutorialLessonSheet: View {
    let lesson: TutorialLesson
    let isLearned: Bool
    let onTry: (TutorialLesson) -> Void
    let onMark: (TutorialLesson) -> Void

    var body: some View {
        ZStack {
            RisoPaperBackground().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Header: icon tile + "Move N of 8" + title
                    HStack(spacing: 12) {
                        Image(systemName: isLearned ? "checkmark" : lesson.systemImage)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(isLearned ? Color.risoPaper : Color.risoInk)
                            .frame(width: 52, height: 52)
                            .risoCard(fill: isLearned ? .risoGreen : .risoPaper2)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Move \(tutorialMoveNumber(for: lesson)) of \(TutorialProgressStore.totalLessons)")
                                .risoKicker()
                            Text(lesson.title)
                                .font(.risoHead(22, .extraBold))
                                .foregroundStyle(Color.risoInk)
                        }
                        Spacer(minLength: 0)
                    }

                    Text(lesson.blurb)
                        .font(.risoBody(14, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    // 3-step numbered how-to (keyline list)
                    VStack(spacing: 0) {
                        ForEach(Array(lesson.steps.enumerated()), id: \.offset) { idx, step in
                            if idx > 0 {
                                Divider().background(Color.risoInk.opacity(0.12))
                            }
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(idx + 1)")
                                    .font(.risoHead(12, .extraBold))
                                    .foregroundStyle(Color.risoInk)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                                Text(step)
                                    .font(.risoBody(14, .semibold))
                                    .foregroundStyle(Color.risoInk)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 12)
                    .risoCard(fill: .risoPaper2)

                    if isLearned {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                            Text("You've done this one")
                                .font(.risoBody(13, .bold))
                        }
                        .foregroundStyle(Color.risoGreen)
                    }

                    RisoButton(title: lesson.cta, kind: .primary, systemImage: "arrow.right",
                               fullWidth: true, large: true) {
                        onTry(lesson)
                    }
                    .padding(.top, 2)

                    if !isLearned {
                        Button { onMark(lesson) } label: {
                            Text("Mark as learned")
                                .font(.risoBody(14, .semibold))
                                .foregroundStyle(Color.risoMuted)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
    }
}

#if DEBUG
#Preview("Lesson sheet — undone") {
    TutorialLessonSheet(lesson: tutorialLessons[4], isLearned: false, onTry: { _ in }, onMark: { _ in })
}
#Preview("Lesson sheet — learned") {
    TutorialLessonSheet(lesson: tutorialLessons[0], isLearned: true, onTry: { _ in }, onMark: { _ in })
}
#endif
