import XCTest
@testable import OYBC

/// Cross-platform compound-evaluation enforcement (workstream C1 / issue #267).
///
/// Runs the hand-authored fixture (`packages/shared/tests/fixtures/compoundEvaluationVectors.json`)
/// through iOS's `CompoundEvaluation.evaluate` in
/// `Services/CompoundEvaluation.swift`. The SAME fixture is exercised on the
/// shared/web side by `packages/shared/tests/algorithms/compoundEvaluation.test.ts`
/// against `@oybc/shared`'s `compoundEvaluation.ts`. Both suites passing
/// against the same vectors is what proves the two hand-mirrored
/// implementations agree, not just an audit claim.
final class CompoundEvaluationVectorTests: XCTestCase {

    private struct MiniTask: Decodable {
        let id: String
        let type: String?
        let operatorField: String?
        let threshold: Int?
        let isCompleted: Bool?
        let isDeleted: Bool?

        enum CodingKeys: String, CodingKey {
            case id, type, threshold, isCompleted, isDeleted
            case operatorField = "operator"
        }
    }

    private struct MiniChild: Decodable {
        let compoundTaskId: String
        let childTaskId: String
        let isDeleted: Bool?
    }

    private struct Vector: Decodable {
        let name: String
        let compoundId: String
        let tasks: [MiniTask]
        let children: [MiniChild]
        let expected: Bool
    }

    private struct Fixture: Decodable {
        let vectors: [Vector]
    }

    private let ts = "2026-04-23T00:00:00.000Z"

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: CompoundEvaluationVectorTests.self).url(
            forResource: "compoundEvaluationVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "compoundEvaluationVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func toTask(_ m: MiniTask) -> Task {
        Task(
            id: m.id,
            userId: "u",
            title: m.id,
            type: TaskType(rawValue: m.type ?? "normal") ?? .normal,
            operatorType: m.operatorField.flatMap { OperatorType(rawValue: $0) },
            threshold: m.threshold,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: m.isCompleted ?? false,
            createdAt: ts,
            updatedAt: ts,
            version: 1,
            isDeleted: m.isDeleted ?? false
        )
    }

    private func toChild(_ m: MiniChild, _ idx: Int) -> CompoundChild {
        CompoundChild(
            id: "\(m.compoundTaskId)-\(m.childTaskId)-\(idx)",
            compoundTaskId: m.compoundTaskId,
            childTaskId: m.childTaskId,
            childIndex: idx,
            createdAt: ts,
            updatedAt: ts,
            version: 1,
            isDeleted: m.isDeleted ?? false
        )
    }

    func testEvaluateCompoundVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.vectors.isEmpty)
        for v in fixture.vectors {
            var taskById: [String: Task] = [:]
            for t in v.tasks { taskById[t.id] = toTask(t) }

            var childrenByCompound: [String: [CompoundChild]] = [:]
            for (idx, c) in v.children.enumerated() {
                childrenByCompound[c.compoundTaskId, default: []].append(toChild(c, idx))
            }

            guard let compound = taskById[v.compoundId] else {
                XCTFail("Vector '\(v.name)' compoundId '\(v.compoundId)' not found in tasks")
                continue
            }
            let result = CompoundEvaluation.evaluate(
                compound: compound, childrenByCompound: childrenByCompound, taskById: taskById
            )
            XCTAssertEqual(result, v.expected, "Vector '\(v.name)' mismatch")
        }
    }
}
