import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for `RisoCompoundFieldsView` — the inline compound builder
/// extracted from `RisoSpecialTaskPanel`.
///
/// Each test renders the **real** `RisoCompoundFieldsView(seed:)` directly,
/// wrapped in minimal card chrome (panel header + type chips) that matches
/// what the user actually sees when the Compound chip is selected. No
/// hand-copied mirror view — regressions in the real component surface here.
///
/// Variants (light + dark each):
///   1. Empty — title blank, rule = All of, no subs
///   2. At least N — title filled, stepper row visible, no subs yet
///   3. In order with subs — "1./2." prefix, one Normal + one Counting sub
///   4. New-sub type = Counting — Goal/unit row + live preview visible
///
/// Width: 393pt (iPhone 16). Height sized per variant to capture full content.
final class RisoCompoundPanelSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - 1. Empty state (compound selected, no subs)

    func testCompoundEmptyLight() {
        let view = makeHost(seed: .empty)
            .padding(16)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 420)),
            record: recordMode
        )
    }

    func testCompoundEmptyDark() {
        let view = makeHost(seed: .empty)
            .padding(16)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 420),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - 2. At least N rule, stepper visible

    func testCompoundAtLeastNLight() {
        let view = makeHost(seed: .atLeastN)
            .padding(16)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 460)),
            record: recordMode
        )
    }

    func testCompoundAtLeastNDark() {
        let view = makeHost(seed: .atLeastN)
            .padding(16)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 460),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - 3. In order rule, two subs (Normal + Counting)

    func testCompoundInOrderWithSubsLight() {
        let view = makeHost(seed: .inOrderWithSubs)
            .padding(16)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 540)),
            record: recordMode
        )
    }

    func testCompoundInOrderWithSubsDark() {
        let view = makeHost(seed: .inOrderWithSubs)
            .padding(16)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 540),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - 4. New-sub type = Counting (Goal/unit row + preview visible)

    func testCompoundNewSubCountingLight() {
        let view = makeHost(seed: .newSubCounting)
            .padding(16)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 480)),
            record: recordMode
        )
    }

    func testCompoundNewSubCountingDark() {
        let view = makeHost(seed: .newSubCounting)
            .padding(16)
            .background(Color.risoPaper)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 480),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Builder

    /// Wraps `RisoCompoundFieldsView` in the same panel card + header chrome
    /// the user sees when the Compound chip is selected in `RisoSpecialTaskPanel`.
    /// The type-chip row is rendered statically (Compound = selected/green).
    private func makeHost(seed: CompoundSeed) -> some View {
        let library = SnapshotFixtures.makeCompoundSnapshotLibrary()
        return CompoundPanelHost(seed: seed.fieldSeed, taskLibrary: library)
    }
}

// MARK: - Seed aliases

/// Typed render-variant enum used by the test class. Converts to a
/// `RisoCompoundFieldsView.Seed` for the real view's seedable init.
fileprivate enum CompoundSeed {
    /// Compound tab selected, title empty, no subs, rule = All of.
    case empty
    /// Rule = At least N (stepper row visible), no subs yet.
    case atLeastN
    /// Rule = In order, two subs added (Normal + Counting), showing "1./2." prefix.
    case inOrderWithSubs
    /// New-sub type flipped to Counting, showing Goal/unit row + preview.
    case newSubCounting

    var fieldSeed: RisoCompoundFieldsView.Seed {
        switch self {
        case .empty:
            return RisoCompoundFieldsView.Seed(
                title: "",
                rule: .allOf,
                threshold: 2,
                subs: [],
                subInputText: "",
                newSubType: .normal,
                subGoalText: "5",
                subUnitText: ""
            )
        case .atLeastN:
            return RisoCompoundFieldsView.Seed(
                title: "Morning routine",
                rule: .atLeastN,
                threshold: 2,
                subs: [],
                subInputText: "",
                newSubType: .normal,
                subGoalText: "5",
                subUnitText: ""
            )
        case .inOrderWithSubs:
            return RisoCompoundFieldsView.Seed(
                title: "Morning routine",
                rule: .inOrder,
                threshold: 2,
                subs: [
                    .newNormal(title: "Meditate 10 min"),
                    .newCounting(action: "Run", goal: 5, unit: "km"),
                ],
                subInputText: "",
                newSubType: .normal,
                subGoalText: "5",
                subUnitText: ""
            )
        case .newSubCounting:
            return RisoCompoundFieldsView.Seed(
                title: "Workout block",
                rule: .allOf,
                threshold: 2,
                subs: [
                    .newNormal(title: "Warm up"),
                ],
                subInputText: "Run",
                newSubType: .counting,
                subGoalText: "5",
                subUnitText: "km"
            )
        }
    }
}

// MARK: - Host view

/// Wraps `RisoCompoundFieldsView` in the same card chrome visible in production:
/// the "Special task" section label + dismiss icon and the type-chip row
/// (Counting / Compound / Achievement, with Compound shown as selected).
///
/// This is NOT a re-implementation of `RisoCompoundFieldsView` — it is a
/// minimal host that adds only the surrounding card chrome so the snapshot
/// frame matches what the user actually sees.
private struct CompoundPanelHost: View {

    let seed: RisoCompoundFieldsView.Seed
    let taskLibrary: [OYBC.Task]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Header row
            HStack {
                Text("Special task")
                    .risoSectionLabel()
                Spacer()
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(width: 28, height: 28)
            }

            // Static type chips (Compound = selected, others = off)
            HStack(spacing: 6) {
                staticTypeChip("Counting", kind: .counting, isOn: false)
                staticTypeChip("Compound", kind: .compound, isOn: true)
                staticTypeChip("Achievement", kind: .achievement, isOn: false)
            }

            // The REAL compound fields view, seeded for this variant
            RisoCompoundFieldsView(
                seed: seed,
                taskLibrary: taskLibrary
            )
        }
        .padding(12)
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.small)
    }

    /// Static (non-interactive) type chip — no button wrapper needed for snapshots.
    private func staticTypeChip(_ label: String, kind: RisoTaskKind, isOn: Bool) -> some View {
        Text(label)
            .font(.risoHead(12, .bold))
            .foregroundStyle(isOn ? Color.risoPaper : Color.risoInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .fill(isOn ? kind.fill : Color.risoPaper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
    }
}
