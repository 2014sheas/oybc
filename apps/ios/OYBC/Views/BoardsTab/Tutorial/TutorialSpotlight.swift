import SwiftUI
import UIKit

// MARK: - Wiring a control

/// A wired control's frame (as an anchor) and the corner radius its ring follows.
struct TutorialWiredInfo {
    let anchor: Anchor<CGRect>
    let radius: CGFloat
}

/// Collects the `.tutorialWired` tags beneath a facsimile.
struct TutorialWiredKey: PreferenceKey {
    static var defaultValue: [TutorialControlID: TutorialWiredInfo] = [:]
    static func reduce(value: inout [TutorialControlID: TutorialWiredInfo], nextValue: () -> [TutorialControlID: TutorialWiredInfo]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// Tags a facsimile control the lesson can wire. The stage lights it only
    /// when the current step names it; otherwise it sits under the scrim like
    /// everything else.
    /// - Parameters:
    ///   - id: Which control this is.
    ///   - radius: The control's corner radius; the hole and ring follow it.
    func tutorialWired(_ id: TutorialControlID, radius: CGFloat = Riso.cardRadius) -> some View {
        anchorPreference(key: TutorialWiredKey.self, value: .bounds) { [id: TutorialWiredInfo(anchor: $0, radius: radius)] }
    }

    /// Marks a facsimile part the lesson never offers: drawn, never tapped, and
    /// hidden from VoiceOver (focus stays on the bar, the coach text and the
    /// wired control).
    func tutorialInert() -> some View {
        allowsHitTesting(false).accessibilityHidden(true)
    }

    /// Dims a facsimile part the lesson does not offer (a locked option: muted
    /// text, keyline at 40% ink) and makes it inert.
    func tutorialLocked() -> some View {
        opacity(0.5).tutorialInert()
    }

    /// Adds the lesson's scrim, holes, gold rings and coach mark above this
    /// facsimile, from the controls it tagged with `.tutorialWired`.
    func tutorialSpotlight(coach: TutorialCoordinator) -> some View {
        overlayPreferenceValue(TutorialWiredKey.self) { wired in
            TutorialSpotlightOverlay(coach: coach, wired: wired)
        }
    }
}

// MARK: - Geometry

/// Pure geometry for the coach mark and the spotlight.
enum TutorialCoachGeometry {
    /// Gap between the lit control and the coach mark.
    static let markGap: CGFloat = 18
    /// How far outside the control the hole (and the surface pad) extends.
    static let ringOutset: CGFloat = 6
    /// Ring stroke width.
    static let ringWidth: CGFloat = 3
    /// Horizontal inset of the coach mark.
    static let markInset: CGFloat = 20
    /// Horizontal inset of a tell.
    static let tellInset: CGFloat = 28

    /// Room left under the mark while a shipped moment plays, so it sits above
    /// the moment's buttons (`RisoMomentOverlay.buttonsBlockHeight`) with the
    /// usual gap.
    static func momentButtonsReserve(session: TutorialSession) -> CGFloat {
        let greenlog: Bool = {
            if case .completeBoard(let s) = session.state { return s.moment == .greenlog }
            return false
        }()
        return RisoMomentOverlay.buttonsBlockHeight(kind: greenlog ? .greenlog : .bingo) + markGap
    }
    /// The smallest mark (one instruction line, no note); the floor for the
    /// measured height the overlay feeds in.
    static let markEstimate: CGFloat = 72

    /// Whether the mark goes below the target. Prefers below; goes above only
    /// when below has no room and above does.
    /// - Parameter markHeight: The mark's rendered height (the estimate until measured).
    static func placesBelow(target: CGRect, containerHeight: CGFloat, bottomReserve: CGFloat, topReserve: CGFloat, markHeight: CGFloat = markEstimate) -> Bool {
        let roomBelow = containerHeight - bottomReserve - target.maxY - markGap
        let roomAbove = target.minY - topReserve - markGap
        if roomBelow >= markHeight { return true }
        return !(roomAbove >= markHeight)
    }

    /// Whether a mark fits either above or below `target`.
    static func fits(target: CGRect, containerHeight: CGFloat, bottomReserve: CGFloat, topReserve: CGFloat, markHeight: CGFloat = markEstimate) -> Bool {
        containerHeight - bottomReserve - target.maxY - markGap >= markHeight
            || target.minY - topReserve - markGap >= markHeight
    }

    /// The rect the mark is placed against: the union of every ringed control,
    /// unless that union leaves no room above or below, in which case the
    /// first control alone.
    static func placementTarget(lit: [CGRect], containerHeight: CGFloat, bottomReserve: CGFloat, topReserve: CGFloat, markHeight: CGFloat = markEstimate) -> CGRect {
        guard let first = lit.first else { return .zero }
        let union = lit.dropFirst().reduce(first) { $0.union($1) }
        if fits(target: union, containerHeight: containerHeight, bottomReserve: bottomReserve, topReserve: topReserve, markHeight: markHeight) {
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
/// stay fully visible and taps inside a hole reach the control.
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

/// Just the holes (no outer rect): the mask that cuts them out of the scrim.
struct TutorialHolesShape: Shape {
    let holes: [(rect: CGRect, radius: CGFloat)]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for hole in holes {
            path.addRoundedRect(in: hole.rect, cornerSize: CGSize(width: hole.radius, height: hole.radius))
        }
        return path
    }
}

// MARK: - Overlay

/// The scrim + holes + rings + coach mark for the running lesson's current step.
struct TutorialSpotlightOverlay: View {
    @ObservedObject var coach: TutorialCoordinator
    let wired: [TutorialControlID: TutorialWiredInfo]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = 0
    @State private var keyboardHeight: CGFloat = 0
    /// The coach mark's rendered height, so above-vs-below is decided on the
    /// real card (a note line or a long instruction makes it taller than the
    /// one-line estimate).
    @State private var measuredMark: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            if let session = coach.session, session.phase != .complete, !coach.isClosing {
                let spots = session.spots
                let lit = spots.compactMap { spot in
                    wired[spot.id].map { (rect: geo[$0.anchor], radius: $0.radius, ringed: spot.ringed, primary: spot.primary) }
                }
                layer(geo: geo, session: session, lit: lit)
                    .transaction { if reduceMotion { $0.animation = nil } }
            }
        }
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            keyboardHeight = frame.minY >= UIScreen.main.bounds.height ? 0 : frame.height
        }
    }

    @ViewBuilder
    private func layer(geo: GeometryProxy, session: TutorialSession, lit: [(rect: CGRect, radius: CGFloat, ringed: Bool, primary: Bool)]) -> some View {
        let outset = TutorialCoachGeometry.ringOutset
        let holes = lit.map { item -> (rect: CGRect, radius: CGFloat, ringed: Bool, primary: Bool) in
            let rect = item.rect.insetBy(dx: -outset, dy: -outset)
            return (rect, min(item.radius + outset, min(rect.width, rect.height) / 2), item.ringed, item.primary)
        }
        let ringed = holes.filter(\.ringed).map(\.rect)
        let primaries = holes.filter { $0.ringed && $0.primary }.map(\.rect)
        let readOnly = holes.filter { $0.ringed && !$0.primary }.map(\.rect)
        // A lit read-only group (lesson 2's "8 tasks" caption and centre row
        // beside the wired Next): the mark clears the whole group and its notch
        // points at the first lit caption. One ringed control: the notch points
        // at it. Several primaries (the finale's squares): no notch.
        let notchRects = readOnly.isEmpty ? (primaries.count == 1 ? primaries : []) : [readOnly[0]]
        let hasTarget = !ringed.isEmpty
        let markHeight = max(measuredMark, TutorialCoachGeometry.markEstimate)
        let target = TutorialCoachGeometry.placementTarget(
            lit: readOnly.isEmpty && primaries.count == 1 ? primaries : ringed,
            containerHeight: geo.size.height, bottomReserve: keyboardHeight, topReserve: 0, markHeight: markHeight
        )
        let below = hasTarget
            ? TutorialCoachGeometry.placesBelow(target: target, containerHeight: geo.size.height, bottomReserve: keyboardHeight, topReserve: 0, markHeight: markHeight)
            : false
        let notch: TutorialCoachMark.Notch = notchRects.count == 1 ? (below ? .up : .down) : .none
        let notchOffset = notchRects.count == 1 ? TutorialCoachGeometry.notchOffset(targetMidX: notchRects[0].midX, containerWidth: geo.size.width) : 0
        let isTell = session.title != nil
        // A shipped moment plays whole: no scrim, no rings; the mark sits above
        // its buttons.
        let scrimHidden = session.state.scrimHidden
        let bottomPad: CGFloat = scrimHidden
            ? TutorialCoachGeometry.momentButtonsReserve(session: session)
            : (hasTarget && !below ? geo.size.height - target.minY + TutorialCoachGeometry.markGap : (hasTarget ? 0 : 24 + keyboardHeight))

        ZStack(alignment: .top) {
            if !scrimHidden {
                // Scrim: swallows taps outside the holes and pulses the ring. Drawn
                // through a mask (not even-odd) so two holes that touch — the goal
                // and unit fields — leave no hairline between them.
                Rectangle()
                    .fill(TutorialScrimShape.color)
                    .mask {
                        ZStack {
                            Rectangle()
                            TutorialHolesShape(holes: holes.map { (rect: $0.rect, radius: $0.radius) })
                                .fill(Color.black)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .contentShape(TutorialScrimShape(holes: holes.map { (rect: $0.rect, radius: $0.radius) }), eoFill: true)
                    .onTapGesture { pulse += 1 }
                    .accessibilityHidden(true)

                ForEach(Array(holes.enumerated()), id: \.offset) { _, hole in
                    if hole.ringed { spotlightRing(hole: (hole.rect, hole.radius)) }
                }
            }

            if isTell {
                // A tell: inset 28, centred in the room above the keyboard.
                mark(session: session, notch: .none, notchOffset: 0)
                    .padding(.horizontal, TutorialCoachGeometry.tellInset)
                    .padding(.bottom, keyboardHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                mark(session: session, notch: notch, notchOffset: notchOffset)
                    .padding(.horizontal, TutorialCoachGeometry.markInset)
                    .padding(.top, hasTarget && below ? target.maxY + TutorialCoachGeometry.markGap : 0)
                    .padding(.bottom, bottomPad)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hasTarget && below ? .top : .bottom)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.step)
    }

    /// The gold ring around a lit control (3pt, 6pt out) plus the single pulse
    /// ring that fades when the person taps outside; Reduce Motion brightens
    /// the ring instead.
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
        .accessibilityHidden(true)
    }

    private func mark(session: TutorialSession, notch: TutorialCoachMark.Notch, notchOffset: CGFloat) -> some View {
        TutorialCoachMark(
            text: session.text,
            note: session.note,
            title: session.title,
            resumed: session.resumed,
            showsNext: session.showsNext,
            notch: notch,
            notchOffset: notchOffset,
            onNext: { coach.next() }
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TutorialMarkHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(TutorialMarkHeightKey.self) { measuredMark = $0 }
    }
}

/// The coach mark's rendered height (fed back into the above-vs-below choice).
private struct TutorialMarkHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
