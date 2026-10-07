import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Riso design-system foundation (Phase 0).
/// Renders the full primitive gallery in both "day press" (light) and
/// "night press" (dark) so token/appearance regressions are caught before
/// any screen consumes the kit. iOS-version pinning is at the scheme level
/// (see CLAUDE.md → Snapshot Testing).
final class RisoKitSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    func testKitLight() {
        assertSnapshot(
            of: RisoKitGallery(),
            as: .image(layout: .fixed(width: 393, height: 1340)),
            record: recordMode
        )
    }

    func testKitDark() {
        assertSnapshot(
            of: RisoKitGallery(),
            as: .image(
                layout: .fixed(width: 393, height: 1340),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - RisoSegmented — pill style (P2 Task 3)
    //
    // Additive `style: .pill` on the existing `RisoSegmented` (default
    // `.card`, unchanged — covered by `testKitLight`/`testKitDark` above,
    // which render the gallery's existing card-style segmented sections).
    // Guards the new capsule-container / ink-active-fill rendering path.

    private func pillSegmented() -> some View {
        PillSegmentedPreview()
            .padding(16)
            .background(Color.risoPaper)
            .frame(width: 353, height: 70)
    }

    func testPillSegmentedLight() {
        assertSnapshot(
            of: pillSegmented(),
            as: .image(layout: .fixed(width: 353, height: 70)),
            record: recordMode
        )
    }

    func testPillSegmentedDark() {
        assertSnapshot(
            of: pillSegmented(),
            as: .image(layout: .fixed(width: 353, height: 70), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - §Member rules primitives (B3)
    //
    // The three new row controls, side by side at their real 22/26pt
    // sizes: the dice at all three vary levels (off = muted outline, no
    // pips; a little = blue fill + 2 pips; a lot = 5 pips), the compact
    // stepper pill, and the compact One square / Split up segmented.
    // Guards the pip geometry and the on-blue `risoInkStatic` contrast in
    // BOTH schemes — adaptive ink on a coloured fill is the dark-mode trap.

    private func memberRulePrimitives() -> some View {
        MemberRulePrimitivesPreview()
            .padding(16)
            .background(Color.risoPaper)
            .frame(width: 353, height: 120)
    }

    func testMemberRulePrimitivesLight() {
        assertSnapshot(
            of: memberRulePrimitives(),
            as: .image(layout: .fixed(width: 353, height: 120)),
            record: recordMode
        )
    }

    func testMemberRulePrimitivesDark() {
        assertSnapshot(
            of: memberRulePrimitives(),
            as: .image(
                layout: .fixed(width: 353, height: 120),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - RisoUndoPill (audit T2)
    //
    // Both visual scales side by side. The dashed outline traces each
    // pill's LAYOUT frame, so the baseline pins the 28pt-tall touch target
    // extending past the smaller visual capsule — the hit-area floor this
    // component exists to guarantee — not just the capsule's look.

    private func undoPills() -> some View {
        HStack(spacing: 16) {
            ForEach([RisoUndoPill.Scale.member, .part], id: \.self) { scale in
                RisoUndoPill(scale: scale, accessibilityLabel: "Undo") {}
                    .overlay(
                        Rectangle().strokeBorder(
                            Color.risoBlue,
                            style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                        )
                    )
            }
        }
        .padding(16)
        .frame(width: 200, height: 60)
        .background(Color.risoPaper)
    }

    func testUndoPillLight() {
        assertSnapshot(
            of: undoPills(),
            as: .image(layout: .fixed(width: 200, height: 60)),
            record: recordMode
        )
    }

    func testUndoPillDark() {
        assertSnapshot(
            of: undoPills(),
            as: .image(
                layout: .fixed(width: 200, height: 60),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Counter kinds (PR 3) — the four picker states of handoff §1

    private func kindPickerStates() -> some View {
        KindPickerStatesPreview()
            .padding(16)
            .background(Color.risoPaper)
            .frame(width: 353, height: 230)
    }

    func testKindPickerStatesLight() {
        assertSnapshot(of: kindPickerStates(), as: .image(layout: .fixed(width: 353, height: 230)), record: recordMode)
    }

    func testKindPickerStatesDark() {
        assertSnapshot(
            of: kindPickerStates(),
            as: .image(layout: .fixed(width: 353, height: 230), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - GoalEntry (PR 3 Task 4) — handoff §1 "Amount entry"

    private func goalEntryKinds() -> some View {
        GoalEntryKindsPreview().padding(16).background(Color.risoPaper).frame(width: 353, height: 300)
    }

    func testGoalEntryKindsLight() {
        assertSnapshot(of: goalEntryKinds(), as: .image(layout: .fixed(width: 353, height: 300)), record: recordMode)
    }

    func testGoalEntryKindsDark() {
        assertSnapshot(of: goalEntryKinds(), as: .image(layout: .fixed(width: 353, height: 300), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }
}

/// `@State` wrappers so the compact stepper + compact segmented render
/// with valid `Binding`s in a snapshot context (same pattern as
/// `PillSegmentedPreview` above). The dice is stateless — all three
/// levels render at once.
private struct MemberRulePrimitivesPreview: View {
    @State private var target: Int = 6
    @State private var isSplit: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RisoDiceButton(level: .off) { }
                RisoDiceButton(level: .little) { }
                RisoDiceButton(level: .lot) { }
                RisoInlineStepperView(value: $target, min: 1, max: 35, style: .compact)
                Text("of 35 mi")
                    .font(.risoBody(10, .semibold))
                    .foregroundStyle(Color.risoMuted)
            }
            HStack(spacing: 8) {
                RisoSegmented(
                    options: [
                        (value: false, label: "One square"),
                        (value: true, label: "Split up"),
                    ],
                    selection: $isSplit,
                    style: .pill,
                    size: .compact
                )
                Text("1 square")
                    .font(.risoBody(10, .semibold))
                    .foregroundStyle(Color.risoMuted)
                Text("4\u{2013}6 mi")
                    .font(.risoBody(10.5, .semibold))
                    .foregroundStyle(Color.risoBlue)
            }
        }
    }
}

/// Thin `@State` wrapper so `RisoSegmented`'s pill style renders with a
/// valid `Binding` in a snapshot context (mirrors `RisoKitGallery`'s
/// `@State private var seg` for the card-style example above it).
private struct PillSegmentedPreview: View {
    @State private var value: String = "pools"

    var body: some View {
        RisoSegmented(
            options: [("library", "Library"), ("pools", "Pools · 2")],
            selection: $value,
            style: .pill
        )
    }
}

/// New (all live) · existing Continuous (Duration locked out) · existing
/// Duration (locked in) · linked tag — handoff `Counter Kinds.dc.html` §1.
private struct KindPickerStatesPreview: View {
    @State private var a: CountKind = .continuous
    @State private var b: CountKind = .continuous
    @State private var c: CountKind = .duration
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KindPickerView(selection: $a, lock: .none)
            KindPickerView(selection: $b, lock: .duration)
            KindPickerView(selection: $c, lock: .all)
            KindTagView(kind: .continuous, counterName: "Miles", lifetime: 148.6)
        }
    }
}

/// Discrete 300 · Continuous 26.2 · Duration 10h 30m with the wheel open — handoff §1 "Amount entry".
private struct GoalEntryKindsPreview: View {
    @State private var d = "300"
    @State private var c = "26.2"
    @State private var t = "10h 30m"
    var body: some View {
        VStack(spacing: 8) {
            GoalEntryView(kind: .discrete, text: $d)
            GoalEntryView(kind: .continuous, text: $c, suffix: "mi")
            GoalEntryView(kind: .duration, text: $t, startsOpen: true)
        }
    }
}
