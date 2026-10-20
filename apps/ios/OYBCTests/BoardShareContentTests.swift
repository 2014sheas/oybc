import XCTest
@testable import OYBC

/// The share sheet's copy rules (handoff 5c / 5d): title, filename, share
/// text, the always-on stats row and the streak-card rule.
final class BoardShareContentTests: XCTestCase {

    private func content(
        _ kind: MomentTrigger.Kind, name: String = "October reset", streak: Int = 0,
        timeframe: Timeframe = .weekly, isCore: Bool = true, size: Int = 5
    ) -> BoardShareContent {
        BoardShareContent(
            kind: kind, boardName: name, completedTasks: 13, totalTasks: 25, linesCompleted: 3,
            boardSize: size, streak: streak, timeframe: timeframe, isCore: isCore
        )
    }

    func test_titlesBadgesAndFilenamesByKind() {
        XCTAssertEqual(content(.bingo).sheetTitle, "Share bingo")
        XCTAssertEqual(content(.greenlog).sheetTitle, "Share greenlog")
        XCTAssertEqual(content(.bingo).badge, "BINGO")
        XCTAssertEqual(content(.greenlog).badge, "GREENLOG")
        XCTAssertEqual(content(.bingo).shareTitle, "October reset — BINGO")
        XCTAssertEqual(content(.greenlog).shareTitle, "October reset — GREENLOG")
        XCTAssertEqual(content(.bingo).fileName, "october-reset-bingo.png")
        XCTAssertEqual(content(.greenlog).fileName, "october-reset-greenlog.png")
        XCTAssertEqual(content(.bingo).tagline, "What's on your bingo card")
    }

    func test_slugMatchesWebSlugify() {
        XCTAssertEqual(BoardShareContent.slug("  Weekly -- Wellness! "), "weekly-wellness")
        XCTAssertEqual(BoardShareContent.slug("!!!"), "board")
        XCTAssertEqual(BoardShareContent.slug(String(repeating: "a", count: 80)).count, 60)
    }

    func test_shareText() {
        XCTAssertEqual(content(.bingo, size: 5).shareText, "Bingo on October reset! 3 of 12 lines.")
        XCTAssertEqual(content(.bingo, size: 3).shareText, "Bingo on October reset! 3 of 8 lines.")
        XCTAssertEqual(content(.greenlog).shareText, "I crushed every square. Greenlog on On Your Bingo Card!")
    }

    func test_squaresCardAlwaysOn_streakCardUnderChipRule() {
        XCTAssertEqual(content(.bingo, streak: 2).stats, [
            .init(value: "13/25", label: "SQUARES"), .init(value: "2w", label: "STREAK"),
        ])
        XCTAssertEqual(content(.greenlog, streak: 3, timeframe: .monthly).stats.last, .init(value: "3mo", label: "STREAK"))
        // streak <= 1, non-core, or no cadence → SQUARES only.
        XCTAssertEqual(content(.bingo, streak: 1).stats, [.init(value: "13/25", label: "SQUARES")])
        XCTAssertEqual(content(.bingo, streak: 0).stats.count, 1)
        XCTAssertEqual(content(.greenlog, streak: 5, isCore: false).stats.count, 1)
        XCTAssertEqual(content(.greenlog, streak: 5, timeframe: .custom).stats.count, 1)
    }

    func test_activityItemCarriesShareTitleAsSubject() throws {
        let c = content(.bingo)
        let item = PosterActivityItem(item: "poster", title: c.shareTitle)
        let vc = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        XCTAssertEqual(item.activityViewController(vc, subjectForActivityType: nil), "October reset — BINGO")
        XCTAssertEqual(item.activityViewControllerLinkMetadata(vc)?.title, "October reset — BINGO")
        XCTAssertEqual(item.activityViewController(vc, itemForActivityType: nil) as? String, "poster")
    }

    func test_showTaskNamesDefaultsOn() {
        XCTAssertTrue(BoardShareContent.showTaskNamesDefault)
    }
}
