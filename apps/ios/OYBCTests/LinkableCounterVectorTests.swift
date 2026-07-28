import XCTest
@testable import OYBC

/// Cross-platform linkable-counter match enforcement (workstream C1 /
/// issue #267).
///
/// Runs the hand-authored fixture (`packages/shared/tests/fixtures/linkableCounterVectors.json`)
/// through iOS's `findLinkableCounter` in `Helpers/LinkableCounter.swift`.
/// The SAME fixture is exercised on the shared/web side by
/// `packages/shared/tests/algorithms/linkableCounter.test.ts` against
/// `@oybc/shared`'s `linkableCounter.ts`. Both suites passing against the
/// same vectors is what proves the two hand-mirrored implementations agree,
/// not just an audit claim.
final class LinkableCounterVectorTests: XCTestCase {

    private struct MiniTask: Decodable {
        let id: String
        let action: String?
        let unit: String?
        let currentCount: Int?
        let sharedCounterId: String?
        let isDeleted: Bool?
        let type: String?
    }

    private struct ExpectedCounter: Decodable {
        let counterId: String
        let name: String
        let lifetime: Int
        let memberCount: Int
    }

    private struct Vector: Decodable {
        let name: String
        let action: String
        let unit: String
        let excludeTaskId: String?
        let tasks: [MiniTask]
        let expected: ExpectedCounter?
    }

    private struct Fixture: Decodable {
        let vectors: [Vector]
    }

    private let ts = "2026-07-01T12:00:00.000Z"

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: LinkableCounterVectorTests.self).url(
            forResource: "linkableCounterVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "linkableCounterVectors.json not found in test bundle — check project.yml's " +
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
            userId: "u1",
            title: "Task \(m.id)",
            type: TaskType(rawValue: m.type ?? "counting") ?? .counting,
            action: m.action,
            unit: m.unit,
            totalCompletions: 0,
            totalInstances: 0,
            currentCount: m.currentCount,
            createdAt: ts,
            updatedAt: ts,
            version: 1,
            isDeleted: m.isDeleted ?? false,
            sharedCounterId: m.sharedCounterId
        )
    }

    func testFindLinkableCounterVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.vectors.isEmpty)
        for v in fixture.vectors {
            let tasks = v.tasks.map(toTask)
            let result = findLinkableCounter(action: v.action, unit: v.unit, excludeTaskId: v.excludeTaskId, tasks: tasks)
            if let expected = v.expected {
                XCTAssertNotNil(result, "Vector '\(v.name)' expected a match")
                XCTAssertEqual(result?.counterId, expected.counterId, "Vector '\(v.name)' counterId")
                XCTAssertEqual(result?.name, expected.name, "Vector '\(v.name)' name")
                XCTAssertEqual(result?.lifetime, expected.lifetime, "Vector '\(v.name)' lifetime")
                XCTAssertEqual(result?.memberCount, expected.memberCount, "Vector '\(v.name)' memberCount")
            } else {
                XCTAssertNil(result, "Vector '\(v.name)' expected nil")
            }
        }
    }
}
