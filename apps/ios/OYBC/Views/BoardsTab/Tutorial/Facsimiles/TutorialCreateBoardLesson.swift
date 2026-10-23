import SwiftUI

// MARK: - Lesson 2 · Create a board

/// The lesson 2 facsimiles, fed by `TutorialCreateBoardState`: the Create hub,
/// the board wizard's Setup / Tasks / Preview steps and the "Add from a pool or
/// board" sheet. Everything is drawn from the Riso kit and the fixtures in
/// `TutorialCreateBoardFixture` — pure props, never the real wizard, so nothing
/// the person does here reaches their boards, tasks or pools.
///
/// This file holds the entry point, the hub, the wizard chrome (header, stepper,
/// footer bar) and the Setup step; the Tasks step, the source sheet and the
/// Preview step live in `TutorialCreateBoardLesson+Tasks.swift`.
struct TutorialCreateBoardLesson: View {
    let state: TutorialCreateBoardState
    let step: Int
    let perform: (TutorialEvent) -> Void
    /// The clock the Setup step's window note reads (injectable so snapshots
    /// never render the live date).
    var now: Date = Date()

    var body: some View {
        ZStack(alignment: .top) {
            switch state.screen {
            case .hub:
                TutorialCreateHubFacsimile(perform: perform)
            case .setup:
                TutorialCreateBoardSetupFacsimile(state: state, perform: perform, now: now)
            case .tasks:
                TutorialCreateBoardTasksFacsimile(state: state, step: step, perform: perform)
            case .preview:
                TutorialCreateBoardPreviewFacsimile(state: state, perform: perform)
            }
            if state.screen == .tasks, state.sourceSheetOpen {
                TutorialBehindSheetDim()
                TutorialSourceSheetFacsimile(state: state, perform: perform)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Create hub

/// The Create tab: "Build something" / "Create", the NEW BOARD section with the
/// one-off card (the one wired control) and the recurring card (a lock, a Pro
/// lesson), over the inert tab bar. Metrics follow the shipped hub
/// (`CreateHubView` / `CreateHubBoardCTAView`).
struct TutorialCreateHubFacsimile: View {
    let perform: (TutorialEvent) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            RisoPaperBackground()
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Build something").risoKicker()
                    Text("Create").risoH1().padding(.top, 4)
                }
                .tutorialInert()

                VStack(alignment: .leading, spacing: 10) {
                    Text("New board").risoSectionLabel().tutorialInert()

                    Button { perform(.oneOffTapped) } label: {
                        TutorialHubCard(title: "Start a one-off board", systemImage: "square.grid.3x3.fill", fill: .risoRed) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.risoPaper.opacity(0.7))
                        }
                    }
                    .buttonStyle(RisoButtonStyle())
                    .tutorialWired(.oneOffCard)
                    .accessibilityLabel("Start a one-off board")

                    TutorialHubCard(title: "Start a recurring board", systemImage: "repeat", fill: .risoBlue) {
                        TutorialLockChip(size: 24)
                    }
                    .risoHardShadow(Riso.Shadow.button)
                    .tutorialLocked()
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Riso.gutter)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            TutorialTabBarFacsimile(active: .create)
                .padding(.bottom, 30)
        }
    }
}

/// One Create-hub board card (gold icon tile, title, a trailing glyph), drawn
/// like `CreateHubBoardCTAView` but without the button: the one-off card wraps
/// it in a `Button`, the locked recurring card leaves it flat.
struct TutorialHubCard<Trailing: View>: View {
    let title: String
    let systemImage: String
    let fill: Color
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.risoInkStatic)
                .frame(width: 44, height: 44)
                .risoCard(fill: Color.risoGold)

            Text(title)
                .font(.risoHead(16, .extraBold))
                .foregroundStyle(Color.risoPaper)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(Riso.cardPadding)
        .risoCard(fill: fill)
    }
}

// MARK: - Wizard chrome

/// The wizard's frame: header (kicker + H2 title + ✕), the three-step stepper
/// and the footer bar around the step's content. Header and stepper are inert;
/// the footer's buttons are placed by the step.
struct TutorialWizardFrame<Content: View, Footer: View>: View {
    let kicker: String
    let title: String
    /// Active step, 1...3.
    let activeStep: Int
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        ZStack(alignment: .top) {
            RisoPaperBackground()
            VStack(spacing: 0) {
                header
                RisoBoardWizardStepperView(currentStep: activeStep)
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 8)
                    .tutorialInert()
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footerBar
            }
        }
    }

    /// Kicker + H2 on the left, the 46pt ✕ card on the right (inert).
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(kicker).risoKicker()
                Text(title).risoH2()
            }
            Spacer()
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 46, height: 46)
                .risoCard(fill: .risoPaper2)
                .risoHardShadow(Riso.Shadow.small)
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 16)
        .padding(.bottom, 2)
        .tutorialInert()
    }

    /// Top ink rule 2, paper background, 14/20/44 padding.
    private var footerBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.risoInk).frame(height: Riso.Keyline.container)
            HStack(spacing: 10) { footer() }
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 14)
                .padding(.bottom, 44)
                .background(Color.risoPaper)
        }
    }
}

// MARK: - Setup step

/// Wizard step 1: the name (fixed, inert), the timeframe row with Weekly the one
/// live segment, the window note, the size cards with 3×3 the one live card, the
/// task-count caption and the Free / Choose / None row (inert). Footer: Cancel
/// (inert) and Next, dimmed until a size is picked.
struct TutorialCreateBoardSetupFacsimile: View {
    let state: TutorialCreateBoardState
    let perform: (TutorialEvent) -> Void
    let now: Date

    var body: some View {
        TutorialWizardFrame(kicker: "New one-off board", title: "Setup", activeStep: 1) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    nameSection
                    timeframeSection
                    sizeSection
                    centerSection
                }
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        } footer: {
            RisoButton(title: "Cancel", kind: .neutral) {}
                .tutorialInert()
                .frame(maxWidth: .infinity)
            RisoButton(title: "Next ›", kind: .primary) { perform(.setupNextTapped) }
                .opacity(state.sizePicked ? 1 : 0.45)
                .disabled(!state.sizePicked)
                .tutorialWired(.setupNext)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                Text("Board name").risoSectionLabel()
                Text("*").font(.risoBody(11, .bold)).foregroundStyle(Color.risoRed)
            }
            Text(TutorialCreateBoardFixture.boardName)
                .font(.risoHead(16, .bold))
                .foregroundStyle(Color.risoInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.risoPaper2)
                .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
        }
        .tutorialInert()
    }

    private var timeframeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeframe").risoSectionLabel().tutorialInert()
            HStack(spacing: 6) {
                TutorialLockedSegment(label: "Daily")
                TutorialSegment(label: "Weekly", isOn: state.timeframePicked) { perform(.weeklyTapped) }
                    .tutorialWired(.timeframeWeekly)
                TutorialLockedSegment(label: "Monthly")
                TutorialLockedSegment(label: "Yearly")
                TutorialLockedSegment(label: "Custom")
            }
            windowNote.tutorialInert()
        }
    }

    /// The dashed window chip: calendar glyph + this week's range, as the shipped
    /// form's note ("Week of Oct 19 – 25, 2026"). Weeks start on Monday here, so
    /// the chip never depends on the person's own setting.
    private var windowNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 12))
                .foregroundStyle(Color.risoMuted)
            Text(windowLabel)
                .font(.risoBody(12, .semibold))
                .foregroundStyle(Color.risoMuted)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [6, 4]))
                .foregroundStyle(Color.risoInk)
        )
    }

    private var windowLabel: String {
        let start = computeTimeframeBoundaries(timeframe: .weekly, referenceDate: now, weekStartDay: "monday")?.start ?? now
        return formatWindowLabel(timeframe: .weekly, startDate: start)
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Board size").risoSectionLabel().tutorialInert()
            HStack(spacing: 8) {
                RisoBoardSizeCard(n: 3, isSelected: state.sizePicked) { perform(.size3Tapped) }
                    .tutorialWired(.sizeCard3)
                TutorialLockedSizeCard(n: 4)
                TutorialLockedSizeCard(n: 5)
            }
            Text("\(TutorialCreateBoardFixture.required) tasks")
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted)
                .tutorialInert()
        }
    }

    private var centerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Center square").risoSectionLabel()
            HStack(spacing: 6) {
                TutorialSegment(label: "Free", isOn: true)
                TutorialSegment(label: "Choose")
                TutorialSegment(label: "None")
            }
        }
        .tutorialInert()
    }
}

/// A board-size card the tutorial does not offer: paper fill, keyline at 40% ink,
/// muted label, an 18pt lock chip top-right. Inert.
struct TutorialLockedSizeCard: View {
    let n: Int

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                ForEach(0..<n, id: \.self) { _ in
                    HStack(spacing: 2) {
                        ForEach(0..<n, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.risoPaper)
                                .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(Color.risoInk, lineWidth: 1))
                                .frame(width: 7, height: 7)
                        }
                    }
                }
            }
            Text("\(n)×\(n)")
                .font(.risoHead(14, .extraBold))
                .foregroundStyle(Color.risoMuted)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper))
        .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk.opacity(0.4), lineWidth: Riso.Keyline.container))
        .overlay(alignment: .topTrailing) {
            TutorialLockChip(size: 18).padding(6)
        }
        .tutorialInert()
    }
}
