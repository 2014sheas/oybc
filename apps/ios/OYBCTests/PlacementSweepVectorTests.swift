import XCTest
@testable import OYBC

/// Cross-platform pins for `Helpers/PlacementSweep.swift`, driven by the same
/// `placementSweepVectors.json` as
/// `packages/shared/tests/algorithms/placementSweep.test.ts`. Mini rows are
/// widened to full rows exactly as the TS `full()` does.
enum SweepFixture {
    static let ts = "2026-10-01T00:00:00.000Z"

    /// Decodes `merged` defaults + the mini row into a model.
    static func decode<T: Decodable>(_ type: T.Type, defaults: [String: Any], mini: [String: Any]) throws -> T {
        let merged = defaults.merging(mini) { _, new in new }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    /// Board's array columns are stored as JSON strings (the GRDB shape).
    static func jsonStringColumns(_ row: [String: Any]) -> [String: Any] {
        var out = row
        if let cells = row["sealedCompletedCells"] as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: cells) {
            out["sealedCompletedCells"] = String(data: data, encoding: .utf8)
        }
        return out
    }

    static func workspace(_ ws: [String: Any]) throws -> BoardSources.SweepWorkspace {
        func rows(_ key: String) -> [[String: Any]] { ws[key] as? [[String: Any]] ?? [] }
        let tasks = try rows("tasks").map {
            try decode(Task.self, defaults: [
                "userId": "u", "totalCompletions": 0, "totalInstances": 0, "createdAt": ts, "updatedAt": ts,
                "version": 1, "type": "counting", "title": "Task \($0["id"] ?? "")", "isCompleted": false, "isDeleted": false,
            ], mini: $0)
        }
        let boards = try rows("boards").map {
            try decode(Board.self, defaults: [
                "userId": "u", "isRandomized": false, "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
                "createdAt": ts, "updatedAt": ts, "version": 1, "isDeleted": false,
            ], mini: jsonStringColumns($0))
        }
        let boardTasks = try rows("boardTasks").map {
            try decode(BoardTask.self, defaults: [
                "isCenter": false, "createdAt": ts, "updatedAt": ts, "version": 1, "isDeleted": false,
            ], mini: $0)
        }
        let links = try rows("compoundChildren").enumerated().map { i, c in
            try decode(CompoundChild.self, defaults: [
                "id": "\(c["compoundTaskId"] ?? "")-\(c["childTaskId"] ?? "")", "childIndex": i,
                "createdAt": ts, "updatedAt": ts, "version": 1,
            ], mini: c)
        }
        let events = try rows("events").enumerated().map { i, e in
            try decode(TaskEvent.self, defaults: [
                "id": "e\(i)", "userId": "u", "createdAt": ts, "updatedAt": ts, "version": 1, "isDeleted": false,
            ], mini: e)
        }
        return BoardSources.SweepWorkspace(tasks: tasks, boards: boards, boardTasks: boardTasks, compoundChildren: links, events: events)
    }

    static func loadFixture() throws -> [String: Any] {
        guard let url = Bundle(for: PlacementSweepVectorTests.self).url(forResource: "placementSweepVectors", withExtension: "json") else {
            XCTFail("placementSweepVectors.json missing from the test bundle")
            throw XCTSkip("Fixture missing")
        }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
}

final class PlacementSweepVectorTests: XCTestCase {

    private func json(_ plan: BoardSources.PlacementSweepPlan) throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! NSDictionary
    }

    func testPlanVectors() throws {
        let cases = try SweepFixture.loadFixture()["planPlacementSweep"] as! [[String: Any]]
        XCTAssertFalse(cases.isEmpty)
        for v in cases {
            let name = v["name"] as! String
            let plan = BoardSources.planPlacementSweep(ws: try SweepFixture.workspace(v["ws"] as! [String: Any]), now: SweepFixture.ts)
            XCTAssertEqual(try json(plan), v["expected"] as! NSDictionary, name)
        }
    }

    /// The fixture exercises the 4b outcomes: a compound mismatch and a repoint carrying child targets.
    func testFixtureCoversCompoundOutcomes() throws {
        let cases = try SweepFixture.loadFixture()["planPlacementSweep"] as! [[String: Any]]
        let expected = cases.compactMap { $0["expected"] as? [String: Any] }
        let reasons = expected.flatMap { ($0["outcomes"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String } }
        XCTAssertTrue(reasons.contains("compoundMismatch"))
        XCTAssertTrue(expected.contains { ($0["repoints"] as? [[String: Any]] ?? []).contains { $0["childTargets"] != nil } })
    }

    /// Applying each plan and re-planning reaches an empty plan within three runs, with no repoint after the first.
    func testConvergence() throws {
        let cases = try SweepFixture.loadFixture()["planPlacementSweep"] as! [[String: Any]]
        for v in cases {
            let name = v["name"] as! String
            var ws = try SweepFixture.workspace(v["ws"] as! [String: Any])
            var plan = BoardSources.planPlacementSweep(ws: ws, now: SweepFixture.ts)
            var runs = 0
            while !plan.isEmpty && runs < 3 {
                let byId = Dictionary(uniqueKeysWithValues: plan.repoints.map { ($0.boardTaskId, $0) })
                ws.boardTasks = ws.boardTasks.map { bt in
                    guard let r = byId[bt.id] else { return bt }
                    var next = bt
                    next.taskId = r.toTaskId
                    next.targetOverride = r.targetOverride
                    next.targetKind = r.targetKind
                    next.childTargets = r.childTargets
                    next.titleOverride = r.titleOverride
                    return next
                }
                ws.tasks = ws.tasks.map { t in
                    var next = t
                    if plan.orphanTombstones.contains(t.id) { next.isDeleted = true }
                    if plan.strips.contains(t.id) { next.timeframe = nil; next.startDate = nil; next.endDate = nil }
                    return next
                }
                plan = BoardSources.planPlacementSweep(ws: ws, now: SweepFixture.ts)
                runs += 1
                XCTAssertTrue(plan.repoints.isEmpty, "repoint after the first run: \(name)")
            }
            XCTAssertTrue(plan.isEmpty, "did not converge: \(name)")
        }
    }

    func testRekeyIds() throws {
        for v in try SweepFixture.loadFixture()["rekeyIds"] as! [[String: Any]] {
            let ids = v["ids"] as! [String]
            let out = BoardSources.rekeyIds(ids, map: v["map"] as! [String: String])
            XCTAssertEqual(out, v["expected"] as! [String], v["name"] as! String)
            XCTAssertEqual(out == ids, v["identity"] as! Bool, v["name"] as! String)
        }
    }

    func testRekeyRecordKeys() throws {
        for v in try SweepFixture.loadFixture()["rekeyRecordKeys"] as! [[String: Any]] {
            let record = v["record"] as! [String: Any]
            let out = BoardSources.rekeyRecordKeys(record, map: v["map"] as! [String: String])
            XCTAssertEqual(NSDictionary(dictionary: out), v["expected"] as! NSDictionary, v["name"] as! String)
            XCTAssertEqual(NSDictionary(dictionary: out).isEqual(to: record), v["identity"] as! Bool, v["name"] as! String)
        }
    }
}
