import XCTest
@testable import OYBC

/// Board Sources §Member rules (B3) — the compact stepper's ordering rule
/// (`RisoCompactStepperMath` in `RisoSpecialTaskPanel.swift`).
///
/// The review-round defect these pin: a SwiftUI `Button` tap does NOT
/// resign the `TextField`'s first responder, so a −/＋ tap used to step
/// the OLD value while the typed text sat uncommitted — and the later
/// blur then wrote that stale text over the step. Web can't hit this (a
/// mousedown blurs the input, `onBlur` commits, `onClick` steps after),
/// so the fix folds the commit into the step and these tests hold the
/// two platforms to the same number for the same gesture.
final class RisoCompactStepperMathTests: XCTestCase {

    private typealias Math = RisoCompactStepperMath

    // MARK: - committed(draft:min:max:)

    func testCommittedParsesAndClampsIntoRange() {
        XCTAssertEqual(Math.committed(draft: "7", min: 1, max: 35), 7)
        XCTAssertEqual(Math.committed(draft: "900", min: 1, max: 35), 35, "above max clamps down")
        XCTAssertEqual(Math.committed(draft: "0", min: 1, max: 35), 1, "below min clamps up")
        XCTAssertEqual(Math.committed(draft: "  12  ", min: 1, max: 35), 12, "whitespace trimmed")
    }

    /// A non-numeric or empty entry is not an error state — the field
    /// simply reverts, exactly like web's `commit()` bail-out.
    func testCommittedReturnsNilForNonNumericDraft() {
        XCTAssertNil(Math.committed(draft: "", min: 1, max: 35))
        XCTAssertNil(Math.committed(draft: "abc", min: 1, max: 35))
        XCTAssertNil(Math.committed(draft: "-", min: 1, max: 35))
        XCTAssertNil(Math.committed(draft: "1.5", min: 1, max: 35))
    }

    // MARK: - base(value:draft:min:max:)

    func testBaseIsTheLiveValueWhenNotEditing() {
        XCTAssertEqual(Math.base(value: 6, draft: nil, min: 1, max: 35), 6)
    }

    func testBaseIsTheDraftWhileEditing() {
        XCTAssertEqual(Math.base(value: 6, draft: "20", min: 1, max: 35), 20)
    }

    func testBaseFallsBackToTheValueForAnUnparseableDraft() {
        XCTAssertEqual(Math.base(value: 6, draft: "abc", min: 1, max: 35), 6)
        XCTAssertEqual(Math.base(value: 6, draft: "", min: 1, max: 35), 6)
    }

    /// The −/＋ disabled state reads `base`, not `value`: with the live
    /// value parked at `min` but `5` typed in, the − button must be live
    /// (web's blurred re-render would have enabled it too).
    func testBaseUnblocksTheBoundsWhileTypingAwayFromThem() {
        XCTAssertEqual(Math.base(value: 1, draft: "5", min: 1, max: 35), 5)
        XCTAssertEqual(Math.base(value: 35, draft: "5", min: 1, max: 35), 5)
    }

    // MARK: - stepped(value:draft:delta:min:max:)

    /// THE regression: type 20 over a value of 6, tap ＋ → 21, never 7.
    func testStepCommitsTheDraftFirst() {
        XCTAssertEqual(Math.stepped(value: 6, draft: "20", delta: 1, min: 1, max: 35), 21)
        XCTAssertEqual(Math.stepped(value: 6, draft: "20", delta: -1, min: 1, max: 35), 19)
    }

    func testStepWithoutADraftMovesTheLiveValue() {
        XCTAssertEqual(Math.stepped(value: 6, draft: nil, delta: 1, min: 1, max: 35), 7)
        XCTAssertEqual(Math.stepped(value: 6, draft: nil, delta: -1, min: 1, max: 35), 5)
    }

    func testStepClampsAtBothBounds() {
        XCTAssertEqual(Math.stepped(value: 35, draft: nil, delta: 1, min: 1, max: 35), 35)
        XCTAssertEqual(Math.stepped(value: 1, draft: nil, delta: -1, min: 1, max: 35), 1)
    }

    /// An out-of-range draft is clamped BEFORE the step, so ＋ on "900"
    /// with a goal of 35 lands on 35 rather than 36.
    func testStepClampsAnOutOfRangeDraftBeforeStepping() {
        XCTAssertEqual(Math.stepped(value: 6, draft: "900", delta: 1, min: 1, max: 35), 35)
        XCTAssertEqual(Math.stepped(value: 6, draft: "0", delta: -1, min: 1, max: 35), 1)
    }

    /// An unparseable draft is dropped and the step falls back to the
    /// live value — it never traps and never writes garbage.
    func testStepIgnoresAnUnparseableDraft() {
        XCTAssertEqual(Math.stepped(value: 6, draft: "abc", delta: 1, min: 1, max: 35), 7)
    }

    /// Step of 1, always (handoff §Interactions "Counting targets") —
    /// even on a 4-digit goal, where a percentage step would tempt.
    func testStepIsAlwaysOne() {
        XCTAssertEqual(Math.stepped(value: 1000, draft: nil, delta: 1, min: 1, max: 5000), 1001)
        XCTAssertEqual(Math.stepped(value: 1000, draft: nil, delta: -1, min: 1, max: 5000), 999)
    }
}
