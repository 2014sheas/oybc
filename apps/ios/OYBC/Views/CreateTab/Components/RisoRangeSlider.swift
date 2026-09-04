import SwiftUI

/// Two-handle range slider for a source row's membership range (Board
/// Sources P2 — docs/BOARD_SOURCES.md §Surfaces item 1; handoff frame 2a
/// "Range block"). Net-new Riso primitive — the kit had no slider.
///
/// Geometry (from the handoff, 393pt frames): 60pt tall; 6pt track with a
/// 1.5pt ink keyline (radius 999) at y=14; blue fill between the handles;
/// ticks (1.5×5pt, muted @ 0.5) at each stop only when N > 12; stop
/// labels (10/700 head) under the track — every stop when N ≤ 12, else
/// multiples of 5 plus the two handle values (a multiple within 1 of a
/// handle is dropped); two 22pt knobs (paper-2 fill, 2pt ink keyline,
/// small hard shadow) centered on the track. Every stop is a full-height
/// hit target; tapping moves the NEARER handle (ties go to min).
///
/// Value semantics: `maxValue == nil` is the "all" latch. Dragging the
/// max handle to the top stop re-latches to nil (a numeric N is visually
/// indistinguishable, and the latch is what makes excludes/pool edits
/// follow the live count — docs/BOARD_SOURCES.md §Data model). Min can't
/// pass max; max can't pass min.
struct RisoRangeSlider: View {
    /// The source's live available count (N). Stops are 0...N.
    let available: Int
    let minValue: Int
    /// nil = the "all" latch (renders at stop N).
    let maxValue: Int?
    let onChange: (_ min: Int, _ max: Int?) -> Void

    /// Which handle the in-flight drag grabbed (sticky for the gesture).
    @State private var activeHandle: Handle? = nil

    private enum Handle { case min, max }

    private var effectiveMax: Int { maxValue ?? available }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knob: CGFloat = 22
            // Stop centers span [knob/2, width - knob/2] so the end knobs
            // don't clip the container.
            let usable = max(width - knob, 1)
            let stepWidth = available > 0 ? usable / CGFloat(available) : 0
            let xFor: (Int) -> CGFloat = { stop in
                knob / 2 + CGFloat(stop) * stepWidth
            }
            let trackY: CGFloat = 14 + 3 // track center (6pt tall at y=14)

            ZStack(alignment: .topLeading) {
                // Track
                Capsule()
                    .fill(Color.risoPaper2)
                    .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                    .frame(height: 6)
                    .offset(y: 14)

                // Blue fill between the handles
                Capsule()
                    .fill(Color.risoBlue)
                    .frame(width: max(xFor(effectiveMax) - xFor(minValue), 0), height: 6)
                    .offset(x: xFor(minValue), y: 14)

                // Ticks (only at scale — every stop when N > 12)
                if available > 12 {
                    ForEach(1..<available, id: \.self) { stop in
                        Rectangle()
                            .fill(Color.risoMuted.opacity(0.5))
                            .frame(width: 1.5, height: 5)
                            .position(x: xFor(stop), y: trackY)
                    }
                }

                // Stop labels
                ForEach(labelStops, id: \.self) { stop in
                    Text("\(stop)")
                        .font(Font.risoHead(10, .bold))
                        .foregroundStyle(Color.risoMuted)
                        .position(x: xFor(stop), y: 44)
                }

                // Knobs (min drawn under max so a fully-collapsed range
                // still lets the max handle be grabbed).
                knobView.position(x: xFor(minValue), y: trackY)
                knobView.position(x: xFor(effectiveMax), y: trackY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard available > 0 else { return }
                        let stop = nearestStop(x: value.location.x, xFor: xFor, stepWidth: stepWidth)
                        if activeHandle == nil {
                            // Grab the nearer handle; ties go to min (spec).
                            let dMin = abs(value.startLocation.x - xFor(minValue))
                            let dMax = abs(value.startLocation.x - xFor(effectiveMax))
                            activeHandle = dMin <= dMax ? .min : .max
                        }
                        apply(stop: stop)
                    }
                    .onEnded { _ in activeHandle = nil }
            )
        }
        .frame(height: 60)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Range")
        .accessibilityValue(
            maxValue == nil
                ? "\(minValue) to all \(available)"
                : "\(minValue) to \(effectiveMax) of \(available)"
        )
    }

    private var knobView: some View {
        Circle()
            .fill(Color.risoPaper2)
            .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
            .frame(width: 22, height: 22)
            .risoHardShadow(Riso.Shadow.small)
    }

    /// Label stops per the spec: everything at small N; multiples of 5 +
    /// the two handle values at scale, dropping a multiple within 1 of a
    /// handle (so labels never collide).
    private var labelStops: [Int] {
        guard available > 0 else { return [0] }
        if available <= 12 { return Array(0...available) }
        var stops = Set(stride(from: 0, through: available, by: 5))
        stops.insert(available)
        for handle in [minValue, effectiveMax] {
            stops = stops.filter { $0 == handle || abs($0 - handle) > 1 || !$0.isMultiple(of: 5) }
            stops.insert(handle)
        }
        return stops.sorted()
    }

    private func nearestStop(x: CGFloat, xFor: (Int) -> CGFloat, stepWidth: CGFloat) -> Int {
        guard stepWidth > 0 else { return 0 }
        let raw = Int(((x - 11) / stepWidth).rounded())
        return min(max(raw, 0), available)
    }

    private func apply(stop: Int) {
        switch activeHandle {
        case .min:
            // Min can't pass max.
            let newMin = min(stop, effectiveMax)
            onChange(newMin, maxValue)
        case .max:
            // Max can't pass min; the top stop re-latches "all".
            let newMax = max(stop, minValue)
            onChange(minValue, newMax >= available ? nil : newMax)
        case nil:
            break
        }
    }
}
