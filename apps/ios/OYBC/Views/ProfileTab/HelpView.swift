import SwiftUI

/// HelpView — Profile reorg PR1. Pushed from Settings' "Help & getting
/// started" row (kicker "SETTINGS", title "Help").
///
/// Contents: a "Getting started" card showing `{done}/8` with a button that
/// opens the tutorial board (or, once complete, replays it after a confirm),
/// and a "Contact support" row that is an intentional PLACEHOLDER — present,
/// disabled, caption "Coming soon" (owner decision #4,
/// `.superpowers/sdd/2026-09-30-profile-reorg/owner-decisions.md`) until a
/// real support address exists. Nothing else — no FAQ content.
struct HelpView: View {
    @EnvironmentObject var tutorialStore: TutorialProgressStore

    /// Opens the Getting Started tutorial board (cross-tab to Boards).
    /// Optional so #Preview / tests can mount this view standalone.
    var onOpenTutorial: (() -> Void)? = nil

    @State private var showReplayConfirm = false

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
        .alert("Replay tutorial?", isPresented: $showReplayConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Replay") {
                tutorialStore.reset()
                onOpenTutorial?()
            }
        } message: {
            Text("This resets your Getting Started progress back to 0/8.")
        }
    }

    // MARK: - Getting started card

    private var gettingStartedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Getting started")
                    .font(.risoHead(16, .extraBold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
                Text("\(tutorialStore.completedCount)/\(TutorialProgressStore.totalLessons)")
                    .font(.risoHead(14, .bold))
                    .foregroundStyle(Color.risoMuted)
            }

            RisoButton(
                title: tutorialStore.isComplete ? "Replay tutorial" : "Open tutorial board",
                kind: .primary,
                fullWidth: true
            ) {
                if tutorialStore.isComplete {
                    showReplayConfirm = true
                } else {
                    onOpenTutorial?()
                }
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
            .environmentObject(TutorialProgressStore())
    }
}
