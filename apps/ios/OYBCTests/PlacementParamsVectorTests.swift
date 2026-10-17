import XCTest
@testable import OYBC

/// `PlacementParams` — how a square reads its placement's goal / title
/// (TASK_WINDOW_REWORK slice 2a). Twin of `placementParams.test.ts`, pinned
/// by `placementParamsVectors.json`.
final class PlacementParamsVectorTests: XCTestCase {

    private struct MiniTask: Decodable {
        let type: String
        let title: String
        let action: String?
        let unit: String?
        let maxCount: CountValue?
        let countKind: String?
        let sharedCounterId: String?
    }
    private struct MiniChildTarget: Decodable { let childId: String; let target: CountValue }
    private struct MiniPlacement: Decodable {
        let targetOverride: CountValue?
        let targetKind: String?
        let childTargets: [MiniChildTarget]?
        let titleOverride: String?
    }
    private struct MiniSettings: Decodable {
        let counterName: String?
        let titleTemplateSingular: String?
        let titleTemplatePlural: String?
    }
    private struct Vector: Decodable {
        let name: String
        let task: MiniTask
        let placement: MiniPlacement?
        let settings: MiniSettings?
        let expectedGoal: CountValue?
        let expectedTitle: String
    }
    private struct Fixture: Decodable { let vectors: [Vector] }

    private func task(_ m: MiniTask) throws -> Task {
        let type = try XCTUnwrap(TaskType(rawValue: m.type))
        return Task(
            id: "t", userId: "u", title: m.title, description: nil, type: type,
            action: m.action, unit: m.unit, maxCount: m.maxCount,
            totalCompletions: 0, totalInstances: 0,
            createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z", version: 1, isDeleted: false,
            sharedCounterId: m.sharedCounterId,
            countKind: m.countKind.flatMap(CountKind.init(rawValue:))
        )
    }

    private func placement(_ m: MiniPlacement?) -> BoardTask? {
        guard let m else { return nil }
        return BoardTask(
            id: "bt", boardId: "b", taskId: "t", row: 0, col: 0, isCenter: false,
            targetOverride: m.targetOverride,
            targetKind: m.targetKind.flatMap(CountKind.init(rawValue:)),
            childTargets: m.childTargets?.map { PlacementChildTarget(childId: $0.childId, target: $0.target) },
            titleOverride: m.titleOverride,
            createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z", version: 1
        )
    }

    func testPlacementParams_matchTheSharedVectors() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "placementParamsVectors", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(fixture.vectors.count, 8)
        for v in fixture.vectors {
            let t = try task(v.task)
            let p = placement(v.placement)
            let settings = v.settings.map {
                CounterSettings.TitleSettings(counterName: $0.counterName, titleTemplateSingular: $0.titleTemplateSingular, titleTemplatePlural: $0.titleTemplatePlural)
            }
            XCTAssertEqual(PlacementParams.goal(for: t, placement: p), v.expectedGoal, v.name)
            XCTAssertEqual(PlacementParams.title(for: t, placement: p, settings: settings), v.expectedTitle, v.name)
            let adjusted = PlacementParams.apply(t, placement: p, settings: settings)
            XCTAssertEqual(adjusted.title, v.expectedTitle, v.name)
            if t.type == .counting { XCTAssertEqual(adjusted.maxCount, v.expectedGoal, v.name) }
        }
    }

    func testChildTargets_applyToTheNamedDirectChildOnly() throws {
        let targets = [PlacementChildTarget(childId: "a", target: 1)]
        var a = try task(MiniTask(type: "counting", title: "A", action: "Do", unit: "reps", maxCount: 10, countKind: nil, sharedCounterId: nil))
        a.id = "a"
        var b = a; b.id = "b"
        XCTAssertEqual(PlacementParams.withChildTarget(a, childTargets: targets).maxCount, 1)
        XCTAssertEqual(PlacementParams.withChildTarget(b, childTargets: targets).maxCount, 10)
    }
}
