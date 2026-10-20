import SwiftUI

/// HelpView — Profile reorg PR1. Pushed from Settings' "Help & getting
/// started" row (kicker "SETTINGS", title "Help").
///
/// Contents: a "Getting started" card showing `{done}/9` with a button that
/// always opens the tutorial board (a finished lesson replays from its square),
/// and a "Contact support" row that is an intentional PLACEHOLDER — present,
/// disabled, caption "Coming soon" (owner decision #4,
/// `.superpowers/sdd/2026-09-30-profile-reorg/owner-decisions.md`) until a
/// real support address exists. Nothing else — no FAQ content.
struct HelpView: View {
    @EnvironmentObject var tutorial: TutorialCoordinator

    /// Opens the Getting Started tutorial board (cross-tab to Boards).
    /// Optional so #Preview / tests can mount this view standalone.
    var onOpenTutorial: (() -> Void)? = nil

    var body: some View {
        ZStack {
            RisoPaperBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    RisoSubPageHeader(title: "Help", kicker: "Settings")
                        .padding(.top, 16)
                        .padding(.bottom, 20)

                    gettingStartedCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)

                    contactSupportCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)
                }
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Getting started card

    private var gettingStartedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Getting started")
                    .font(.risoHead(16, .extraBold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
                Text("\(tutorial.progress.doneCount)/\(TutorialLessonID.total)")
                    .font(.risoHead(14, .bold))
                    .foregroundStyle(Color.risoMuted)
            }

            RisoButton(title: "Open tutorial board", kind: .primary, fullWidth: true) {
                onOpenTutorial?()
            }
        }
        .padding(Riso.cardPadding)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    // MARK: - Contact support (placeholder — owner decision #4)

    private var contactSupportCard: some View {
        RisoProfileRow(
            icon: "envelope",
            label: "Contact support",
            caption: "Coming soon"
        )
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .opacity(0.55)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Contact support, coming soon")
    }
}

#Preview("In progress") {
    NavigationStack {
        HelpView()
            .environmentObject(TutorialCoordinator.preview())
    }
}
