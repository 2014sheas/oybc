import SwiftUI
import UIKit

// MARK: - Anchor tagging

/// A tagged control's frame (as an anchor) and the corner radius its ring follows.
struct TutorialAnchorInfo {
    let anchor: Anchor<CGRect>
    let radius: CGFloat
}

/// Collects the `.tutorialAnchor` tags beneath a view.
struct TutorialAnchorKey: PreferenceKey {
    static var defaultValue: [TutorialAnchorID: TutorialAnchorInfo] = [:]
    static func reduce(value: inout [TutorialAnchorID: TutorialAnchorInfo], nextValue: () -> [TutorialAnchorID: TutorialAnchorInfo]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// Tags a real control so a walkthrough step can light it. Inert (just a
    /// preference nobody reads) when no lesson runs.
    /// - Parameters:
    ///   - id: Which anchor this control is.
    ///   - radius: The control's corner radius; the spotlight ring follows it.
    func tutorialAnchor(_ id: TutorialAnchorID, radius: CGFloat = Riso.cardRadius) -> some View {
        anchorPreference(key: TutorialAnchorKey.self, value: .bounds) { [id: TutorialAnchorInfo(anchor: $0, radius: radius)] }
    }

    /// Adds the walkthrough scrim / spotlight / coach mark above this view.
    /// Apply at EACH presentation root a lesson uses — a sheet is a separate
    /// hierarchy, so an overlay on the lesson's root does not cover it.
    /// - Parameter isRoot: true for the lesson stage's root content (it also
    ///   shows the fallback mark when no sheet claims the step).
    func tutorialCoachLayer(isRoot: Bool = false) -> some View {
        modifier(TutorialCoachLayer(isRoot: isRoot))
    }
}

// MARK: - Placement

/// Pure geometry for the coach mark and the spotlight.
enum TutorialCoachGeometry {
    /// Gap between the lit control and the coach mark.
    static let markGap: CGFloat = 18
    /// How far outside the control the gold ring sits.
    static let ringOutset: CGFloat = 6
    /// Ring stroke width.
    static let ringWidth: CGFloat = 3
    /// Horizontal inset of the coach mark.
    static let markInset: CGFloat = 20
    /// Estimated mark height used only to choose above vs below.
    static let markEstimate: CGFloat = 132

    /// Whether the mark goes below the target. Prefers below; goes above only
    /// when below has no room and above does.
    static func placesBelow(
        target: CGRect, containerHeight: CGFloat, bottomReserve: CGFloat, topReserve: CGFloat,
        prefersAbove: Bool = false
    ) -> Bool {
        let roomBelow = containerHeight - bottomReserve - target.maxY - markGap
        let roomAbove = target.minY - topReserve - markGap
        if prefersAbove && roomAbove >= markEstimate { return false }
        if roomBelow >= markEstimate { return true }
        return !(roomAbove >= markEstimate)
    }

    /// Whether a mark fits either above or below `target`.
    static func fits(target: CGRect, containerHeight: CGFloat, bottomReserve: CGFloat, topReserve: CGFloat) -> Bool {
        containerHeight - bottomReserve - target.maxY - markGap >= markEstimate
            || target.minY - topReserve - markGap >= markEstimate
    }

    /// The rect the mark is placed against: the union of every lit control,
    /// unless that union leaves no room above or below (a step that lights a
    /// control at the top and one at the bottom of the screen — Timeframe and
    /// Next, the pool rows and Done), in which case the first control alone.
    static func placementTarget(
        lit: [CGRect], containerHeight: CGFloat, bottomReserve: CGFloat, topReserve: CGFloat
    ) -> CGRect {
        guard let first = lit.first else { return .zero }
        let union = lit.dropFirst().reduce(first) { $0.union($1) }
        if fits(target: union, containerHeight: containerHeight, bottomReserve: bottomReserve, topReserve: topReserve) {
            return union
        }
        return first
    }

    /// Offset of the notch's centre from the card's leading edge, kept clear of
    /// the card's rounded corners.
    static func notchOffset(targetMidX: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let cardWidth = containerWidth - markInset * 2
        let raw = targetMidX - markInset
        return min(max(raw, 22), cardWidth - 22)
    }
}

// MARK: - Scrim

/// The scrim: the whole area minus rounded holes (even-odd), so lit controls
/// stay fully visible and taps inside a hole reach the real control.
struct TutorialScrimShape: Shape {
    let holes: [(rect: CGRect, radius: CGFloat)]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for hole in holes {
            path.addRoundedRect(in: hole.rect, cornerSize: CGSize(width: hole.radius, height: hole.radius))
        }
        return path
    }
}

extension TutorialScrimShape {
    /// The scrim colour: ink-static at 62%, identical in light and dark.
    static let color = Color(red: 24 / 255, green: 18 / 255, blue: 11 / 255).opacity(0.62)
}

// MARK: - Layer

/// Modifier behind `.tutorialCoachLayer(isRoot:)`.
private struct TutorialCoachLayer: ViewModifier {
    let isRoot: Bool
    @Environment(\.tutorialCoach) private var coach

    func body(content: Content) -> some View {
        if let coach {
            content.overlayPreferenceValue(TutorialAnchorKey.self) { anchors in
                TutorialCoachOverlay(coach: coach, anchors: anchors, isRoot: isRoot)
            }
        } else {
            content
        }
    }
}

/// The scrim + spotlight + coach mark for the running lesson's current step.
struct TutorialCoachOverlay: View {
    @ObservedObject var coach: TutorialCoordinator
    let anchors: [TutorialAnchorID: TutorialAnchorInfo]
    let isRoot: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = 0
    @State private var keyboardHeight: CGFloat = 0
    /// This layer raised the "Leave this lesson?" sheet (presented from here, not
    /// from the stage, so it works above a sheet the lesson opened).
    @State private var confirmingLeave = false

    var body: some View {
        GeometryReader { geo in
            if let session = coach.session, session.phase != .complete, !coach.isClosing, !session.momentOpen, let step = session.currentStep {
                let litIds = session.litAnchors
                let lit = litIds.compactMap { id in
                    anchors[id].map { (rect: geo[$0.anchor], radius: $0.radius) }
                }
                let hasTarget = !lit.isEmpty
                content(geo: geo, session: session, step: step, lit: lit, hasTarget: hasTarget)
                    .transaction { if reduceMotion { $0.animation = nil } }
            }
        }
        .ignoresSafeArea()
        .tutorialLeaveSheet(coach: coach, isPresented: $confirmingLeave)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            keyboardHeight = frame.minY >= UIScreen.main.bounds.height ? 0 : frame.height
        }
        .onAppear { if !isRoot { coach.sheetLayerAppeared() } }
        .onDisappear { if !isRoot { coach.sheetLayerDisappeared() } }
    }

    @ViewBuilder
    private func content(
        geo: GeometryProxy, session: TutorialSession, step: TutorialStep,
        lit: [(rect: CGRect, radius: CGFloat)], hasTarget: Bool
    ) -> some View {
        if session.awaitingNext {
            doneLayer(session: session, step: step)
        } else if hasTarget {
            targetLayer(geo: geo, session: session, step: step, lit: lit)
        } else if !isRoot {
            // A sheet is up with nothing lit on it: the step's own control went
            // away (the Undo strip after Undo), or the sheet was opened from a
            // lit square (the finale's Read). Keep the mark — and its exit /
            // Next — on the sheet, where the root layer defers to it.
            mark(session: session, step: step, notch: .none, notchOffset: 0)
                .padding(.horizontal, TutorialCoachGeometry.markInset)
                .padding(.bottom, 24 + keyboardHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        } else if isRoot {
            let sheetOwnsStep = step.onSheet && coach.sheetLayerCount > 0
            if step.onSheet {
                // Dims what is behind the sheet (or the whole screen if the
                // sheet went away).
                Rectangle().fill(TutorialScrimShape.color).ignoresSafeArea().allowsHitTesting(false)
            }
            if !sheetOwnsStep {
                // The lit control is not on screen: keep the exit reachable.
                mark(session: session, step: step, notch: .none, notchOffset: 0)
                    .padding(.horizontal, TutorialCoachGeometry.markInset)
                    .padding(.bottom, 24 + keyboardHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    /// The hold after an action: every hole closed, the step's done line with
    /// Next at the bottom. Drawn by the layer whose presentation the NEXT step
    /// lights (its sheet is already up), so the card is never under a sheet.
    @ViewBuilder
    private func doneLayer(session: TutorialSession, step: TutorialStep) -> some View {
        let nextOnSheet = session.screenStep?.onSheet ?? false
        let sheetOwns = nextOnSheet && coach.sheetLayerCount > 0
        let drawsMark = isRoot ? !sheetOwns : nextOnSheet
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(TutorialScrimShape.color)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
            if drawsMark {
                mark(session: session, step: step, notch: .none, notchOffset: 0)
                    .padding(.horizontal, TutorialCoachGeometry.markInset)
                    .padding(.bottom, 24 + keyboardHeight)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.awaitingNext)
    }

    private func targetLayer(
        geo: GeometryProxy, session: TutorialSession, step: TutorialStep,
        lit: [(rect: CGRect, radius: CGFloat)]
    ) -> some View {
        let outset = TutorialCoachGeometry.ringOutset
        let holes = lit.map { item -> (rect: CGRect, radius: CGFloat) in
            let rect = item.rect.insetBy(dx: -outset, dy: -outset)
            return (rect, min(item.radius + outset, min(rect.width, rect.height) / 2))
        }
        // The mark clears the WHOLE lit area when it can, else its first control.
        let target = TutorialCoachGeometry.placementTarget(
            lit: lit.map(\.rect), containerHeight: geo.size.height,
            bottomReserve: keyboardHeight, topReserve: geo.safeAreaInsets.top
        )
        let below = TutorialCoachGeometry.placesBelow(
            target: target, containerHeight: geo.size.height,
            bottomReserve: keyboardHeight, topReserve: geo.safeAreaInsets.top,
            prefersAbove: step.prefersAbove
        )
        let notchOffset = TutorialCoachGeometry.notchOffset(targetMidX: lit[0].rect.midX, containerWidth: geo.size.width)
        return ZStack(alignment: .top) {
            // Scrim: swallows taps outside the holes and pulses the ring.
            TutorialScrimShape(holes: holes)
                .fill(TutorialScrimShape.color, style: FillStyle(eoFill: true))
                .contentShape(TutorialScrimShape(holes: holes), eoFill: true)
                .onTapGesture { pulse += 1 }

            ForEach(Array(holes.enumerated()), id: \.offset) { _, hole in
                spotlightRing(hole: hole)
            }

            mark(session: session, step: step, notch: below ? .up : .down, notchOffset: notchOffset)
                .padding(.horizontal, TutorialCoachGeometry.markInset)
                .padding(.top, below ? target.maxY + TutorialCoachGeometry.markGap : 0)
                .padding(.bottom, below ? 0 : geo.size.height - target.minY + TutorialCoachGeometry.markGap)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: below ? .top : .bottom)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.step)
    }

    /// The gold ring around a lit control (3pt, 6pt out) plus the single pulse
    /// ring that fades when the user taps outside; Reduce Motion brightens the
    /// ring instead.
    private func spotlightRing(hole: (rect: CGRect, radius: CGFloat)) -> some View {
        let ring = hole.rect.insetBy(dx: -TutorialCoachGeometry.ringWidth / 2, dy: -TutorialCoachGeometry.ringWidth / 2)
        let radius = hole.radius + TutorialCoachGeometry.ringWidth / 2
        return ZStack {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color.risoGold, lineWidth: TutorialCoachGeometry.ringWidth)
                .frame(width: ring.width, height: ring.height)
                .brightness(reduceMotion && pulse % 2 == 1 ? 0.25 : 0)
            if !reduceMotion {
                TutorialRingPulse(rect: ring, radius: radius, trigger: pulse)
            }
        }
        .position(x: ring.midX, y: ring.midY)
        .allowsHitTesting(false)
    }

    private func mark(session: TutorialSession, step: TutorialStep, notch: TutorialCoachMark.Notch, notchOffset: CGFloat) -> some View {
        TutorialCoachMark(
            lessonTitle: TutorialCatalog.info(for: session.lesson).title,
            text: coach.currentText ?? step.text,
            step: session.step,
            stepCount: session.steps.count,
            resumed: session.resumed,
            showsNext: coach.showsNext,
            done: session.awaitingNext,
            notch: notch,
            notchOffset: notchOffset,
            onExit: { confirmingLeave = true; coach.requestLeave() },
            onNext: { coach.next() }
        )
    }
}

/// The second ring that expands and fades once per outside tap.
private struct TutorialRingPulse: View {
    let rect: CGRect
    let radius: CGFloat
    let trigger: Int
    @State private var expanded = false
    @State private var visible = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius + (expanded ? 6 : 0))
            .strokeBorder(Color.risoGold, lineWidth: TutorialCoachGeometry.ringWidth)
            .frame(width: rect.width + (expanded ? 12 : 0), height: rect.height + (expanded ? 12 : 0))
            .opacity(visible ? (expanded ? 0 : 0.9) : 0)
            .onChange(of: trigger) { _, _ in
                expanded = false
                visible = true
                withAnimation(.easeOut(duration: 0.35)) { expanded = true }
            }
    }
}

// MARK: - Leave sheet + exit guard

private struct TutorialLeaveSheetModifier: ViewModifier {
    @ObservedObject var coach: TutorialCoordinator
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            if coach.session?.phase == .confirmingLeave { coach.keepGoing() }
        }) {
            TutorialLeaveSheet(
                onKeepGoing: { isPresented = false },
                onLeave: { isPresented = false; coach.leave() }
            )
            .presentationDetents([.medium])
        }
    }
}

extension View {
    /// Presents "Leave this lesson?" from this view.
    fileprivate func tutorialLeaveSheet(coach: TutorialCoordinator, isPresented: Binding<Bool>) -> some View {
        modifier(TutorialLeaveSheetModifier(coach: coach, isPresented: isPresented))
    }

    /// A small exit control for a presentation the lesson did not light but the
    /// user can still reach mid-lesson (the Edit swap picker, a task detail, the
    /// share sheet, the wizard's cancel dialog) — it must not need the scrim,
    /// which would block the sheet. Inert outside a lesson.
    func tutorialExitGuard() -> some View {
        modifier(TutorialExitGuard())
    }
}

private struct TutorialExitGuard: ViewModifier {
    @Environment(\.tutorialCoach) private var coach

    func body(content: Content) -> some View {
        if let coach {
            content.overlay(alignment: .bottomTrailing) { TutorialExitChip(coach: coach) }
        } else {
            content
        }
    }
}

private struct TutorialExitChip: View {
    @ObservedObject var coach: TutorialCoordinator
    @State private var confirming = false

    var body: some View {
        // Stays mounted through `.confirmingLeave`: the tap flips the phase, and
        // the Leave sheet hangs off this very view, so an `if phase == .running`
        // here would unmount the sheet before it could present.
        if let session = coach.session, session.phase != .complete, !coach.isClosing {
            Button {
                confirming = true
                coach.requestLeave()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(width: 36, height: 36)
                    .risoCard(fill: .risoPaper2)
            }
            .buttonStyle(.plain)
            .disabled(session.phase != .running)
            .padding(.trailing, 14)
            .padding(.bottom, 24)
            .accessibilityLabel("Exit lesson")
            .tutorialLeaveSheet(coach: coach, isPresented: $confirming)
        }
    }
}
