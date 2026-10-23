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
    /// Estimated mark height used only to choose above vs below.
    static let markEstimate: CGFloat = 72

    /// Whether the mark goes below the target. Prefers below; goes above only
    /// when below has no room and above does.
    static func placesBelow(target: CGRect, containerHeight: CGFloat, bottomReserve: CGFloat, topReserve: CGFloat) -> Bool {
        let roomBelow = containerHeight - bottomReserve - target.maxY - markGap
        let roomAbove = target.minY - topReserve - markGap
        if roomBelow >= markEstimate { return true }
        return !(roomAbove >= markEstimate)
    }

    /// Whether a mark fits either above or below `target`.
    static func fits(target: CGRect, containerHeight: CGFloat, bottomReserve: CGFloat, topReserve: CGFloat) -> Bool {
        containerHeight - bottomReserve - target.maxY - markGap >= markEstimate
            || target.minY - topReserve - markGap >= markEstimate
    }

    /// The rect the mark is placed against: the union of every ringed control,
    /// unless that union leaves no room above or below, in which case the
    /// first control alone.
    static func placementTarget(lit: [CGRect], containerHeight: CGFloat, bottomReserve: CGFloat, topReserve: CGFloat) -> CGRect {
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

// MARK: - Overlay

/// The scrim + holes + rings + coach mark for the running lesson's current step.
struct TutorialSpotlightOverlay: View {
    @ObservedObject var coach: TutorialCoordinator
    let wired: [TutorialControlID: TutorialWiredInfo]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = 0
    @State private var keyboardHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            if let session = coach.session, session.phase != .complete, !coach.isClosing, !session.state.coachHidden {
                let spots = session.spots
                let lit = spots.compactMap { spot in
                    wired[spot.id].map { (rect: geo[$0.anchor], radius: $0.radius, ringed: spot.ringed) }
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
    private func layer(geo: GeometryProxy, session: TutorialSession, lit: [(rect: CGRect, radius: CGFloat, ringed: Bool)]) -> some View {
        let outset = TutorialCoachGeometry.ringOutset
        let holes = lit.map { item -> (rect: CGRect, radius: CGFloat, ringed: Bool) in
            let rect = item.rect.insetBy(dx: -outset, dy: -outset)
            return (rect, min(item.radius + outset, min(rect.width, rect.height) / 2), item.ringed)
        }
        let ringed = holes.filter(\.ringed).map(\.rect)
        let hasTarget = !ringed.isEmpty
        let target = TutorialCoachGeometry.placementTarget(
            lit: ringed, containerHeight: geo.size.height, bottomReserve: keyboardHeight, topReserve: 0
        )
        let below = hasTarget
            ? TutorialCoachGeometry.placesBelow(target: target, containerHeight: geo.size.height, bottomReserve: keyboardHeight, topReserve: 0)
            : false
        // Several ringed controls (the finale's three squares): no notch.
        let notch: TutorialCoachMark.Notch = hasTarget ? (ringed.count > 1 ? .none : (below ? .up : .down)) : .none
        let notchOffset = hasTarget ? TutorialCoachGeometry.notchOffset(targetMidX: ringed[0].midX, containerWidth: geo.size.width) : 0

        ZStack(alignment: .top) {
            // Scrim: swallows taps outside the holes and pulses the ring.
            TutorialScrimShape(holes: holes.map { (rect: $0.rect, radius: $0.radius) })
                .fill(TutorialScrimShape.color, style: FillStyle(eoFill: true))
                .contentShape(TutorialScrimShape(holes: holes.map { (rect: $0.rect, radius: $0.radius) }), eoFill: true)
                .onTapGesture { pulse += 1 }
                .accessibilityHidden(true)

            ForEach(Array(holes.enumerated()), id: \.offset) { _, hole in
                if hole.ringed { spotlightRing(hole: (hole.rect, hole.radius)) }
            }

            mark(session: session, notch: notch, notchOffset: notchOffset)
                .padding(.horizontal, TutorialCoachGeometry.markInset)
                .padding(.top, hasTarget && below ? target.maxY + TutorialCoachGeometry.markGap : 0)
                .padding(.bottom, hasTarget && !below ? geo.size.height - target.minY + TutorialCoachGeometry.markGap : (hasTarget ? 0 : 24 + keyboardHeight))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hasTarget && below ? .top : .bottom)
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
            resumed: session.resumed,
            showsNext: session.showsNext,
            notch: notch,
            notchOffset: notchOffset,
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
