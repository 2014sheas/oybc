import XCTest
@testable import OYBC

/// Cross-platform Windowed Completion enforcement (docs/WINDOWED_COMPLETION.md
/// §Testing matrix → "Cross-platform vectors").
///
/// Runs the three hand-authored PR-A fixtures
/// (`packages/shared/tests/fixtures/{taskWindowStateVectors,backfillEventVectors,
/// sealReDerivationVectors}.json`, synced to `OYBCTests/Fixtures/`) through the
/// iOS ports:
///   - `resolveTaskWindowState` (Helpers/TaskEvents.swift)
///   - `UUIDv5.uuidv5` + `backfillTaskEventId` + `buildBackfillTaskEvent`
///     (Helpers/UUIDv5.swift + Helpers/TaskEvents.swift)
///   - `DerivationPass.computeSealedCompletedCells` (Services/DerivationPass.swift)
///
/// The SAME fixtures are exercised on the shared/web side by
/// `packages/shared/tests/algorithms/{taskEvents,taskEventBackfill,sealReDerivation}.test.ts`.
/// Both suites passing against the same vectors is what proves the two
/// hand-mirrored implementations agree, not just an audit claim.
final class TaskEventVectorTests: XCTestCase {

    private let ts = "2026-07-01T00:00:00.000Z"

    // MARK: - Fixture loading

    private func loadFixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        guard let url = Bundle(for: TaskEventVectorTests.self).url(
            forResource: name, withExtension: "json"
        ) else {
            XCTFail(
                "\(name).json not found in test bundle — check project.yml's OYBCTests " +
                "`resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(T.self, from: try Data(contentsOf: url))
    }

    // MARK: - resolveTaskWindowState vectors

    private struct WindowEvent: Decodable {
        let kind: String
        let delta: Int?
        let occurredAt: String
        let isDeleted: Bool
    }

    private struct WindowVector: Decodable {
        struct MiniTask: Decodable { let type: String; let maxCount: Int? }
        struct Expected: Decodable { let isCompleted: Bool; let count: Int }
        let name: String
        let task: MiniTask
        let windowStart: String?
        /// Optional inclusive upper bound (2026-09-24 amendment); absent = none.
        let windowEnd: String?
        let events: [WindowEvent]
        let expected: Expected
    }

    private struct WindowFixture: Decodable { let vectors: [WindowVector] }

    /// One `lateLogOccurredAt` vector: `expected` is `"now"` (result is
    /// `nowIso` verbatim) or `"endDate"` (result is a canonical UTC
    /// millisecond ISO string naming the same instant as `board.endDate`).
    private struct LateLogVector: Decodable {
        struct MiniBoard: Decodable { let endDate: String?; let sealedAt: String? }
        let name: String
        let board: MiniBoard
        let nowIso: String
        let expected: String
    }

    private struct LateLogFixture: Decodable { let lateLogOccurredAt: [LateLogVector] }

    /// Build a minimal event-owning Task (type + maxCount) for windowed resolution.
    private func makeTask(type: String, maxCount: Int?, sharedCounterId: String? = nil) -> Task {
        Task(
            id: "t", userId: "u", title: "t",
            type: TaskType(rawValue: type) ?? .normal,
            maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false,
            createdAt: ts, updatedAt: ts, version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId
        )
    }

    private func makeEvent(_ e: WindowEvent, taskId: String = "t") -> TaskEvent {
        TaskEvent(
            id: UUID().uuidString, userId: "u", taskId: taskId,
            kind: TaskEventKind(rawValue: e.kind) ?? .completion,
            delta: e.delta, occurredAt: e.occurredAt, boardId: nil,
            createdAt: ts, updatedAt: ts, lastSyncedAt: nil,
            version: 1, isDeleted: e.isDeleted, deletedAt: nil
        )
    }

    func testResolveTaskWindowStateVectors() throws {
        let fixture = try loadFixture("taskWindowStateVectors", as: WindowFixture.self)
        XCTAssertFalse(fixture.vectors.isEmpty)
        for v in fixture.vectors {
            let task = makeTask(type: v.task.type, maxCount: v.task.maxCount)
            let events = v.events.map { makeEvent($0) }
            let result = resolveTaskWindowState(
                task: task, events: events, windowStart: v.windowStart, windowEnd: v.windowEnd
            )
            XCTAssertEqual(result.isCompleted, v.expected.isCompleted, "Vector '\(v.name)' isCompleted")
            XCTAssertEqual(result.count, v.expected.count, "Vector '\(v.name)' count")
        }
    }

    // MARK: - lateLogOccurredAt + boardWindowEnd vectors (2026-09-24 amendment)

    /// Build a minimal Board carrying only the window fields the helpers read.
    private func makeWindowBoard(endDate: String?, sealedAt: String?) -> Board {
        var dict: [String: Any] = [
            "id": "b", "userId": "u", "name": "b",
            "status": "active", "boardSize": 3,
            "timeframe": "weekly", "startDate": "2026-09-14T00:00:00.000",
            "centerSquareType": "none", "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": ts, "updatedAt": ts, "version": 1, "isDeleted": false,
        ]
        if let endDate { dict["endDate"] = endDate }
        if let sealedAt { dict["sealedAt"] = sealedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    func testLateLogOccurredAtVectors() throws {
        let fixture = try loadFixture("taskWindowStateVectors", as: LateLogFixture.self)
        XCTAssertEqual(Set(fixture.lateLogOccurredAt.map(\.expected)), ["now", "endDate"])
        let canonical = try NSRegularExpression(
            pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        )
        for v in fixture.lateLogOccurredAt {
            let board = makeWindowBoard(endDate: v.board.endDate, sealedAt: v.board.sealedAt)
            let result = lateLogOccurredAt(board: board, nowIso: v.nowIso)
            if v.expected == "now" {
                XCTAssertEqual(result, v.nowIso, "Vector '\(v.name)'")
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            XCTAssertNotNil(canonical.firstMatch(in: result, range: range), "Vector '\(v.name)' shape: \(result)")
            let endDate = try XCTUnwrap(v.board.endDate.flatMap { DateFormatting.parseISO($0) }, "Vector '\(v.name)'")
            let got = try XCTUnwrap(DateFormatting.parseISO(result), "Vector '\(v.name)' parse")
            XCTAssertEqual(
                (got.timeIntervalSince1970 * 1000).rounded(),
                (endDate.timeIntervalSince1970 * 1000).rounded(),
                "Vector '\(v.name)' instant"
            )
            XCTAssertNotEqual(result, v.nowIso, "Vector '\(v.name)'")
        }
    }

    func testBoardWindowEnd() {
        XCTAssertEqual(
            boardWindowEnd(makeWindowBoard(endDate: "2026-09-20T23:59:59.999", sealedAt: nil)),
            "2026-09-20T23:59:59.999"
        )
        XCTAssertNil(boardWindowEnd(makeWindowBoard(endDate: nil, sealedAt: nil)))
    }

    // MARK: - resolveLinkedCounterDisplay vectors (Task 3 item 6)

    private struct LinkedDisplayVector: Decodable {
        struct MiniTask: Decodable {
            let type: String
            let maxCount: Int?
            let sharedCounterId: String?
            let startDate: String?
            let endDate: String?
            let createdInWizard: Bool?
            let baseline: Int?
            let currentCount: Int?
            let isCompleted: Bool
        }
        struct Expected: Decodable { let displayed: Int; let isCompleted: Bool }
        let name: String
        let task: MiniTask
        let eventsByTaskId: [String: [WindowEvent]]?
        let sealedAt: String?
        let expected: Expected
    }

    private struct LinkedDisplayFixture: Decodable { let linkedCounterDisplay: [LinkedDisplayVector] }

    func testResolveLinkedCounterDisplayVectors() throws {
        let fixture = try loadFixture("taskWindowStateVectors", as: LinkedDisplayFixture.self)
        XCTAssertGreaterThanOrEqual(fixture.linkedCounterDisplay.count, 8)
        for v in fixture.linkedCounterDisplay {
            let m = v.task
            let task = Task(
                id: "t", userId: "u", title: "t",
                type: TaskType(rawValue: m.type) ?? .normal,
                maxCount: m.maxCount,
                totalCompletions: 0, totalInstances: 0,
                isCompleted: m.isCompleted, currentCount: m.currentCount,
                createdAt: ts, updatedAt: ts, version: 1, isDeleted: false,
                startDate: m.startDate, endDate: m.endDate,
                sharedCounterId: m.sharedCounterId, baseline: m.baseline,
                createdInWizard: m.createdInWizard ?? false
            )
            let events = v.eventsByTaskId.map { map in
                Dictionary(uniqueKeysWithValues: map.map { rootId, evs in
                    (rootId, evs.map { makeEvent($0, taskId: rootId) })
                })
            }
            let result = resolveLinkedCounterDisplay(task: task, eventsByTaskId: events, sealedAt: v.sealedAt)
            XCTAssertEqual(result.displayed, v.expected.displayed, "Vector '\(v.name)' displayed")
            XCTAssertEqual(result.isCompleted, v.expected.isCompleted, "Vector '\(v.name)' isCompleted")
        }
    }

    // MARK: - uuidv5 + backfill vectors

    private struct Uuidv5Vector: Decodable {
        let name: String
        let namespace: String
        let name_input: String
        let expected: String
    }

    private struct IdVector: Decodable {
        let taskId: String
        let completionId: String
        let incrementId: String
    }

    private struct BackfillTaskSnapshot: Decodable {
        let id: String
        let userId: String
        let type: String
        let sharedCounterId: String?
        let isCompleted: Bool
        let completedAt: String?
        let currentCount: Int?
        let updatedAt: String
        let isDeleted: Bool
    }

    private struct ExpectedEvent: Decodable {
        let id: String
        let userId: String
        let taskId: String
        let kind: String
        let delta: Int?
        let occurredAt: String
        let createdAt: String
        let updatedAt: String
        let version: Int
        let isDeleted: Bool
    }

    private struct EventVector: Decodable {
        let name: String
        let task: BackfillTaskSnapshot
        let expected: ExpectedEvent?
    }

    private struct BackfillFixture: Decodable {
        let uuidv5Vectors: [Uuidv5Vector]
        let idVectors: [IdVector]
        let eventVectors: [EventVector]
    }

    func testUuidv5KnownAnswerVectors() throws {
        let fixture = try loadFixture("backfillEventVectors", as: BackfillFixture.self)
        XCTAssertFalse(fixture.uuidv5Vectors.isEmpty)
        for v in fixture.uuidv5Vectors {
            let result = UUIDv5.uuidv5(name: v.name_input, namespace: v.namespace)
            XCTAssertEqual(result, v.expected, "uuidv5 vector '\(v.name)'")
        }
        // Belt-and-braces: the canonical RFC 4122 v5 known answer, independent
        // of any fixture regeneration.
        XCTAssertEqual(
            UUIDv5.uuidv5(name: "www.example.com", namespace: "6ba7b810-9dad-11d1-80b4-00c04fd430c8"),
            "2ed6657d-e927-568b-95e1-2665a8aea6a2"
        )
    }

    func testBackfillTaskEventIdVectors() throws {
        let fixture = try loadFixture("backfillEventVectors", as: BackfillFixture.self)
        XCTAssertFalse(fixture.idVectors.isEmpty)
        for v in fixture.idVectors {
            XCTAssertEqual(
                backfillTaskEventId(taskId: v.taskId, kind: .completion),
                v.completionId, "completion id for \(v.taskId)"
            )
            XCTAssertEqual(
                backfillTaskEventId(taskId: v.taskId, kind: .increment),
                v.incrementId, "increment id for \(v.taskId)"
            )
            // Kind-qualified: completion and increment ids must differ.
            XCTAssertNotEqual(v.completionId, v.incrementId)
        }
    }

    func testBuildBackfillTaskEventVectors() throws {
        let fixture = try loadFixture("backfillEventVectors", as: BackfillFixture.self)
        XCTAssertFalse(fixture.eventVectors.isEmpty)
        for v in fixture.eventVectors {
            let task = Task(
                id: v.task.id, userId: v.task.userId, title: v.task.id,
                type: TaskType(rawValue: v.task.type) ?? .normal,
                totalCompletions: 0, totalInstances: 0,
                isCompleted: v.task.isCompleted,
                completedAt: v.task.completedAt,
                currentCount: v.task.currentCount,
                createdAt: v.task.updatedAt, updatedAt: v.task.updatedAt,
                version: 1, isDeleted: v.task.isDeleted,
                sharedCounterId: v.task.sharedCounterId
            )
            let result = buildBackfillTaskEvent(task: task)

            guard let expected = v.expected else {
                XCTAssertNil(result, "Vector '\(v.name)' expected nil")
                continue
            }
            let event = try XCTUnwrap(result, "Vector '\(v.name)' expected an event")
            XCTAssertEqual(event.id, expected.id, "Vector '\(v.name)' id")
            XCTAssertEqual(event.userId, expected.userId, "Vector '\(v.name)' userId")
            XCTAssertEqual(event.taskId, expected.taskId, "Vector '\(v.name)' taskId")
            XCTAssertEqual(event.kind.rawValue, expected.kind, "Vector '\(v.name)' kind")
            XCTAssertEqual(event.delta, expected.delta, "Vector '\(v.name)' delta")
            XCTAssertEqual(event.occurredAt, expected.occurredAt, "Vector '\(v.name)' occurredAt")
            XCTAssertEqual(event.createdAt, expected.createdAt, "Vector '\(v.name)' createdAt")
            XCTAssertEqual(event.updatedAt, expected.updatedAt, "Vector '\(v.name)' updatedAt")
            XCTAssertEqual(event.version, expected.version, "Vector '\(v.name)' version")
            XCTAssertEqual(event.isDeleted, expected.isDeleted, "Vector '\(v.name)' isDeleted")
        }
    }

    // MARK: - Seal re-derivation vectors

    private struct SealVector: Decodable {
        struct MiniBoard: Decodable {
            let id: String
            let boardSize: Int
            let centerSquareType: String
            let startDate: String
            let endDate: String?
            let status: String
            let linesCompleted: Int
            let completedLineIds: [String]?
            let isDeleted: Bool
        }
        struct MiniTask: Decodable {
            let id: String
            let type: String
            let maxCount: Int?
            let sharedCounterId: String?
            /// Compound tasks only (Task-4 breadth vectors).
            let `operator`: String?
            let threshold: Int?
            // 2026-09-23 amendment: window-stamped derived counters.
            let startDate: String?
            let endDate: String?
            let createdInWizard: Bool?
            let isCompleted: Bool
            let isDeleted: Bool
        }
        struct MiniBoardTask: Decodable { let taskId: String; let row: Int; let col: Int }
        struct MiniCompoundChild: Decodable {
            let compoundTaskId: String
            let childTaskId: String
            let childIndex: Int
            let isDeleted: Bool
        }
        struct MiniEvent: Decodable {
            let id: String
            let taskId: String
            let kind: String
            let delta: Int?
            let occurredAt: String
            let isDeleted: Bool
        }
        let name: String
        let board: MiniBoard
        let tasks: [MiniTask]
        let boardTasks: [MiniBoardTask]
        let events: [MiniEvent]
        /// Optional — when present the snapshot is computed by the production
        /// `AppDatabase.computeSealSnapshot`, which bounds the union to
        /// `occurredAt <= sealedAt` (the `[startDate, sealedAt]` window).
        let sealedAt: String?
        /// Optional — compound links (absent = none).
        let compoundChildren: [MiniCompoundChild]?
        let expectedCells: [Int]
        /// Optional — the sealed snapshot's frozen stats.
        let expectedCompletedTasks: Int?
        let expectedLinesCompleted: Int?
        let expectedCompletedLineIds: [String]?
    }

    private struct SealFixture: Decodable { let vectors: [SealVector] }

    private func toBoard(_ m: SealVector.MiniBoard) -> Board {
        var dict: [String: Any] = [
            "id": m.id, "userId": "u", "name": m.id,
            "status": m.status, "boardSize": m.boardSize,
            "timeframe": "daily", "startDate": m.startDate,
            "centerSquareType": m.centerSquareType, "isRandomized": false,
            "totalTasks": m.boardSize * m.boardSize, "completedTasks": 0,
            "linesCompleted": m.linesCompleted,
            "createdAt": ts, "updatedAt": ts, "version": 1, "isDeleted": m.isDeleted,
        ]
        if let endDate = m.endDate { dict["endDate"] = endDate }
        if let ids = m.completedLineIds {
            dict["completedLineIds"] = String(data: try! JSONEncoder().encode(ids), encoding: .utf8)!
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func toTask(_ m: SealVector.MiniTask) -> Task {
        Task(
            id: m.id, userId: "u", title: m.id,
            type: TaskType(rawValue: m.type) ?? .normal,
            maxCount: m.maxCount,
            operatorType: m.operator.flatMap { OperatorType(rawValue: $0) },
            threshold: m.threshold,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: m.isCompleted,
            createdAt: ts, updatedAt: ts, version: 1, isDeleted: m.isDeleted,
            startDate: m.startDate,
            endDate: m.endDate,
            sharedCounterId: m.sharedCounterId,
            createdInWizard: m.createdInWizard ?? false
        )
    }

    private func toBoardTask(_ m: SealVector.MiniBoardTask, boardId: String) -> BoardTask {
        BoardTask(
            id: "\(boardId)-\(m.taskId)", boardId: boardId, taskId: m.taskId,
            row: m.row, col: m.col, isCenter: false,
            createdAt: ts, updatedAt: ts, version: 1
        )
    }

    private func toEvent(_ m: SealVector.MiniEvent) -> TaskEvent {
        TaskEvent(
            id: m.id, userId: "u", taskId: m.taskId,
            kind: TaskEventKind(rawValue: m.kind) ?? .completion,
            delta: m.delta, occurredAt: m.occurredAt, boardId: nil,
            createdAt: ts, updatedAt: ts, lastSyncedAt: nil,
            version: 1, isDeleted: m.isDeleted, deletedAt: nil
        )
    }

    func testComputeSealedCompletedCellsVectors() throws {
        let fixture = try loadFixture("sealReDerivationVectors", as: SealFixture.self)
        XCTAssertFalse(fixture.vectors.isEmpty)
        for v in fixture.vectors {
            let board = toBoard(v.board)
            let boardTasks = v.boardTasks.map { toBoardTask($0, boardId: board.id) }
            var taskById: [String: Task] = [:]
            for t in v.tasks { taskById[t.id] = toTask(t) }

            var eventsByTaskId: [String: [TaskEvent]] = [:]
            for e in v.events { eventsByTaskId[e.taskId, default: []].append(toEvent(e)) }

            let children: [CompoundChild] = (v.compoundChildren ?? []).enumerated().map { i, c in
                CompoundChild(
                    id: "cc-\(i)", compoundTaskId: c.compoundTaskId, childTaskId: c.childTaskId,
                    childIndex: c.childIndex, createdAt: ts, updatedAt: ts,
                    lastSyncedAt: nil, version: 1, isDeleted: c.isDeleted, deletedAt: nil
                )
            }
            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in children { childrenByCompound[c.compoundTaskId, default: []].append(c) }

            if let sealedAt = v.sealedAt {
                // Production path: the sealing data layer's own snapshot builder
                // (bound + resolvePlacements + stats + cells), so the
                // `[startDate, sealedAt]` upper bound is exercised for real.
                let sealedAtDate = try XCTUnwrap(DateFormatting.parseISO(sealedAt), "Vector '\(v.name)' sealedAt")
                let lookups = AppDatabase.SealLookups(
                    childrenByCompound: childrenByCompound,
                    taskById: taskById,
                    allBoards: [board],
                    allBoardTasks: boardTasks,
                    allChildren: children,
                    eventsByTaskId: eventsByTaskId
                )
                let snapshot = AppDatabase.computeSealSnapshot(
                    board: board, lookups: lookups,
                    sealedAtMs: sealedAtDate.timeIntervalSince1970 * 1000
                )
                XCTAssertEqual(snapshot.sealedCompletedCells, v.expectedCells, "Vector '\(v.name)' cells")
                if let expected = v.expectedCompletedTasks {
                    XCTAssertEqual(snapshot.completedTasks, expected, "Vector '\(v.name)' completedTasks")
                }
                if let expected = v.expectedLinesCompleted {
                    XCTAssertEqual(snapshot.linesCompleted, expected, "Vector '\(v.name)' linesCompleted")
                }
                if let expected = v.expectedCompletedLineIds {
                    XCTAssertEqual(snapshot.completedLineIds, expected, "Vector '\(v.name)' completedLineIds")
                }
                continue
            }

            let cells = DerivationPass.computeSealedCompletedCells(
                board: board,
                boardTasksOnBoard: boardTasks,
                childrenByCompound: childrenByCompound,
                taskById: taskById,
                allBoards: [board],
                windowContext: WindowEvaluationContext(eventsByTaskId: eventsByTaskId)
            )
            XCTAssertEqual(cells, v.expectedCells, "Vector '\(v.name)' cells")
        }
    }

    /// Task-4 breadth guard: the loop above iterates every vector; this pins
    /// that the compound / 4x4-bingo / sealedAt-bound cases are present so a
    /// fixture edit can't silently drop one.
    func testSealVectorBreadthCasesPresent() throws {
        let fixture = try loadFixture("sealReDerivationVectors", as: SealFixture.self)
        let names = Set(fixture.vectors.map(\.name))
        let required = [
            "compound-children-complete-in-window-green-and-pre-window-child-keeps-sibling-compound-grey",
            "bingo-4x4-row-and-main-diagonal-recorded-in-sealed-lines-with-near-misses",
            "normal-completion-after-endDate-before-sealedAt-excluded-by-endDate",
            "normal-completion-stamped-exactly-at-endDate-counts",
            "normal-completion-one-ms-after-sealedAt-excluded-even-though-lifetime-cache-says-done",
            "normal-completion-exactly-at-sealedAt-counts-inclusive-upper-bound",
        ]
        XCTAssertEqual(required.filter { !names.contains($0) }, [])
    }
}
