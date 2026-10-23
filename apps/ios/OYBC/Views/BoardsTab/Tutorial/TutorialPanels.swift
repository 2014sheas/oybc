import SwiftUI

// MARK: - Start sheet (handoff: every lesson, from the board)

/// The medium sheet a free square opens before its stage: kicker
/// "LESSON n · m STEPS", the title, one expectation line, Start and "Not now".
struct TutorialStartSheet: View {
    let info: TutorialLessonInfo
    var onStart: () -> Void = {}
    var onNotNow: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lesson \(info.number) · \(info.steps.count) steps").risoKicker()
            Text(info.title)
                .font(.risoHead(26, .extraBold))
                .tracking(-0.52)
                .foregroundStyle(Color.risoInk)
            Text(info.startLine)
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            RisoButton(title: "Start", kind: .primary, fullWidth: true, large: true, action: onStart)
            Button(action: onNotNow) {
                Text("Not now")
                    .font(.risoBody(14, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RisoPaperBackground().ignoresSafeArea())
    }
}

// MARK: - Pro placeholder sheet (handoff 05)

/// The stub sheet a locked Pro square opens: lock tile, "PRO LESSON" kicker,
/// the square's title, a one-line note, a gold "See Pro" and a quiet "Not now".
/// "See Pro" is the paywall entry point and does nothing yet — no entitlement
/// or paywall exists on dev (monetization is parked, see PR #452).
struct TutorialProSheet: View {
    let title: String
    var onSeePro: () -> Void = {}
    var onNotNow: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "lock")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 52, height: 52)
                .risoCard(fill: .risoPaper2)
                .risoHardShadow(Riso.Shadow.small)
            VStack(alignment: .leading, spacing: 4) {
                Text("PRO LESSON").risoKicker()
                Text(title).risoH2()
            }
            Text("This lesson comes with Pro.")
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoMuted)
            Spacer(minLength: 8)
            RisoButton(title: "See Pro", kind: .gold, fullWidth: true, large: true, action: onSeePro)
            Button(action: onNotNow) {
                Text("Not now")
                    .font(.risoHead(14, .bold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RisoPaperBackground().ignoresSafeArea())
    }
}

// MARK: - Lesson complete card (handoff 06)

/// The card that closes a lesson over the last dimmed facsimile: a 44pt green
/// check, "Lesson complete", one subtitle line, "Back to the board" and, when
/// the lesson has one, a plain secondary ("Open Tasks" / "Open Create").
struct TutorialLessonCompleteCard: View {
    let subtitle: String
    var secondary: TutorialExit? = nil
    var onBack: () -> Void = {}
    var onSecondary: (TutorialExit) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(Color.risoPaper)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.risoGreen))
                .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
            Text("Lesson complete")
                .font(.risoHead(20, .extraBold))
                .foregroundStyle(Color.risoInk)
                .padding(.top, 6)
            Text(subtitle)
                .font(.risoBody(13, .semibold))
                .foregroundStyle(Color.risoMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            RisoButton(title: "Back to the board", kind: .primary, fullWidth: true, action: onBack)
                .padding(.top, 10)
            if let secondary {
                Button { onSecondary(secondary) } label: {
                    Text(secondary.label)
                        .font(.risoBody(13, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(EdgeInsets(top: 22, leading: 20, bottom: 20, trailing: 20))
        .frame(maxWidth: 330)
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.card)
        .padding(.horizontal, Riso.gutter)
    }
}

// MARK: - Free row finished card (handoff 07)

/// Under the grid once the three free lessons are done: points to the user's own
/// Boards tab, with the Pro link secondary. "See what Pro adds" is the paywall
/// entry point and does nothing yet (no paywall on dev; monetization is parked).
struct TutorialFreeRowCard: View {
    var onGoToBoards: () -> Void = {}
    var onSeePro: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You know the moves.")
                .font(.risoHead(17, .extraBold))
                .foregroundStyle(Color.risoInk)
            Text("The rest of the board comes with Pro.")
                .font(.risoBody(13, .semibold))
                .foregroundStyle(Color.risoMuted)
            RisoButton(title: "Go to my boards", kind: .primary, fullWidth: true, action: onGoToBoards)
                .padding(.top, 10)
            Button(action: onSeePro) {
                Text("See what Pro adds")
                    .font(.risoHead(13, .bold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .buttonStyle(.plain)
        }
        .padding(Riso.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.button)
    }
}

// MARK: - Middle-row Bingo toast (handoff 06)

/// The gold toast that drops from the top when the middle row completes — lighter
/// than the full-screen Bingo moment, by decision.
struct TutorialBingoToast: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "star.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.risoInkStatic)
            VStack(alignment: .leading, spacing: 1) {
                Text("Bingo")
                    .font(.risoHead(15, .extraBold))
                Text("Middle row · 3 of 9")
                    .font(.risoBody(11, .bold))
            }
            .foregroundStyle(Color.risoInkStatic)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(fill: .risoGold)
        .risoHardShadow(Riso.Shadow.button)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Leave sheet (handoff: exit)

/// "Leave this lesson?" — medium sheet raised by the bar's ✕.
struct TutorialLeaveSheet: View {
    /// 0-based current step (the sheet names it 1-based).
    var step: Int = 0
    var onKeepGoing: () -> Void = {}
    var onLeave: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leave this lesson?")
                .font(.risoHead(26, .extraBold))
                .tracking(-0.52)
                .foregroundStyle(Color.risoInk)
            Text("Your place is saved. Tap the square to pick up at step \(step + 1).")
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            RisoButton(title: "Keep going", kind: .primary, fullWidth: true, large: true, action: onKeepGoing)
            RisoButton(title: "Leave", kind: .neutral, fullWidth: true, large: true, action: onLeave)
                .padding(.top, 4)
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RisoPaperBackground().ignoresSafeArea())
    }
}
