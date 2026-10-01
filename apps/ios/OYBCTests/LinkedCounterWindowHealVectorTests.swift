import XCTest
@testable import OYBC

/// Cross-platform enforcement for the windowed-linked-counter heal planner,
/// placement gate and copy-draft builder (owner rule 2026-10-01).
///
/// Runs the shared fixture (`Fixtures/linkedCounterWindowHealVectors.json`,
/// byte-identical to
/// `packages/shared/tests/fixtures/linkedCounterWindowHealVectors.json`)
/// through iOS's `BoardSources` twins in `Helpers/LinkedCounterWindowHeal.swift`.
/// The SAME fixture is exercised on the shared side by
/// `packages/shared/tests/algorithms/linkedCounterWindowHeal.test.ts` — both
/// suites passing against byte-identical vectors is what proves the two
/// hand-mirrored implementations agree (the `MemberRuleVectorTests`
/// precedent). The copy ids are literal uuidv5 pins the Swift `uuidv5` must
/// reproduce independently.
final class LinkedCounterWindowHealVectorTests: XCTestCase {

    // MARK: - Fixture shapes

    private struct SameWindowStartVector: Decodable {
        let name: String
        let a: String?
        let b: String?
        let expected: Bool
    }

    private struct StampedForBoardVector: Decodable {
        struct MiniTask: Decodable {
            let sharedCounterId: String?
            let startDate: String?
            let createdInWizard: Bool
        }
        struct MiniBoard: Decodable { let startDate: String }
        let name: String
        let task: MiniTask
        let board: MiniBoard
        let expected: Bool
    }

    private struct FixTask: Decodable {
        let id: String
        let type: String
        let sharedCounterId: String?
        let startDate: String?
        let endDate: String?
        let timeframe: String?
        let createdInWizard: Bool
        let isDeleted: Bool
        let maxCount: Int?
    }

    private struct FixBoard: Decodable {
        let id: String
        let timeframe: String
        let startDate: String
        let endDate: String?
        let isDeleted: Bool
    }

    private struct FixBoardTask: Decodable {
        let id: String
        let boardId: String
        let taskId: String
        let isDeleted: Bool
    }

    private struct FixLink: Decodable {
        let compoundTaskId: String
        let childTaskId: String
        let isDeleted: Bool
    }

    private struct FixStamp: Decodable {
        let taskId: String
        let boardId: String
        let timeframe: String
        let startDate: String
        let endDate: String?
    }

    private struct FixCopy: Decodable {
        let id: String
        let boardId: String
        let boardTaskId: String
        let sourceTaskId: String
        let rootTaskId: String
        let timeframe: String
        let startDate: String
        let endDate: String?
    }

    private struct FixPlan: Decodable {
        let stamps: [FixStamp]
        let copies: [FixCopy]
    }

    private struct PlanVector: Decodable {
        let name: String
        /// A vector-level roster overrides the section's shared `boards`.
        let boards: [FixBoard]?
        let tasks: [FixTask]
        let boardTasks: [FixBoardTask]
        let compoundChildren: [FixLink]
        let expected: FixPlan
    }

    private struct PlanSection: Decodable {
        let boards: [FixBoard]
        let vectors: [PlanVector]
    }

    private struct FixDraft: Decodable {
        let id: String
        let rootTaskId: String
        let sourceMemberId: String
        let replacesId: String
        let maxCount: Int
        let baseline: Int
        let title: String
        let action: String
        let unit: String
        let timeframe: String
        let startDate: String?
        let endDate: String?
    }

    private struct DraftVector: Decodable {
        struct MiniSource: Decodable {
            let title: String
            let action: String?
            let unit: String?
            let maxCount: Int?
        }
        let name: String
        let copy: FixCopy
        let sourceTask: MiniSource
        let baseline: Int
        /// `null` in the fixture = the builder refuses (goal-less source).
        let expected: FixDraft?
    }

    private struct Fixture: Decodable {
        let sameWindowStart: [SameWindowStartVector]
        let isWindowStampedForBoard: [StampedForBoardVector]
        let planLinkedCounterWindowHeal: PlanSection
        let windowStampedCopyDraft: [DraftVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: LinkedCounterWindowHealVectorTests.self).url(
            forResource: "linkedCounterWindowHealVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "linkedCounterWindowHealVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    // MARK: - Value builders

    private static let isoStamp = "2026-10-01T00:00:00.000Z"

    private func timeframe(_ raw: String) throws -> Timeframe {
        try XCTUnwrap(Timeframe(rawValue: raw), "unknown timeframe \(raw)")
    }

    private func makeTask(_ raw: FixTask) throws -> Task {
        Task(
            id: raw.id,
            userId: "u1",
            title: raw.id,
            type: try XCTUnwrap(TaskType(rawValue: raw.type), "unknown task type \(raw.type)"),
            maxCount: raw.maxCount,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: Self.isoStamp,
            updatedAt: Self.isoStamp,
            version: 1,
            isDeleted: raw.isDeleted,
            timeframe: try raw.timeframe.map(timeframe),
            startDate: raw.startDate,
            endDate: raw.endDate,
            sharedCounterId: raw.sharedCounterId,
            createdInWizard: raw.createdInWizard
        )
    }

    /// `Board` has no memberwise init (custom `Codable`), so build it from a
    /// JSON dictionary — the `DerivationPassVectorTests` pattern.
    private func makeBoard(id: String, timeframe: String, startDate: String, endDate: String?, isDeleted: Bool) throws -> Board {
        var dict: [String: Any] = [
            "id": id,
            "userId": "u1",
            "name": id,
            "status": "active",
            "boardSize": 3,
            "timeframe": timeframe,
            "startDate": startDate,
            "centerSquareType": "none",
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": Self.isoStamp,
            "updatedAt": Self.isoStamp,
            "version": 1,
            "isDeleted": isDeleted,
        ]
        if let endDate { dict["endDate"] = endDate }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoard(_ raw: FixBoard) throws -> Board {
        try makeBoard(id: raw.id, timeframe: raw.timeframe, startDate: raw.startDate, endDate: raw.endDate, isDeleted: raw.isDeleted)
    }

    private func makeBoardTask(_ raw: FixBoardTask) -> BoardTask {
        BoardTask(
            id: raw.id,
            boardId: raw.boardId,
            taskId: raw.taskId,
            row: 0,
            col: 0,
            isCenter: false,
            createdAt: Self.isoStamp,
            updatedAt: Self.isoStamp,
            version: 1,
            isDeleted: raw.isDeleted
        )
    }

    private func makeLink(_ raw: FixLink, _ index: Int) -> CompoundChild {
        CompoundChild(
            id: "link-\(raw.compoundTaskId)-\(raw.childTaskId)-\(index)",
            compoundTaskId: raw.compoundTaskId,
            childTaskId: raw.childTaskId,
            childIndex: index,
            createdAt: Self.isoStamp,
            updatedAt: Self.isoStamp,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: raw.isDeleted,
            deletedAt: nil
        )
    }

    private func makeCopy(_ raw: FixCopy) throws -> BoardSources.LinkedCounterWindowCopy {
        BoardSources.LinkedCounterWindowCopy(
            id: raw.id,
            boardId: raw.boardId,
            boardTaskId: raw.boardTaskId,
            sourceTaskId: raw.sourceTaskId,
            rootTaskId: raw.rootTaskId,
            timeframe: try timeframe(raw.timeframe),
            startDate: raw.startDate,
            endDate: raw.endDate
        )
    }

    // MARK: - sameWindowStart

    func testSameWindowStart() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.sameWindowStart.count, 6)
        for v in fixture.sameWindowStart {
            XCTAssertEqual(BoardSources.sameWindowStart(v.a, v.b), v.expected, v.name)
        }
    }

    // MARK: - isWindowStampedForBoard

    func testIsWindowStampedForBoard() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.isWindowStampedForBoard.count, 5)
        for v in fixture.isWindowStampedForBoard {
            let task = Task(
                id: "t", userId: "u1", title: "t", type: .counting, maxCount: 5,
                totalCompletions: 0, totalInstances: 0,
                createdAt: Self.isoStamp, updatedAt: Self.isoStamp, version: 1, isDeleted: false,
                startDate: v.task.startDate,
                sharedCounterId: v.task.sharedCounterId,
                createdInWizard: v.task.createdInWizard
            )
            let board = try makeBoard(id: "b", timeframe: "monthly", startDate: v.board.startDate, endDate: nil, isDeleted: false)
            XCTAssertEqual(BoardSources.isWindowStampedForBoard(task, board: board), v.expected, v.name)
        }
    }

    // MARK: - planLinkedCounterWindowHeal

    func testPlanLinkedCounterWindowHeal() throws {
        let section = try loadFixture().planLinkedCounterWindowHeal
        XCTAssertGreaterThanOrEqual(section.vectors.count, 20)
        XCTAssertTrue(section.vectors.contains { !$0.expected.copies.isEmpty })
        // The all-or-nothing veto: a PLACED unstamped row that is left alone.
        XCTAssertTrue(section.vectors.contains { v in
            !v.boardTasks.isEmpty
                && v.tasks.contains { $0.sharedCounterId != nil && !$0.createdInWizard }
                && v.expected.stamps.isEmpty && v.expected.copies.isEmpty
        })
        // A mis-placed window-stamped row: copies with no stamp.
        XCTAssertTrue(section.vectors.contains { $0.expected.stamps.isEmpty && !$0.expected.copies.isEmpty })
        let sharedBoards = try section.boards.map(makeBoard)

        for v in section.vectors {
            let plan = BoardSources.planLinkedCounterWindowHeal(
                tasks: try v.tasks.map(makeTask),
                boardTasks: v.boardTasks.map(makeBoardTask),
                boards: try v.boards.map { try $0.map(makeBoard) } ?? sharedBoards,
                compoundChildren: v.compoundChildren.enumerated().map { makeLink($1, $0) }
            )
            let expectedStamps = try v.expected.stamps.map {
                BoardSources.LinkedCounterWindowStamp(
                    taskId: $0.taskId, boardId: $0.boardId,
                    timeframe: try timeframe($0.timeframe), startDate: $0.startDate, endDate: $0.endDate
                )
            }
            let expectedCopies = try v.expected.copies.map(makeCopy)
            XCTAssertEqual(plan.stamps, expectedStamps, "\(v.name): stamps")
            XCTAssertEqual(plan.copies, expectedCopies, "\(v.name): copies")
            // The pinned copy ids are literal uuidv5 outputs; they must also be
            // the id the wizard / spawn would mint for the same (board, root).
            for copy in plan.copies {
                XCTAssertEqual(
                    copy.id,
                    BoardSources.derivedTaskId(boardId: copy.boardId, rootTaskId: copy.rootTaskId),
                    "\(v.name): copy id for \(copy.boardId)"
                )
            }
        }
    }

    // MARK: - windowStampedCopyDraft

    func testWindowStampedCopyDraft() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.windowStampedCopyDraft.count, 4)
        XCTAssertTrue(fixture.windowStampedCopyDraft.contains { $0.expected == nil })
        for v in fixture.windowStampedCopyDraft {
            let source = Task(
                id: v.copy.sourceTaskId, userId: "u1", title: v.sourceTask.title, type: .counting,
                action: v.sourceTask.action, unit: v.sourceTask.unit, maxCount: v.sourceTask.maxCount,
                totalCompletions: 0, totalInstances: 0,
                createdAt: Self.isoStamp, updatedAt: Self.isoStamp, version: 1, isDeleted: false,
                sharedCounterId: v.copy.rootTaskId
            )
            let draft = BoardSources.windowStampedCopyDraft(
                copy: try makeCopy(v.copy), sourceTask: source, baseline: v.baseline
            )
            guard let expected = v.expected else {
                XCTAssertNil(draft, v.name)
                continue
            }
            let unwrapped = try XCTUnwrap(draft, "\(v.name): expected a draft")
            XCTAssertEqual(unwrapped, BoardSources.DerivedTaskDraft(
                id: expected.id,
                rootTaskId: expected.rootTaskId,
                sourceMemberId: expected.sourceMemberId,
                replacesId: expected.replacesId,
                maxCount: expected.maxCount,
                baseline: expected.baseline,
                title: expected.title,
                action: expected.action,
                unit: expected.unit,
                timeframe: try timeframe(expected.timeframe),
                startDate: expected.startDate,
                endDate: expected.endDate
            ), v.name)
        }
    }
}
