import XCTest
@testable import OYBC

/// Cross-platform vector pins for `TaskTitle` (Swift twin of
/// `packages/shared/src/algorithms/taskTitle.ts`), driven by the checked-in
/// copy of `taskTitleVectors.json` — the same fixture
/// `packages/shared/tests/algorithms/taskTitleVectors.test.ts` runs. See the
/// fixture's `_note` for the trim / case decisions behind
/// `isAutoCounterTitle` / `counterCopyTitle` (custom-counter-title fix,
/// 2026-10-06).
final class TaskTitleVectorTests: XCTestCase {

    private struct GenerateVector: Decodable {
        let name: String
        let action: String
        let maxCount: Int?
        let unit: String
        let providedTitle: String?
        let expected: String
    }

    private struct IsAutoVector: Decodable {
        let name: String
        let title: String
        let action: String
        let maxCount: Int?
        let unit: String
        let expected: Bool
    }

    private struct MemberFields: Decodable {
        let title: String
        let action: String?
        let unit: String?
        let maxCount: Int?
    }

    private struct CopyVector: Decodable {
        let name: String
        let member: MemberFields
        let newMaxCount: Int
        let expected: String
    }

    private struct Fixture: Decodable {
        let generateCounterTaskTitle: [GenerateVector]
        let isAutoCounterTitle: [IsAutoVector]
        let counterCopyTitle: [CopyVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: TaskTitleVectorTests.self).url(
            forResource: "taskTitleVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "taskTitleVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    private static let isoStamp = "2026-10-06T00:00:00.000Z"

    private func makeMember(_ m: MemberFields) -> Task {
        Task(
            id: "m", userId: "u1", title: m.title, type: .counting,
            action: m.action, unit: m.unit, maxCount: m.maxCount,
            totalCompletions: 0, totalInstances: 0,
            createdAt: Self.isoStamp, updatedAt: Self.isoStamp, version: 1, isDeleted: false
        )
    }

    func testGenerateCounterTaskTitle() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.generateCounterTaskTitle.count, 4)
        for v in fixture.generateCounterTaskTitle {
            XCTAssertEqual(
                TaskTitle.generateCounterTaskTitle(
                    action: v.action, maxCount: v.maxCount, unit: v.unit, providedTitle: v.providedTitle
                ),
                v.expected,
                v.name
            )
        }
    }

    func testIsAutoCounterTitle() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(Set(fixture.isAutoCounterTitle.map(\.expected)), [true, false], "pins both outcomes")
        for v in fixture.isAutoCounterTitle {
            XCTAssertEqual(
                TaskTitle.isAutoCounterTitle(title: v.title, action: v.action, maxCount: v.maxCount, unit: v.unit),
                v.expected,
                v.name
            )
        }
    }

    func testCounterCopyTitle() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.counterCopyTitle.count, 4)
        for v in fixture.counterCopyTitle {
            XCTAssertEqual(
                TaskTitle.counterCopyTitle(member: makeMember(v.member), newMaxCount: v.newMaxCount),
                v.expected,
                v.name
            )
        }
    }
}
