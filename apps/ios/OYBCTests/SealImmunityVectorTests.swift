import XCTest
@testable import OYBC

/// Board Edit redesign slice 4 (D10 / owner ruling R2): runs the
/// `sealImmunity` and `closedBoardLateLogs` sections of the shared
/// `sealReDerivationVectors.json` fixture through the Swift
/// `isEventSealImmune` (Helpers/TaskEvents.swift) and
/// `selectClosedBoardLateLogs` (Helpers/LastCounterLogEntry.swift). The SAME
/// vectors drive `packages/shared/tests/algorithms/sealing.test.ts` and
/// `lastCounterLogEntry.test.ts`.
final class SealImmunityVectorTests: XCTestCase {

    private struct Window: Decodable {
        let startDate: String
        let endDate: String?
        let sealedAt: String
    }

    private struct ImmunityEvent: Decodable {
        let occurredAt: String
        let createdAt: String
        let boardId: String?
    }

    private struct ImmunityVector: Decodable {
        let name: String
        let windows: [Window]
        let event: ImmunityEvent
        let expectedImmune: Bool
    }

    private struct LateLogBoard: Decodable {
        let id: String
        let endDate: String?
        let sealedAt: String?
    }

    private struct LateLogVector: Decodable {
        let name: String
        let board: LateLogBoard
        let taskId: String
        let events: [TaskEvent]
        let expectedIds: [String]
    }

    private struct Fixture: Decodable {
        let sealImmunity: [ImmunityVector]
        let closedBoardLateLogs: [LateLogVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: SealImmunityVectorTests.self).url(
            forResource: "sealReDerivationVectors", withExtension: "json"
        ) else {
            XCTFail("sealReDerivationVectors.json not found in test bundle — re-run " +
                    "`pnpm --filter @oybc/shared run gen:sync-fixtures` and xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    func testSealImmunityVectors() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.sealImmunity.count, 8)
        for v in fixture.sealImmunity {
            let windows = buildSealImmuneWindows(
                sealedBoards: v.windows.map { ($0.startDate, $0.endDate, $0.sealedAt) }
            )
            let immune = isEventSealImmune(
                occurredAt: v.event.occurredAt,
                createdAt: v.event.createdAt,
                boardId: v.event.boardId,
                windows: windows
            )
            XCTAssertEqual(immune, v.expectedImmune, "Vector '\(v.name)'")
        }
    }

    func testClosedBoardLateLogVectors() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.closedBoardLateLogs.count, 5)
        for v in fixture.closedBoardLateLogs {
            let picked = selectClosedBoardLateLogs(
                events: v.events,
                boardId: v.board.id,
                endDate: v.board.endDate,
                sealedAt: v.board.sealedAt,
                taskId: v.taskId
            )
            XCTAssertEqual(picked.map(\.id), v.expectedIds, "Vector '\(v.name)'")
        }
    }

    /// A late log's `occurredAt` is the local-ISO `endDate` re-encoded UTC
    /// (`lateLogOccurredAt`); the selector must match it by instant.
    func testMatchesUTCStampAgainstLocalISOEndDate() throws {
        let endDate = "2026-09-15T23:59:59.999"
        let stamp = DateFormatting.utcISOString(try XCTUnwrap(DateFormatting.parseISO(endDate)))
        let late = TaskEvent(
            id: "late", userId: "u", taskId: "t", kind: .increment, delta: 1,
            occurredAt: stamp, boardId: "b",
            createdAt: "2026-09-18T10:00:00.000Z", updatedAt: "2026-09-18T10:00:00.000Z",
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
        let picked = selectClosedBoardLateLogs(
            events: [late], boardId: "b", endDate: endDate,
            sealedAt: "2026-09-17T00:00:00.000Z", taskId: "t"
        )
        XCTAssertEqual(picked.map(\.id), ["late"])
    }

    func testEventOverloadAgreesWithFieldForm() throws {
        let windows = buildSealImmuneWindows(sealedBoards: [
            ("2026-09-15T00:00:00.000Z", "2026-09-15T23:59:59.999Z", "2026-09-17T00:00:00.000Z"),
        ])
        let late = TaskEvent(
            id: "e", userId: "u", taskId: "t", kind: .completion, delta: nil,
            occurredAt: "2026-09-15T23:59:59.999Z", boardId: "b",
            createdAt: "2026-09-18T10:00:00.000Z", updatedAt: "2026-09-18T10:00:00.000Z",
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
        XCTAssertFalse(isEventSealImmune(late, windows: windows))
        var mint = late
        mint.boardId = nil // a heal / backfill mint (no board) stays immune
        XCTAssertTrue(isEventSealImmune(mint, windows: windows))
    }
}
