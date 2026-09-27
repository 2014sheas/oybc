import XCTest
@testable import OYBC

/// Board Edit redesign slice 4 (D8 / owner ruling R3): runs the shared
/// `achievementWatcherVectors.json` fixture through the Swift
/// `findWatcherTaskIds` (Helpers/AchievementWatchers.swift). The SAME fixture
/// drives `packages/shared/tests/algorithms/achievementWatchers.test.ts`.
final class AchievementWatcherVectorTests: XCTestCase {

    private struct VectorTask: Decodable {
        let id: String
        let type: String
        let isDeleted: Bool
        let referencedBoardId: String?
        let referencedTemplateId: String?
    }

    private struct VectorBoard: Decodable {
        let id: String
        let spawnedFromTemplateId: String?
    }

    private struct Vector: Decodable {
        let name: String
        let tasks: [VectorTask]
        let changedBoards: [VectorBoard]
        let expectedTaskIds: [String]
    }

    private struct Fixture: Decodable { let vectors: [Vector] }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: AchievementWatcherVectorTests.self).url(
            forResource: "achievementWatcherVectors", withExtension: "json"
        ) else {
            XCTFail("achievementWatcherVectors.json not found in test bundle — re-run " +
                    "`pnpm --filter @oybc/shared run gen:sync-fixtures` and xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    func testWatcherVectors() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.vectors.count, 6)
        for v in fixture.vectors {
            let candidates = try v.tasks.map { t in
                WatcherCandidate(
                    id: t.id,
                    type: try XCTUnwrap(TaskType(rawValue: t.type), v.name),
                    isDeleted: t.isDeleted,
                    referencedBoardId: t.referencedBoardId,
                    referencedTemplateId: t.referencedTemplateId
                )
            }
            let result = findWatcherTaskIds(
                candidates: candidates,
                changedBoardIds: Set(v.changedBoards.map(\.id)),
                changedTemplateIds: Set(v.changedBoards.compactMap(\.spawnedFromTemplateId))
            )
            XCTAssertEqual(result, v.expectedTaskIds, "Vector '\(v.name)'")
        }
    }

    func testBoardWithoutTemplateProvenanceCannotMatchTemplateWatcher() {
        let watcher = WatcherCandidate(
            id: "w", type: .achievement, isDeleted: false,
            referencedBoardId: nil, referencedTemplateId: "tpl"
        )
        XCTAssertEqual(
            findWatcherTaskIds(candidates: [watcher], changedBoardIds: ["b"], changedTemplateIds: []),
            []
        )
    }
}
