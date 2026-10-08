import XCTest
@testable import OYBC

/// Cross-platform enforcement for board-scoped task edits PR 1
/// (docs/BOARD_SCOPED_TASK_EDITS.md): the deterministic fork ids and the pure
/// `BoardScopedFork.plan` planner.
///
/// Runs the shared fixture (`Fixtures/boardScopedForkVectors.json`,
/// byte-identical to `packages/shared/tests/fixtures/boardScopedForkVectors.json`)
/// through the Swift twin in `Helpers/BoardScopedFork.swift`. The SAME
/// fixture is exercised on the shared side by
/// `packages/shared/tests/algorithms/boardScopedFork.test.ts`; the expected
/// ids are literal uuidv5 pins the Swift `uuidv5` must reproduce.
final class BoardScopedForkVectorTests: XCTestCase {

    // MARK: - Fixture shapes

    private struct FixBoard: Decodable {
        let id: String
        /// Absent = active (fixture note `boards`).
        let status: String?
        let startDate: String
        let endDate: String?
        let sealedAt: String?
        let isDeleted: Bool
    }

    private struct FixTask: Decodable {
        let id: String
        let type: String
        let title: String
        let action: String?
        let unit: String?
        let maxCount: CountValue?
        let `operator`: String?
        let sharedCounterId: String?
        let forkedFromTaskId: String?
        let createdInWizard: Bool?
    }

    private struct FixEvent: Decodable {
        let id: String
        let taskId: String
        let kind: String
        let occurredAt: String
        let delta: CountValue?
        let boardId: String?
        let isDeleted: Bool?
    }

    private struct FixPlacement: Decodable {
        let id: String
        let boardId: String
        let taskId: String
        let isDeleted: Bool
    }

    private struct FixLink: Decodable {
        let id: String
        let compoundTaskId: String
        let childTaskId: String
        let childIndex: Int
        let isDeleted: Bool
    }

    private struct FixRepoint: Decodable, Equatable {
        let boardTaskId: String
        let newTaskId: String
    }

    private struct FixEventCopy: Decodable {
        let id: String
        let sourceEventId: String
        let kind: String
        let occurredAt: String
        let delta: CountValue?
        let boardId: String?
    }

    private struct FixLinkCopy: Decodable {
        let id: String
        let childTaskId: String
        let childIndex: Int
    }

    private struct FixExpected: Decodable {
        let mode: String
        let forkId: String?
        let repoint: FixRepoint?
        let onBoardHolderCompoundIds: [String]?
        let eventCopies: [FixEventCopy]?
        let childLinksToCopy: [FixLinkCopy]?
    }

    private struct FixVector: Decodable {
        let name: String
        let task: FixTask
        let boardId: String
        let editedType: String
        let placements: [FixPlacement]
        let compoundChildren: [FixLink]?
        let events: [FixEvent]?
        let expected: FixExpected
    }

    private struct PlanSection: Decodable {
        let now: String
        let boards: [FixBoard]
        let vectors: [FixVector]
    }

    private struct TaskIdVector: Decodable { let boardId: String; let taskId: String; let expected: String }
    private struct EventIdVector: Decodable { let forkId: String; let eventId: String; let expected: String }
    private struct LinkIdVector: Decodable { let forkId: String; let childTaskId: String; let expected: String }
    private struct IdSection: Decodable {
        let forkTaskId: [TaskIdVector]
        let forkedEventId: [EventIdVector]
        let forkLinkId: [LinkIdVector]
    }

    private struct Fixture: Decodable {
        let ids: IdSection
        let planBoardScopedFork: PlanSection
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: BoardScopedForkVectorTests.self).url(
            forResource: "boardScopedForkVectors",
            withExtension: "json"
        ) else {
            XCTFail("boardScopedForkVectors.json not found in test bundle — re-run xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    // MARK: - Builders (fixture notes `tasks` / `events`)

    private static let old = "2026-01-01T00:00:00.000Z"

    private func makeTask(_ raw: FixTask) throws -> Task {
        let type = try XCTUnwrap(TaskType(rawValue: raw.type), "unknown type \(raw.type)")
        return Task(
            id: raw.id,
            userId: "u1",
            title: raw.title,
            type: type,
            action: raw.action,
            unit: raw.unit,
            maxCount: raw.maxCount,
            operatorType: raw.operator.flatMap(OperatorType.init(rawValue:)),
            totalCompletions: 3,
            totalInstances: 2,
            isCompleted: true,
            completedAt: "2026-10-06T10:00:00.000Z",
            currentCount: type == .counting ? 5 : nil,
            createdAt: Self.old,
            updatedAt: Self.old,
            lastSyncedAt: Self.old,
            version: 7,
            isDeleted: false,
            sharedCounterId: raw.sharedCounterId,
            createdInWizard: raw.createdInWizard ?? false,
            isCounter: true,
            forkedFromTaskId: raw.forkedFromTaskId
        )
    }

    private func makeEvent(_ raw: FixEvent) throws -> TaskEvent {
        TaskEvent(
            id: raw.id,
            userId: "u1",
            taskId: raw.taskId,
            kind: try XCTUnwrap(TaskEventKind(rawValue: raw.kind)),
            delta: raw.delta,
            occurredAt: raw.occurredAt,
            boardId: raw.boardId,
            createdAt: Self.old,
            updatedAt: Self.old,
            lastSyncedAt: Self.old,
            version: 3,
            isDeleted: raw.isDeleted ?? false,
            deletedAt: nil
        )
    }

    private func makeBoard(_ raw: FixBoard) throws -> Board {
        var dict: [String: Any] = [
            "id": raw.id, "userId": "u1", "name": raw.id, "status": raw.status ?? "active", "boardSize": 3,
            "timeframe": "weekly", "startDate": raw.startDate, "centerSquareType": "none",
            "isRandomized": false, "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": Self.old, "updatedAt": Self.old, "version": 1, "isDeleted": raw.isDeleted,
        ]
        if let endDate = raw.endDate { dict["endDate"] = endDate }
        if let sealedAt = raw.sealedAt { dict["sealedAt"] = sealedAt }
        return try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private func makePlacement(_ raw: FixPlacement) -> BoardTask {
        BoardTask(
            id: raw.id, boardId: raw.boardId, taskId: raw.taskId, row: 0, col: 0, isCenter: false,
            createdAt: Self.old, updatedAt: Self.old, version: 1, isDeleted: raw.isDeleted
        )
    }

    private func makeLink(_ raw: FixLink) -> CompoundChild {
        CompoundChild(
            id: raw.id, compoundTaskId: raw.compoundTaskId, childTaskId: raw.childTaskId,
            childIndex: raw.childIndex, createdAt: Self.old, updatedAt: Self.old,
            lastSyncedAt: Self.old, version: 4, isDeleted: raw.isDeleted, deletedAt: nil
        )
    }

    // MARK: - Tests

    func testNamespacesAreFixed() {
        XCTAssertEqual(BoardScopedFork.forkTaskNamespace, "fork:task")
        XCTAssertEqual(BoardScopedFork.forkEventNamespace, "fork:event")
        XCTAssertEqual(BoardScopedFork.forkLinkNamespace, "fork:link")
    }

    func testIdVectors() throws {
        let ids = try loadFixture().ids
        XCTAssertFalse(ids.forkTaskId.isEmpty)
        for v in ids.forkTaskId {
            XCTAssertEqual(BoardScopedFork.forkTaskId(boardId: v.boardId, taskId: v.taskId), v.expected)
        }
        for v in ids.forkedEventId {
            XCTAssertEqual(BoardScopedFork.forkedEventId(forkId: v.forkId, eventId: v.eventId), v.expected)
        }
        for v in ids.forkLinkId {
            XCTAssertEqual(BoardScopedFork.forkLinkId(forkId: v.forkId, childTaskId: v.childTaskId), v.expected)
        }
    }

    func testPlanVectors() throws {
        let section = try loadFixture().planBoardScopedFork
        XCTAssertEqual(section.vectors.count, 30)
        let boards = try section.boards.map(makeBoard)
        let now = section.now

        for v in section.vectors {
            let task = try makeTask(v.task)
            let board = try XCTUnwrap(boards.first { $0.id == v.boardId }, v.name)
            let plan = BoardScopedFork.plan(
                task: task,
                board: board,
                editedType: try XCTUnwrap(TaskType(rawValue: v.editedType), v.name),
                placements: v.placements.map(makePlacement),
                boards: boards,
                compoundChildren: (v.compoundChildren ?? []).map(makeLink),
                events: try (v.events ?? []).map(makeEvent),
                now: now
            )

            guard case let .fork(fork, eventCopies, childLinksToCopy, repoint, onBoardHolderCompoundIds) = plan else {
                XCTAssertEqual(v.expected.mode, "inPlace", "\(v.name): planned in place, expected fork")
                continue
            }
            XCTAssertEqual(v.expected.mode, "fork", "\(v.name): planned a fork, expected in place")
            let forkId = try XCTUnwrap(v.expected.forkId, v.name)

            XCTAssertEqual(fork.id, forkId, v.name)
            XCTAssertEqual(fork.forkedFromTaskId, v.task.id, v.name)
            XCTAssertTrue(fork.createdInWizard, v.name)
            XCTAssertFalse(fork.isCounter, v.name)
            XCTAssertEqual(fork.version, 1, v.name)
            XCTAssertEqual(fork.createdAt, now, v.name)
            XCTAssertEqual(fork.updatedAt, now, v.name)
            XCTAssertNil(fork.lastSyncedAt, v.name)
            XCTAssertNil(fork.deletedAt, v.name)
            XCTAssertFalse(fork.isDeleted, v.name)
            XCTAssertFalse(fork.isCompleted, v.name)
            XCTAssertNil(fork.completedAt, v.name)
            XCTAssertEqual(fork.currentCount, v.task.type == "counting" ? 0 : nil, v.name)
            XCTAssertEqual(fork.totalCompletions, 0, v.name)
            XCTAssertEqual(fork.totalInstances, 1, v.name)
            XCTAssertEqual(fork.title, v.task.title, v.name)
            XCTAssertEqual(fork.type.rawValue, v.task.type, v.name)

            XCTAssertEqual(
                repoint.map { FixRepoint(boardTaskId: $0.boardTaskId, newTaskId: $0.newTaskId) },
                v.expected.repoint,
                v.name
            )

            XCTAssertEqual(onBoardHolderCompoundIds, try XCTUnwrap(v.expected.onBoardHolderCompoundIds, v.name), v.name)

            let expEvents = v.expected.eventCopies ?? []
            XCTAssertEqual(eventCopies.map(\.id), expEvents.map(\.id), v.name)
            for (got, exp) in zip(eventCopies, expEvents) {
                XCTAssertEqual(got.kind.rawValue, exp.kind, v.name)
                XCTAssertEqual(got.occurredAt, exp.occurredAt, v.name)
                XCTAssertEqual(got.delta, exp.delta, v.name)
                XCTAssertEqual(got.boardId, exp.boardId, v.name)
                XCTAssertEqual(got.taskId, forkId, v.name)
                XCTAssertEqual(got.userId, "u1", v.name)
                XCTAssertEqual(got.createdAt, now, v.name)
                XCTAssertEqual(got.updatedAt, now, v.name)
                XCTAssertEqual(got.version, 1, v.name)
                XCTAssertFalse(got.isDeleted, v.name)
                XCTAssertNil(got.lastSyncedAt, v.name)
            }

            let expLinks = v.expected.childLinksToCopy ?? []
            XCTAssertEqual(childLinksToCopy.map(\.id), expLinks.map(\.id), v.name)
            for (got, exp) in zip(childLinksToCopy, expLinks) {
                XCTAssertEqual(got.childTaskId, exp.childTaskId, v.name)
                XCTAssertEqual(got.childIndex, exp.childIndex, v.name)
                XCTAssertEqual(got.compoundTaskId, forkId, v.name)
                XCTAssertEqual(got.version, 1, v.name)
                XCTAssertEqual(got.createdAt, now, v.name)
                XCTAssertFalse(got.isDeleted, v.name)
                XCTAssertNil(got.lastSyncedAt, v.name)
            }
        }
    }
}
