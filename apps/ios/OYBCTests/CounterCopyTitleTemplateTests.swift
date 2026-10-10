import XCTest
@testable import OYBC

/// docs/SHARED_COUNTER_SETTINGS.md §1b hand-off (PR 2): copy-side titles read
/// the counter ROOT's templates — a title rendered from them is auto (seeds
/// blank, follows a goal or kind change), a custom one stays. Web twin:
/// `boardEditTaskSheetModel.templates.test.ts`.
final class CounterCopyTitleTemplateTests: XCTestCase {
    private typealias K = LinkedWindowKit
    private let root = CounterSettings.TitleSettings(
        titleTemplateSingular: "Run #N mile", titleTemplatePlural: "Run #N laps"
    )

    /// A per-board copy titled from the root's plural template.
    private var copy: Task { K.task("cp", maxCount: 5, sharedCounterId: "root", title: "Run 5 laps") }

    func test_boardEditSheet_seedsTemplateTitleBlank_onlyWithTheRoot() {
        XCTAssertEqual(SquareEditTaskSheet.seededTitle(for: copy, settings: root), "")
        XCTAssertEqual(SquareEditTaskSheet.seededTitle(for: copy), "Run 5 laps", "without the root it reads as custom")
        var custom = copy
        custom.title = "My laps"
        XCTAssertEqual(SquareEditTaskSheet.seededTitle(for: custom, settings: root), "My laps")
    }

    func test_boardEditSheet_previewRendersTheTemplate() {
        XCTAssertEqual(
            SquareEditTaskSheet.countingPreviewTitle(
                title: "", action: "Run", goalText: "3", unit: "miles", kind: .discrete, settings: root
            ),
            "Run 3 laps"
        )
        XCTAssertEqual(
            SquareEditTaskSheet.countingPreviewTitle(
                title: "", action: "Run", goalText: "1", unit: "miles", kind: .discrete, settings: root
            ),
            "Run 1 mile"
        )
    }

    func test_kindSwitchPreview_templateTitleFollowsTheRounding() {
        var r = K.task("root", maxCount: 2.5, title: "Run 2.5 laps")
        r.countKind = .continuous
        r.titleTemplatePlural = "Run #N laps"
        XCTAssertEqual(KindSwitchPreview.planned(task: r, to: .discrete, linkedCount: 0)?.titleAfter, "Run 3 laps")
        var c = r
        c.titleTemplatePlural = nil
        c.sharedCounterId = "root"
        XCTAssertEqual(
            KindSwitchPreview.planned(
                task: c, to: .discrete, linkedCount: 0, settings: .init(titleTemplatePlural: "Run #N laps")
            )?.titleAfter,
            "Run 3 laps"
        )
        XCTAssertEqual(KindSwitchPreview.planned(task: c, to: .discrete, linkedCount: 0)?.titleAfter, "Run 2.5 laps")
    }

    func test_taskEditPatch_rootTemplateTitle_seedsBlank_andReRendersOnGoalChange() {
        var r = K.task("root", maxCount: 5, title: "Run 5 laps")
        r.titleTemplatePlural = "Run #N laps"
        var seeded = TaskEditPatch.seededForEditor(from: r)
        XCTAssertEqual(seeded.title, "")
        seeded.goal = "8"
        XCTAssertEqual(seeded.applied(to: r).title, "Run 8 laps")
    }
}
