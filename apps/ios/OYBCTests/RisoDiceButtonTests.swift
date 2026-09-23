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

    /// The pip table shared with the web SVG's `PIPS`, in the 24×24 inner
    /// box. The B3.1 review's proportions — corners one step out from the
    /// naive 6/12, which left only 1.04pt between a corner pip and the
    /// centre — carried over verbatim when the face grew 22 → 28 on
    /// 2026-09-22 (owner, device-testing #493): the 18-box became 24 and
    /// every coordinate scaled by 24/18, rounded (9 → 12, 5 → 7, 13 → 17).
    private static let expected: [VaryLevel: [CGPoint]] = [
        .off: [CGPoint(x: 12, y: 12)],
        .little: [CGPoint(x: 7, y: 7), CGPoint(x: 17, y: 17)],
        .lot: [
            CGPoint(x: 7, y: 7),
            CGPoint(x: 17, y: 7),
            CGPoint(x: 12, y: 12),
            CGPoint(x: 7, y: 17),
            CGPoint(x: 17, y: 17),
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

    /// The clearance the 28pt face was checked against: the 24-box is
    /// centred in the 28-face, so a corner pip centre at 7 lands at 9 in
    /// face coordinates and clears the keyline by
    /// `9 − 2 (radius) − 1.5 (Riso.Keyline.dense) = 5.5pt` — equivalently,
    /// the outermost pip EDGE sits at 21 while the keyline's inner edge is
    /// at 26.5. Checked against all FOUR face edges
    /// (left/top/right/bottom), not just the two `point.x`/`point.y` alone
    /// imply — a pip could clip the far edge even while clearing the near
    /// one — and the tightest of all of them is asserted against the
    /// documented 5.5pt, not just `> 0`, so a regression toward a cramped
    /// geometry would fail here rather than pass on a loose bound.
    /// Asserted as arithmetic over the real `pipDiameter` so a later
    /// diameter bump that would clip the border fails here, not in an
    /// advisory snapshot.
    func testNoPipClipsTheKeyline() {
        let faceSize: CGFloat = 28
        let inset: CGFloat = (faceSize - 24) / 2
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
        XCTAssertEqual(tightestClearance, 5.5, accuracy: 0.001)
    }

    /// The tightest pair on the lit faces is corner-to-centre. The B3.1
    /// widening took it from 1.04pt to 2.46pt of gap between pip EDGES at
    /// the 22pt face; scaling the whole geometry to the 28pt face carries
    /// it to 3.07pt (√(5²+5²) = 7.071 between centres, less the 4pt
    /// `pipDiameter`).
    func testCornerToCentreGapIsTheWidenedOne() {
        guard let corner = RisoDiceButton.pips[.lot]?.first,
              let centre = RisoDiceButton.pips[.lot]?.first(where: { $0.x == 12 && $0.y == 12 })
        else { return XCTFail("the five-pip face lost its corner or its centre") }
        let dx = centre.x - corner.x
        let dy = centre.y - corner.y
        let gap = (dx * dx + dy * dy).squareRoot() - RisoDiceButton.pipDiameter
        XCTAssertEqual(gap, 3.071, accuracy: 0.001)
    }
}
