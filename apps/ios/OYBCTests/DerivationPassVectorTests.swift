import XCTest
@testable import OYBC

/// Cross-platform derivation-pass enforcement (workstream C1 / issue #267).
///
/// Runs the hand-authored fixture (`packages/shared/tests/fixtures/derivationPassVectors.json`)
/// through iOS's `DerivationPass.findTransitiveParentCompounds` /
/// `findAffectedBoardIds` / `computeBoardStatsUpdate` in
/// `Services/DerivationPass.swift`. The SAME fixture is exercised on the
/// shared/web side by `packages/shared/tests/algorithms/derivationPass.test.ts`
/// against `@oybc/shared`'s `derivationPass.ts`. Both suites passing against
/// the same vectors is what proves the two hand-mirrored implementations
/// agree, not just an audit claim.
final class DerivationPassVectorTests: XCTestCase {

    private let ts = "2026-04-23T00:00:00.000Z"

    // MARK: - Fixture shapes

    private struct MiniChild: Decodable {
        let compoundTaskId: String
        let childTaskId: String
        let isDeleted: Bool
    }

    private struct FtpcVector: Decodable {
        let name: String
        let changedTaskId: String
        let children: [MiniChild]
        let expected: [String]
    }

    private struct MiniBoardTaskRef: Decodable {
        let boardId: String
        let taskId: String
    }

    private struct FabiVector: Decodable {
        let name: String
        let changedTaskId: String
        let parentCompounds: [String]
        let boardTasks: [MiniBoardTaskRef]
        let expected: [String]
    }

    private struct MiniTask: Decodable {
        let id: String
        let type: String
        let isCompleted: Bool
        let isDeleted: Bool
        let operatorField: String?
        let threshold: Int?
        let referencedBoardId: String?
        let referencedTemplateId: String?
        let achievementTrigger: String?
        let requiredCount: Int?
        // Bingo-pipeline hardening (item 5): windowed counting-task vectors
        // carry these so a shared-counter-derived task can hit the
        // lifetime-cache carve-out, and a plain counting task can accumulate
        // in-window increment events toward its goal.
        let maxCount: Int?
        let currentCount: Int?
        let sharedCounterId: String?

        enum CodingKeys: String, CodingKey {
            case id, type, isCompleted, isDeleted, threshold
            case operatorField = "operator"
            case referencedBoardId, referencedTemplateId, achievementTrigger, requiredCount
            case maxCount, currentCount, sharedCounterId
        }
    }

    /// One raw event in a fixture `windowContext.eventsByTaskId[taskId]` entry.
    /// `isDeleted` defaults to `false` when absent (mirrors the fixture note).
    private struct MiniWindowEvent: Decodable {
        let kind: String
        let occurredAt: String
        let delta: Int?
        let isDeleted: Bool?
    }

    /// Optional windowed-context block on a `computeBoardStatsUpdate` vector.
    /// Absent on a vector means lifetime resolution (the historical default);
    /// present means every event-owning task in `eventsByTaskId` resolves
    /// against the board's window instead of the lifetime cache.
    private struct MiniWindowContext: Decodable {
        let eventsByTaskId: [String: [MiniWindowEvent]]
    }

    private struct MiniBoardTaskFull: Decodable {
        let taskId: String
        let row: Int
        let col: Int
    }

    private struct MiniBoard: Decodable {
        let id: String
        let boardSize: Int
        let centerSquareType: String
        let startDate: String
        let endDate: String?
        let status: String
        let linesCompleted: Int
        let completedLineIds: [String]?
        let isDeleted: Bool
        let spawnedFromTemplateId: String?
    }

    private struct ExpectedStats: Decodable {
        let boardId: String
        let completedTasks: Int
        let linesCompleted: Int
        let completedLineIds: [String]
        let newBingos: [String]
        let lostBingos: [String]
    }

    /// Board-integrity PR-3 (issue #360) — the JSON shape of one
    /// `AchievementCellBadge` entry inside a fixture's `expectedCells`.
    private struct MiniAchievementBadge: Decodable {
        let mode: String
        let referencedBoardId: String?
        let referencedBoardCompleted: Bool?
        let referencedTemplateId: String?
        let templateInWindowMet: Int?
        let templateRequiredCount: Int?
    }

    /// Board-integrity PR-3 (issue #360) — the JSON shape of one
    /// `computeBoardGrid` `cells[]` entry, asserted only for vectors that
    /// carry `expectedCells` (see `CbsuVector.expectedCells`).
    private struct MiniCellState: Decodable {
        let boardTaskId: String
        let taskId: String
        let row: Int
        let col: Int
        let idx: Int
        let isCompleted: Bool
        let achievement: MiniAchievementBadge?
    }

    private struct CbsuVector: Decodable {
        let name: String
        let board: MiniBoard
        let boardTasksOnBoard: [MiniBoardTaskFull]
        let childrenByCompound: [String: [MiniChild]]
        let taskById: [String: MiniTask]
        let allBoards: [MiniBoard]
        let windowContext: MiniWindowContext?
        let expected: ExpectedStats
        /// Board-integrity PR-3 (issue #360) — OPTIONAL per-cell assertions
        /// against `computeBoardGrid`'s widened `cells[]` output, pinned for
        /// a representative subset of vectors. Absent on every other
        /// (pre-PR-3) vector — `computeBoardStatsUpdate` itself doesn't
        /// expose `cells`, so this is checked via a SEPARATE
        /// `computeBoardGrid` call, not by widening `expected`. Mirrors the
        /// shared TS `derivationPass.test.ts`'s `CbsuVector.expectedCells`.
        let expectedCells: [MiniCellState]?
    }

    private struct Fixture: Decodable {
        let findTransitiveParentCompounds: [FtpcVector]
        let findAffectedBoardIds: [FabiVector]
        let computeBoardStatsUpdate: [CbsuVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: DerivationPassVectorTests.self).url(
            forResource: "derivationPassVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "derivationPassVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    // MARK: - Converters

    private func toChild(_ m: MiniChild, _ idx: Int) -> CompoundChild {
        CompoundChild(
            id: "\(m.compoundTaskId)-\(m.childTaskId)-\(idx)",
            compoundTaskId: m.compoundTaskId,
            childTaskId: m.childTaskId,
            childIndex: idx,
            createdAt: ts,
            updatedAt: ts,
            version: 1,
            isDeleted: m.isDeleted
        )
    }

    private func toBoardTaskRef(_ m: MiniBoardTaskRef, _ idx: Int) -> BoardTask {
        BoardTask(
            id: "\(m.boardId)-\(m.taskId)-\(idx)",
            boardId: m.boardId,
            taskId: m.taskId,
            row: 0,
            col: idx,
            isCenter: false,
            createdAt: ts,
            updatedAt: ts,
            version: 1
        )
    }

    private func toTask(_ m: MiniTask) -> Task {
        Task(
            id: m.id,
            userId: "u",
            title: m.id,
            type: TaskType(rawValue: m.type) ?? .normal,
            maxCount: m.maxCount,
            operatorType: m.operatorField.flatMap { OperatorType(rawValue: $0) },
            threshold: m.threshold,
            referencedBoardId: m.referencedBoardId,
            referencedTemplateId: m.referencedTemplateId,
            achievementTrigger: m.achievementTrigger.flatMap { AchievementTrigger(rawValue: $0) },
            requiredCount: m.requiredCount,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: m.isCompleted,
            currentCount: m.currentCount,
            createdAt: ts,
            updatedAt: ts,
            version: 1,
            isDeleted: m.isDeleted,
            sharedCounterId: m.sharedCounterId
        )
    }

    /// Build a `WindowEvaluationContext` from a fixture's optional
    /// `windowContext` block — filling `TaskEvent` boilerplate (id/userId/
    /// timestamps/version) the fixture omits, `isDeleted` defaulting `false`
    /// when absent. `nil` in ⇒ `nil` out (lifetime resolution).
    private func toWindowContext(_ m: MiniWindowContext?) -> WindowEvaluationContext? {
        guard let m else { return nil }
        var eventsByTaskId: [String: [TaskEvent]] = [:]
        for (taskId, events) in m.eventsByTaskId {
            eventsByTaskId[taskId] = events.enumerated().map { idx, e in
                TaskEvent(
                    id: "\(taskId)-evt-\(idx)",
                    userId: "u",
                    taskId: taskId,
                    kind: TaskEventKind(rawValue: e.kind) ?? .completion,
                    delta: e.delta,
                    occurredAt: e.occurredAt,
                    boardId: nil,
                    createdAt: e.occurredAt,
                    updatedAt: e.occurredAt,
                    lastSyncedAt: nil,
                    version: 1,
                    isDeleted: e.isDeleted ?? false,
                    deletedAt: nil
                )
            }
        }
        return WindowEvaluationContext(eventsByTaskId: eventsByTaskId)
    }

    private func toBoardTaskFull(_ m: MiniBoardTaskFull, boardId: String) -> BoardTask {
        BoardTask(
            id: "\(boardId)-\(m.taskId)",
            boardId: boardId,
            taskId: m.taskId,
            row: m.row,
            col: m.col,
            isCenter: false,
            createdAt: ts,
            updatedAt: ts,
            version: 1
        )
    }

    /// Board-integrity PR-3 (issue #360) — build the real
    /// `DerivationPass.CellState` a fixture's `expectedCells` entry
    /// describes, so it can be compared against `computeBoardGrid`'s actual
    /// output via `Equatable` rather than field-by-field.
    private func toAchievementBadge(_ m: MiniAchievementBadge) -> DerivationPass.AchievementCellBadge {
        DerivationPass.AchievementCellBadge(
            mode: DerivationPass.AchievementCellBadge.Mode(rawValue: m.mode) ?? .specificBoard,
            referencedBoardId: m.referencedBoardId,
            referencedBoardCompleted: m.referencedBoardCompleted,
            referencedTemplateId: m.referencedTemplateId,
            templateInWindowMet: m.templateInWindowMet,
            templateRequiredCount: m.templateRequiredCount
        )
    }

    private func toCellState(_ m: MiniCellState) -> DerivationPass.CellState {
        DerivationPass.CellState(
            boardTaskId: m.boardTaskId,
            taskId: m.taskId,
            row: m.row,
            col: m.col,
            idx: m.idx,
            isCompleted: m.isCompleted,
            achievement: m.achievement.map(toAchievementBadge)
        )
    }

    private func toBoard(_ m: MiniBoard) -> Board {
        var dict: [String: Any] = [
            "id": m.id,
            "userId": "u",
            "name": m.id,
            "status": m.status,
            "boardSize": m.boardSize,
            "timeframe": "monthly",
            "startDate": m.startDate,
            "centerSquareType": m.centerSquareType,
            "isRandomized": false,
            "totalTasks": m.boardSize * m.boardSize,
            "completedTasks": 0,
            "linesCompleted": m.linesCompleted,
            "createdAt": ts,
            "updatedAt": ts,
            "version": 1,
            "isDeleted": m.isDeleted,
        ]
        if let endDate = m.endDate { dict["endDate"] = endDate }
        if let ids = m.completedLineIds {
            let jsonData = try! JSONEncoder().encode(ids)
            dict["completedLineIds"] = String(data: jsonData, encoding: .utf8)!
        }
        if let tid = m.spawnedFromTemplateId { dict["spawnedFromTemplateId"] = tid }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - Tests

    func testFindTransitiveParentCompoundsVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.findTransitiveParentCompounds.isEmpty)
        for v in fixture.findTransitiveParentCompounds {
            let children = v.children.enumerated().map { toChild($1, $0) }
            let result = DerivationPass.findTransitiveParentCompounds(changedTaskId: v.changedTaskId, children: children)
            XCTAssertEqual(result, Set(v.expected), "Vector '\(v.name)'")
        }
    }

    func testFindAffectedBoardIdsVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.findAffectedBoardIds.isEmpty)
        for v in fixture.findAffectedBoardIds {
            let boardTasks = v.boardTasks.enumerated().map { toBoardTaskRef($1, $0) }
            let result = DerivationPass.findAffectedBoardIds(
                changedTaskId: v.changedTaskId, parentCompounds: Set(v.parentCompounds), boardTasks: boardTasks
            )
            XCTAssertEqual(result, Set(v.expected), "Vector '\(v.name)'")
        }
    }

    func testComputeBoardStatsUpdateVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.computeBoardStatsUpdate.isEmpty)
        for v in fixture.computeBoardStatsUpdate {
            let board = toBoard(v.board)
            let boardTasksOnBoard = v.boardTasksOnBoard.map { toBoardTaskFull($0, boardId: board.id) }

            var childrenByCompound: [String: [CompoundChild]] = [:]
            for (key, children) in v.childrenByCompound {
                childrenByCompound[key] = children.enumerated().map { toChild($1, $0) }
            }

            var taskById: [String: Task] = [:]
            for (key, t) in v.taskById { taskById[key] = toTask(t) }

            let allBoards = v.allBoards.map(toBoard)
            let windowContext = toWindowContext(v.windowContext)

            let result = DerivationPass.computeBoardStatsUpdate(
                board: board, boardTasksOnBoard: boardTasksOnBoard,
                childrenByCompound: childrenByCompound, taskById: taskById, allBoards: allBoards,
                windowContext: windowContext
            )

            XCTAssertEqual(result.boardId, v.expected.boardId, "Vector '\(v.name)' boardId")
            XCTAssertEqual(result.completedTasks, v.expected.completedTasks, "Vector '\(v.name)' completedTasks")
            XCTAssertEqual(result.linesCompleted, v.expected.linesCompleted, "Vector '\(v.name)' linesCompleted")
            XCTAssertEqual(result.completedLineIds, v.expected.completedLineIds, "Vector '\(v.name)' completedLineIds")
            XCTAssertEqual(result.newBingos, v.expected.newBingos, "Vector '\(v.name)' newBingos")
            XCTAssertEqual(result.lostBingos, v.expected.lostBingos, "Vector '\(v.name)' lostBingos")

            // Board-integrity PR-3 — per-cell `cells[]` assertion, only for
            // vectors that carry `expectedCells`. Calls `computeBoardGrid`
            // directly (NOT `computeBoardStatsUpdate`, whose own return type
            // is unchanged) with the EXACT same inputs, so this also pins
            // that the widened kernel's grid/completedTasks stay
            // byte-identical to computeBoardStatsUpdate's independently-
            // asserted result above. Mirrors the shared TS test.
            if let expectedCells = v.expectedCells {
                let built = DerivationPass.computeBoardGrid(
                    board: board, boardTasksOnBoard: boardTasksOnBoard,
                    childrenByCompound: childrenByCompound, taskById: taskById,
                    allBoards: allBoards, windowContext: windowContext
                )
                XCTAssertEqual(built.completedTasks, v.expected.completedTasks, "Vector '\(v.name)' cells.completedTasks")
                XCTAssertEqual(built.cells, expectedCells.map(toCellState), "Vector '\(v.name)' cells")
            }
        }
    }
}
