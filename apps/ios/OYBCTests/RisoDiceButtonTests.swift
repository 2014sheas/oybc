import XCTest
import CoreGraphics
@testable import OYBC

/// Board Sources §Member rules (B3.1) — the dice face's pip geometry
/// (`RisoDiceButton.pips`).
///
/// Why a plain XCTest and not a snapshot: cross-platform coordinate parity
/// is the entire point of the square dice face, and the iOS snapshot
/// baselines that would otherwise be the only cover are ADVISORY in CI
/// (`continue-on-error` on the snapshot step — ROADMAP A8), so a one-sided
/// nudge to either platform's table would ship silently. The web twin
/// (`apps/web/src/components/riso/__tests__/DiceButton.test.ts`) asserts
/// the same three faces against the same numbers; move one side alone and
/// one of the two tests goes red.
final class RisoDiceButtonTests: XCTestCase {

    /// The pip table shared with the web SVG's `PIPS`, in the 18×18 inner
    /// box. Corners at 5/13 rather than 6/12 (B3.1 review): 6/12 left only
    /// 1.04pt between a corner pip and the centre pip, and the pattern
    /// spanned 6×6 inside a 22×22 face.
    private static let expected: [VaryLevel: [CGPoint]] = [
        .off: [CGPoint(x: 9, y: 9)],
        .little: [CGPoint(x: 5, y: 5), CGPoint(x: 13, y: 13)],
        .lot: [
            CGPoint(x: 5, y: 5),
            CGPoint(x: 13, y: 5),
            CGPoint(x: 9, y: 9),
            CGPoint(x: 5, y: 13),
            CGPoint(x: 13, y: 13),
        ],
    ]

    func testOffFaceIsOneCentredPip() {
        XCTAssertEqual(RisoDiceButton.pips[.off], Self.expected[.off])
    }

    func testLittleFaceIsTwoPipsOnTheDiagonal() {
        XCTAssertEqual(RisoDiceButton.pips[.little], Self.expected[.little])
    }

    func testLotFaceIsTheFivePipQuincunx() {
        XCTAssertEqual(RisoDiceButton.pips[.lot], Self.expected[.lot])
    }

    /// Every level is covered — a fourth face added without a vector would
    /// otherwise slip past the three cases above.
    func testEveryVaryLevelHasAPinnedFace() {
        for level in [VaryLevel.off, .little, .lot] {
            XCTAssertEqual(RisoDiceButton.pips[level], Self.expected[level], "level \(level)")
        }
        XCTAssertEqual(RisoDiceButton.pips.count, Self.expected.count)
    }

    /// The clearance the widened corners were checked against: the 18-box
    /// is centred in the 22-face, so a corner pip centre at 5 lands at 7 in
    /// face coordinates and clears the keyline by
    /// `7 − 1.6 (radius) − 1.5 (Riso.Keyline.dense) = 3.9pt`. Checked
    /// against all FOUR face edges (left/top/right/bottom), not just the
    /// two `point.x`/`point.y` alone imply — a pip could clip the far edge
    /// even while clearing the near one — and the tightest of all of them
    /// is asserted against the documented 3.9pt, not just `> 0`, so a
    /// regression back toward the old cramped 6/12 geometry (1.04pt corner
    /// gap) would fail here rather than pass on a loose bound. Asserted as
    /// arithmetic over the real `pipDiameter` so a later diameter bump that
    /// would clip the border fails here, not in an advisory snapshot.
    func testNoPipClipsTheKeyline() {
        let faceSize: CGFloat = 22
        let inset: CGFloat = (faceSize - 18) / 2
        let radius = RisoDiceButton.pipDiameter / 2
        var tightestClearance: CGFloat = .greatestFiniteMagnitude
        for (level, points) in RisoDiceButton.pips {
            for point in points {
                let faceX = point.x + inset
                let faceY = point.y + inset
                let edgeClearances: [CGFloat] = [
                    faceX - radius - Riso.Keyline.dense,               // left
                    faceY - radius - Riso.Keyline.dense,               // top
                    (faceSize - faceX) - radius - Riso.Keyline.dense,  // right
                    (faceSize - faceY) - radius - Riso.Keyline.dense,  // bottom
                ]
                for clearance in edgeClearances {
                    XCTAssertGreaterThan(clearance, 0, "level \(level) pip \(point) clips the keyline")
                }
                tightestClearance = Swift.min(tightestClearance, edgeClearances.min()!)
            }
        }
        XCTAssertEqual(tightestClearance, 3.9, accuracy: 0.001)
    }

    /// The tightest pair on the lit faces is corner-to-centre; the widening
    /// took it from 1.04pt to 2.46pt of gap between pip EDGES.
    func testCornerToCentreGapIsTheWidenedOne() {
        guard let corner = RisoDiceButton.pips[.lot]?.first,
              let centre = RisoDiceButton.pips[.lot]?.first(where: { $0.x == 9 && $0.y == 9 })
        else { return XCTFail("the five-pip face lost its corner or its centre") }
        let dx = centre.x - corner.x
        let dy = centre.y - corner.y
        let gap = (dx * dx + dy * dy).squareRoot() - RisoDiceButton.pipDiameter
        XCTAssertEqual(gap, 2.457, accuracy: 0.001)
    }
}
