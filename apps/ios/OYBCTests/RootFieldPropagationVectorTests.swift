import XCTest
@testable import OYBC

/// Board-scoped task edits PR 3 (docs/BOARD_SCOPED_TASK_EDITS.md §6): pins
/// `RootFieldPropagation.plan` against the shared fixture
/// (`Fixtures/rootFieldPropagationVectors.json`, byte-identical to
/// `packages/shared/tests/fixtures/rootFieldPropagationVectors.json`) — the
/// SAME vectors the TS `rootFieldPropagation.test.ts` runs.
final class RootFieldPropagationVectorTests: XCTestCase {

    private struct FixRoot: Decodable {
        let id: String
        let title: String
        let action: String?
        let unit: String?
        let maxCount: Double?
        let countKind: String?
        let sharedCounterId: String?
        let counterName: String?
        let titleTemplateSingular: String?
        let titleTemplatePlural: String?
    }

    /// `sharedCounterId` is tri-state in the fixture: absent → "root", null → unlinked.
    private struct FixCopy: Decodable {
        let id: String
        let title: String
        let type: String?
        let action: String?
        let unit: String?
        let maxCount: Double?
        let countKind: String?
        let sharedCounterId: String??
        let startDate: String?
        let endDate: String?
        let createdInWizard: Bool?
        let isDeleted: Bool?
        let onSealedBoard: Bool?

        enum CodingKeys: String, CodingKey {
            case id, title, type, action, unit, maxCount, countKind, sharedCounterId
            case startDate, endDate, createdInWizard, isDeleted, onSealedBoard
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            action = try c.decodeIfPresent(String.self, forKey: .action)
            unit = try c.decodeIfPresent(String.self, forKey: .unit)
            maxCount = try c.decodeIfPresent(Double.self, forKey: .maxCount)
            countKind = try c.decodeIfPresent(String.self, forKey: .countKind)
            sharedCounterId = c.contains(.sharedCounterId)
                ? .some(try c.decodeIfPresent(String.self, forKey: .sharedCounterId))
                : .none
            startDate = try c.decodeIfPresent(String.self, forKey: .startDate)
            endDate = try c.decodeIfPresent(String.self, forKey: .endDate)
            createdInWizard = try c.decodeIfPresent(Bool.self, forKey: .createdInWizard)
            isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted)
            onSealedBoard = try c.decodeIfPresent(Bool.self, forKey: .onSealedBoard)
        }
    }

    /// The three settings keys are tri-state: absent → unchanged, null → cleared.
    private struct FixPatch: Decodable {
        let title: String?
        let action: String?
        let unit: String?
        let maxCount: Double?
        let countKind: String?
        let counterName: String??
        let titleTemplateSingular: String??
        let titleTemplatePlural: String??

        enum CodingKeys: String, CodingKey {
            case title, action, unit, maxCount, countKind, counterName, titleTemplateSingular, titleTemplatePlural
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            action = try c.decodeIfPresent(String.self, forKey: .action)
            unit = try c.decodeIfPresent(String.self, forKey: .unit)
            maxCount = try c.decodeIfPresent(Double.self, forKey: .maxCount)
            countKind = try c.decodeIfPresent(String.self, forKey: .countKind)
            func tri(_ k: CodingKeys) throws -> String?? {
                c.contains(k) ? .some(try c.decodeIfPresent(String.self, forKey: k)) : .none
            }
            counterName = try tri(.counterName)
            titleTemplateSingular = try tri(.titleTemplateSingular)
            titleTemplatePlural = try tri(.titleTemplatePlural)
        }

        /// The root's post-edit name + templates, or nil when the patch touches none.
        func settings(root: Task) -> CounterSettings.TitleSettings? {
            guard counterName != nil || titleTemplateSingular != nil || titleTemplatePlural != nil else { return nil }
            return CounterSettings.TitleSettings(
                counterName: counterName ?? root.counterName,
                titleTemplateSingular: titleTemplateSingular ?? root.titleTemplateSingular,
                titleTemplatePlural: titleTemplatePlural ?? root.titleTemplatePlural
            )
        }
    }

    private struct FixFieldPatch: Decodable {
        let title: String?
        let action: String?
        let unit: String?
    }

    private struct FixEntry: Decodable {
        let copyId: String
        let patch: FixFieldPatch
    }

    private struct FixVector: Decodable {
        let name: String
        let root: FixRoot
        let patch: FixPatch
        let copies: [FixCopy]
        let expected: [FixEntry]
    }

    private struct Fixture: Decodable {
        let now: String
        let vectors: [FixVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: RootFieldPropagationVectorTests.self).url(
            forResource: "rootFieldPropagationVectors",
            withExtension: "json"
        ) else {
            XCTFail("rootFieldPropagationVectors.json not found in test bundle — re-run xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    private static let old = "2026-01-01T00:00:00.000Z"

    private func makeTask(
        id: String, title: String, type: TaskType, action: String?, unit: String?, maxCount: Double?,
        countKind: String?, sharedCounterId: String?, startDate: String? = nil, endDate: String? = nil,
        createdInWizard: Bool = false, isDeleted: Bool = false
    ) throws -> Task {
        let kind = try countKind.map { try XCTUnwrap(CountKind(rawValue: $0), "unknown kind \($0)") }
        return Task(
            id: id, userId: "u1", title: title, type: type, action: action, unit: unit, maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0, createdAt: Self.old, updatedAt: Self.old, version: 1,
            isDeleted: isDeleted, startDate: startDate, endDate: endDate, sharedCounterId: sharedCounterId,
            createdInWizard: createdInWizard, countKind: kind
        )
    }

    func test_coversTheFixture() throws {
        XCTAssertEqual(try loadFixture().vectors.count, 17)
    }

    func test_vectors() throws {
        let fixture = try loadFixture()
        for v in fixture.vectors {
            var root = try makeTask(
                id: v.root.id, title: v.root.title, type: .counting, action: v.root.action, unit: v.root.unit,
                maxCount: v.root.maxCount, countKind: v.root.countKind, sharedCounterId: v.root.sharedCounterId
            )
            root.counterName = v.root.counterName
            root.titleTemplateSingular = v.root.titleTemplateSingular
            root.titleTemplatePlural = v.root.titleTemplatePlural
            let copies = try v.copies.map { c -> RootFieldPropagation.Copy in
                let type = try XCTUnwrap(TaskType(rawValue: c.type ?? "counting"), "unknown type in \(v.name)")
                let linked: String? = switch c.sharedCounterId {
                case .none: "root"
                case .some(let value): value
                }
                let task = try makeTask(
                    id: c.id, title: c.title, type: type, action: c.action, unit: c.unit, maxCount: c.maxCount,
                    countKind: c.countKind, sharedCounterId: linked, startDate: c.startDate, endDate: c.endDate,
                    createdInWizard: c.createdInWizard ?? true, isDeleted: c.isDeleted ?? false
                )
                return RootFieldPropagation.Copy(task: task, onSealedBoard: c.onSealedBoard ?? false)
            }
            let patch = RootFieldPropagation.EditPatch(
                title: v.patch.title, action: v.patch.action, unit: v.patch.unit, maxCount: v.patch.maxCount,
                countKind: try v.patch.countKind.map { try XCTUnwrap(CountKind(rawValue: $0)) },
                settings: v.patch.settings(root: root)
            )
            let out = RootFieldPropagation.plan(root: root, patch: patch, copies: copies, now: fixture.now)
            let expected = v.expected.map {
                RootFieldPropagation.Entry(
                    copyId: $0.copyId,
                    patch: RootFieldPropagation.FieldPatch(title: $0.patch.title, action: $0.patch.action, unit: $0.patch.unit)
                )
            }
            XCTAssertEqual(out, expected, v.name)
        }
    }
}
