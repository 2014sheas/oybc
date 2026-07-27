import XCTest
@testable import OYBC

/// Golden-parity tests for `BoardPlacement.placeBoard` — the Swift mirror of
/// `@oybc/bingo-core` `placeBoard` (packages/bingo-core/src/placement.ts).
///
/// The seeded LCG and every `expected` array below are BYTE-IDENTICAL to the
/// TypeScript suites (packages/bingo-core/tests/placement.test.ts and
/// packages/shared/tests/algorithms/recurringBoardTemplates.test.ts). That
/// cross-platform lockstep — same seed, same expected permutation — is the
/// proof that the wizard-preview and template-spawn placement paths produce
/// the same boards on iOS and web. See packages/bingo-core/MIRRORS.md.
final class BoardPlacementTests: XCTestCase {

    // MARK: - Shared seeded RNG

    /// Deterministic uniform [0,1) LCG (Numerical Recipes constants). Twin of
    /// packages/bingo-core/tests/seededRng.ts `makeSeededRng`.
    private func makeSeededRng(_ seed: UInt32) -> () -> Double {
        var state = seed
        return {
            state = state &* 1664525 &+ 1013904223
            return Double(state) / 4294967296.0
        }
    }

    private func makeTask(_ id: String) -> Task {
        Task(
            id: id,
            userId: "u1",
            title: "Task \(id)",
            type: .normal,
            operatorType: nil,
            threshold: nil,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            createdAt: "2026-05-01T00:00:00.000Z",
            updatedAt: "2026-05-01T00:00:00.000Z",
            version: 1,
            isDeleted: false
        )
    }

    /// Builds `count` tasks with ids `i0..i{count-1}`.
    private func items(_ count: Int) -> [Task] {
        (0..<count).map { makeTask("i\($0)") }
    }

    /// Maps a placement to a compact id/nil array for readable assertions.
    private func ids(_ placement: [Task?]) -> [String?] {
        placement.map { $0?.id }
    }

    // MARK: - Center handling (mirrors placement.test.ts)

    func testFreeCenterLeavesIndex12Null() {
        let placement = BoardPlacement.placeBoard(
            items: items(24), gridSize: 5, centerType: .free, randomize: false
        )
        XCTAssertEqual(placement.count, 25)
        XCTAssertNil(placement[12])
        XCTAssertEqual(placement[0]?.id, "i0")
        XCTAssertEqual(placement[11]?.id, "i11")
        XCTAssertEqual(placement[13]?.id, "i12") // skipped center
        XCTAssertEqual(placement.compactMap { $0 }.count, 24)
    }

    func testCustomFreeCenterAlsoNull() {
        let placement = BoardPlacement.placeBoard(
            items: items(24), gridSize: 5, centerType: .customFree, randomize: false
        )
        XCTAssertNil(placement[12])
    }

    func testChosenCenterPinnedAndNotDuplicated() {
        let placement = BoardPlacement.placeBoard(
            items: items(25), gridSize: 5, centerType: .chosen,
            chosenCenterId: "i7", randomize: false
        )
        XCTAssertEqual(placement[12]?.id, "i7")
        let others = placement.enumerated()
            .filter { $0.offset != 12 }
            .compactMap { $0.element?.id }
        XCTAssertFalse(others.contains("i7"))
        XCTAssertEqual(others.count, 24)
    }

    func testChosenCenterUnresolvableFallsBackToOrdinary() {
        let placement = BoardPlacement.placeBoard(
            items: items(25), gridSize: 5, centerType: .chosen,
            chosenCenterId: "does-not-exist", randomize: false
        )
        XCTAssertEqual(placement[12]?.id, "i12")
        XCTAssertEqual(placement.compactMap { $0 }.count, 25)
    }

    func testNoneCenterFillsAll25() {
        let placement = BoardPlacement.placeBoard(
            items: items(25), gridSize: 5, centerType: .none, randomize: false
        )
        XCTAssertEqual(placement.compactMap { $0 }.count, 25)
        XCTAssertEqual(placement[12]?.id, "i12")
    }

    func testEvenGridIgnoresCenterType() {
        let placement = BoardPlacement.placeBoard(
            items: items(16), gridSize: 4, centerType: .free,
            chosenCenterId: "i0", randomize: false
        )
        XCTAssertEqual(placement.count, 16)
        XCTAssertEqual(placement.compactMap { $0 }.count, 16)
        XCTAssertEqual(ids(placement), items(16).map { $0.id as String? })
    }

    // MARK: - Pool fit

    func testUnderfilledPoolTrailsNulls() {
        let placement = BoardPlacement.placeBoard(
            items: items(5), gridSize: 3, centerType: .none, randomize: false
        )
        XCTAssertEqual(ids(placement), ["i0", "i1", "i2", "i3", "i4", nil, nil, nil, nil])
    }

    func testOverfilledPoolDropsExtras() {
        let placement = BoardPlacement.placeBoard(
            items: items(30), gridSize: 5, centerType: .free, randomize: false
        )
        let placed = placement.compactMap { $0?.id }
        XCTAssertEqual(placed.count, 24)
        XCTAssertEqual(placed, (0..<24).map { "i\($0)" })
    }

    // MARK: - Deterministic shuffle (byte-identical to placement.test.ts)

    func testRandomizeFalsePreservesOrder() {
        let src = items(25)
        let placement = BoardPlacement.placeBoard(
            items: src, gridSize: 5, centerType: .none, randomize: false
        )
        XCTAssertEqual(ids(placement), src.map { $0.id as String? })
    }

    func testSeededShuffle3x3None_seed7() {
        let placement = BoardPlacement.placeBoard(
            items: items(9), gridSize: 3, centerType: .none,
            randomize: true, rng: makeSeededRng(7)
        )
        XCTAssertEqual(ids(placement),
            ["i8", "i6", "i1", "i3", "i0", "i5", "i4", "i7", "i2"])
    }

    func testSeededShuffle5x5Free_seed42() {
        let placement = BoardPlacement.placeBoard(
            items: items(24), gridSize: 5, centerType: .free,
            randomize: true, rng: makeSeededRng(42)
        )
        XCTAssertEqual(ids(placement), [
            "i3", "i15", "i17", "i16", "i20", "i10", "i21", "i1", "i18", "i5",
            "i9", "i19", nil, "i23", "i11", "i14", "i13", "i22", "i8", "i0",
            "i7", "i4", "i12", "i2", "i6",
        ])
    }

    func testSeededShuffle5x5Chosen_seed99() {
        let withCenter = items(24) + [makeTask("c")]
        let placement = BoardPlacement.placeBoard(
            items: withCenter, gridSize: 5, centerType: .chosen,
            chosenCenterId: "c", randomize: true, rng: makeSeededRng(99)
        )
        XCTAssertEqual(ids(placement), [
            "i14", "i15", "i17", "i11", "i2", "i19", "i8", "i9", "i16", "i18",
            "i1", "i3", "c", "i20", "i10", "i4", "i21", "i22", "i0", "i12",
            "i7", "i23", "i13", "i5", "i6",
        ])
    }

    // MARK: - Spawn golden matrix (byte-identical to recurringBoardTemplates.test.ts)
    //
    // Same seed (2026), same 48 cells, same expected arrays as the TS spawn
    // golden. Driven through BoardPlacement.placeBoard exactly as the
    // buildSpawnPlacement wrapper invokes it (items=pool, no chosenCenterId).

    private struct SpawnGolden {
        let size: Int
        let center: CenterSquareType
        let randomize: Bool
        let poolCount: Int
        let expected: [String?]
    }

    private let spawnGoldenSeed: UInt32 = 2026

    func testSpawnGoldenMatrix() {
        let goldens: [SpawnGolden] = [
        SpawnGolden(size: 3, center: .free, randomize: false, poolCount: 8,
                    expected: ["t0", "t1", "t2", "t3", nil, "t4", "t5", "t6", "t7"]),
        SpawnGolden(size: 3, center: .free, randomize: false, poolCount: 14,
                    expected: ["t0", "t1", "t2", "t3", nil, "t4", "t5", "t6", "t7"]),
        SpawnGolden(size: 3, center: .free, randomize: true, poolCount: 8,
                    expected: ["t5", "t4", "t1", "t2", nil, "t3", "t6", "t7", "t0"]),
        SpawnGolden(size: 3, center: .free, randomize: true, poolCount: 14,
                    expected: ["t2", "t1", "t3", "t9", nil, "t10", "t11", "t5", "t8"]),
        SpawnGolden(size: 3, center: .customFree, randomize: false, poolCount: 8,
                    expected: ["t0", "t1", "t2", "t3", nil, "t4", "t5", "t6", "t7"]),
        SpawnGolden(size: 3, center: .customFree, randomize: false, poolCount: 14,
                    expected: ["t0", "t1", "t2", "t3", nil, "t4", "t5", "t6", "t7"]),
        SpawnGolden(size: 3, center: .customFree, randomize: true, poolCount: 8,
                    expected: ["t5", "t4", "t1", "t2", nil, "t3", "t6", "t7", "t0"]),
        SpawnGolden(size: 3, center: .customFree, randomize: true, poolCount: 14,
                    expected: ["t2", "t1", "t3", "t9", nil, "t10", "t11", "t5", "t8"]),
        SpawnGolden(size: 3, center: .chosen, randomize: false, poolCount: 9,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"]),
        SpawnGolden(size: 3, center: .chosen, randomize: false, poolCount: 15,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"]),
        SpawnGolden(size: 3, center: .chosen, randomize: true, poolCount: 9,
                    expected: ["t6", "t2", "t4", "t1", "t5", "t3", "t7", "t8", "t0"]),
        SpawnGolden(size: 3, center: .chosen, randomize: true, poolCount: 15,
                    expected: ["t10", "t3", "t2", "t9", "t12", "t8", "t1", "t6", "t5"]),
        SpawnGolden(size: 3, center: .none, randomize: false, poolCount: 9,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"]),
        SpawnGolden(size: 3, center: .none, randomize: false, poolCount: 15,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"]),
        SpawnGolden(size: 3, center: .none, randomize: true, poolCount: 9,
                    expected: ["t6", "t2", "t4", "t1", "t5", "t3", "t7", "t8", "t0"]),
        SpawnGolden(size: 3, center: .none, randomize: true, poolCount: 15,
                    expected: ["t10", "t3", "t2", "t9", "t12", "t8", "t1", "t6", "t5"]),
        SpawnGolden(size: 4, center: .free, randomize: false, poolCount: 16,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"]),
        SpawnGolden(size: 4, center: .free, randomize: false, poolCount: 22,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"]),
        SpawnGolden(size: 4, center: .free, randomize: true, poolCount: 16,
                    expected: ["t3", "t11", "t4", "t2", "t10", "t13", "t12", "t1", "t9", "t6", "t5", "t7", "t8", "t14", "t15", "t0"]),
        SpawnGolden(size: 4, center: .free, randomize: true, poolCount: 22,
                    expected: ["t16", "t3", "t15", "t10", "t14", "t6", "t5", "t4", "t13", "t7", "t1", "t19", "t18", "t2", "t17", "t9"]),
        SpawnGolden(size: 4, center: .customFree, randomize: false, poolCount: 16,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"]),
        SpawnGolden(size: 4, center: .customFree, randomize: false, poolCount: 22,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"]),
        SpawnGolden(size: 4, center: .customFree, randomize: true, poolCount: 16,
                    expected: ["t3", "t11", "t4", "t2", "t10", "t13", "t12", "t1", "t9", "t6", "t5", "t7", "t8", "t14", "t15", "t0"]),
        SpawnGolden(size: 4, center: .customFree, randomize: true, poolCount: 22,
                    expected: ["t16", "t3", "t15", "t10", "t14", "t6", "t5", "t4", "t13", "t7", "t1", "t19", "t18", "t2", "t17", "t9"]),
        SpawnGolden(size: 4, center: .chosen, randomize: false, poolCount: 16,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"]),
        SpawnGolden(size: 4, center: .chosen, randomize: false, poolCount: 22,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"]),
        SpawnGolden(size: 4, center: .chosen, randomize: true, poolCount: 16,
                    expected: ["t3", "t11", "t4", "t2", "t10", "t13", "t12", "t1", "t9", "t6", "t5", "t7", "t8", "t14", "t15", "t0"]),
        SpawnGolden(size: 4, center: .chosen, randomize: true, poolCount: 22,
                    expected: ["t16", "t3", "t15", "t10", "t14", "t6", "t5", "t4", "t13", "t7", "t1", "t19", "t18", "t2", "t17", "t9"]),
        SpawnGolden(size: 4, center: .none, randomize: false, poolCount: 16,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"]),
        SpawnGolden(size: 4, center: .none, randomize: false, poolCount: 22,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"]),
        SpawnGolden(size: 4, center: .none, randomize: true, poolCount: 16,
                    expected: ["t3", "t11", "t4", "t2", "t10", "t13", "t12", "t1", "t9", "t6", "t5", "t7", "t8", "t14", "t15", "t0"]),
        SpawnGolden(size: 4, center: .none, randomize: true, poolCount: 22,
                    expected: ["t16", "t3", "t15", "t10", "t14", "t6", "t5", "t4", "t13", "t7", "t1", "t19", "t18", "t2", "t17", "t9"]),
        SpawnGolden(size: 5, center: .free, randomize: false, poolCount: 24,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", nil, "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23"]),
        SpawnGolden(size: 5, center: .free, randomize: false, poolCount: 30,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", nil, "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23"]),
        SpawnGolden(size: 5, center: .free, randomize: true, poolCount: 24,
                    expected: ["t4", "t6", "t3", "t10", "t18", "t22", "t16", "t17", "t7", "t5", "t19", "t8", nil, "t15", "t21", "t14", "t2", "t20", "t11", "t9", "t12", "t13", "t23", "t1", "t0"]),
        SpawnGolden(size: 5, center: .free, randomize: true, poolCount: 30,
                    expected: ["t25", "t15", "t8", "t19", "t23", "t5", "t11", "t10", "t7", "t6", "t2", "t18", nil, "t27", "t22", "t24", "t9", "t4", "t13", "t21", "t29", "t20", "t3", "t26", "t14"]),
        SpawnGolden(size: 5, center: .customFree, randomize: false, poolCount: 24,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", nil, "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23"]),
        SpawnGolden(size: 5, center: .customFree, randomize: false, poolCount: 30,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", nil, "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23"]),
        SpawnGolden(size: 5, center: .customFree, randomize: true, poolCount: 24,
                    expected: ["t4", "t6", "t3", "t10", "t18", "t22", "t16", "t17", "t7", "t5", "t19", "t8", nil, "t15", "t21", "t14", "t2", "t20", "t11", "t9", "t12", "t13", "t23", "t1", "t0"]),
        SpawnGolden(size: 5, center: .customFree, randomize: true, poolCount: 30,
                    expected: ["t25", "t15", "t8", "t19", "t23", "t5", "t11", "t10", "t7", "t6", "t2", "t18", nil, "t27", "t22", "t24", "t9", "t4", "t13", "t21", "t29", "t20", "t3", "t26", "t14"]),
        SpawnGolden(size: 5, center: .chosen, randomize: false, poolCount: 25,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23", "t24"]),
        SpawnGolden(size: 5, center: .chosen, randomize: false, poolCount: 31,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23", "t24"]),
        SpawnGolden(size: 5, center: .chosen, randomize: true, poolCount: 25,
                    expected: ["t10", "t5", "t7", "t4", "t18", "t23", "t17", "t21", "t12", "t8", "t6", "t3", "t19", "t16", "t22", "t15", "t2", "t20", "t11", "t9", "t13", "t14", "t24", "t1", "t0"]),
        SpawnGolden(size: 5, center: .chosen, randomize: true, poolCount: 31,
                    expected: ["t11", "t16", "t20", "t5", "t24", "t9", "t6", "t25", "t2", "t8", "t7", "t19", "t26", "t28", "t14", "t23", "t10", "t4", "t13", "t22", "t30", "t21", "t3", "t27", "t15"]),
        SpawnGolden(size: 5, center: .none, randomize: false, poolCount: 25,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23", "t24"]),
        SpawnGolden(size: 5, center: .none, randomize: false, poolCount: 31,
                    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23", "t24"]),
        SpawnGolden(size: 5, center: .none, randomize: true, poolCount: 25,
                    expected: ["t10", "t5", "t7", "t4", "t18", "t23", "t17", "t21", "t12", "t8", "t6", "t3", "t19", "t16", "t22", "t15", "t2", "t20", "t11", "t9", "t13", "t14", "t24", "t1", "t0"]),
        SpawnGolden(size: 5, center: .none, randomize: true, poolCount: 31,
                    expected: ["t11", "t16", "t20", "t5", "t24", "t9", "t6", "t25", "t2", "t8", "t7", "t19", "t26", "t28", "t14", "t23", "t10", "t4", "t13", "t22", "t30", "t21", "t3", "t27", "t15"]),
        ]
        for g in goldens {
            let pool = (0..<g.poolCount).map { makeTask("t\($0)") }
            let placement = BoardPlacement.placeBoard(
                items: pool,
                gridSize: g.size,
                centerType: g.center,
                randomize: g.randomize,
                rng: makeSeededRng(spawnGoldenSeed)
            )
            XCTAssertEqual(
                placement.map { $0?.id },
                g.expected,
                "\(g.size)x\(g.size) \(g.center) randomize=\(g.randomize) pool=\(g.poolCount)"
            )
        }
    }

    // MARK: - Board-integrity PR-5 (Item 1): cross-platform placement vectors
    //
    // `placeBoard` / `fisherYatesShuffle` / `centerSquare` were the last
    // unpinned kernels in the board-integrity audit — every assertion above
    // (and its TS twin, packages/bingo-core/tests/placement.test.ts) is a
    // HAND-COPIED `expected` array, so a silent drift between TS and Swift
    // (or a regression within one platform) could slip through if both
    // sides' hand-copies drifted together.
    //
    // `Fixtures/placementVectors.json` (synced from
    // packages/bingo-core/tests/fixtures/placementVectors.json via
    // `pnpm --filter @oybc/shared run gen:sync-fixtures`) pins those same
    // seeded-LCG cases as ONE canonical, cross-platform-shared source. This
    // test drives `BoardPlacement.placeBoard` from it directly — the SAME
    // file also drives packages/bingo-core/tests/placementVectors.test.ts.
    // Both suites passing is the proof the two implementations agree, not
    // just that each hand-copy matches itself. The hand-copied tests above
    // stay as extra coverage (broader case shapes than the fixture pins).
    //
    // Every `expected` value was generated by running the CURRENT `placeBoard`
    // TS implementation and cross-checked against the pre-existing hand-copied
    // arrays in both `placement.test.ts` and this file — all matched, so
    // there was no live drift to fix when the fixture was created.

    private struct PlaceBoardVector: Decodable {
        let name: String
        let itemIds: [String]
        let gridSize: Int
        let centerType: CenterSquareType
        let chosenCenterId: String?
        let randomize: Bool
        let seed: Int?
        let expected: [String?]
    }

    private struct PlacementVectorsFixture: Decodable {
        let placeBoardVectors: [PlaceBoardVector]
    }

    private func loadPlacementVectorsFixture() throws -> PlacementVectorsFixture {
        guard let url = Bundle(for: BoardPlacementTests.self).url(
            forResource: "placementVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "placementVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PlacementVectorsFixture.self, from: data)
    }

    func testPlacementVectorsFixture_matchesPlaceBoard() throws {
        let fixture = try loadPlacementVectorsFixture()
        XCTAssertFalse(fixture.placeBoardVectors.isEmpty)
        for v in fixture.placeBoardVectors {
            let pool = v.itemIds.map { makeTask($0) }
            let placement: [Task?]
            if let seed = v.seed {
                placement = BoardPlacement.placeBoard(
                    items: pool,
                    gridSize: v.gridSize,
                    centerType: v.centerType,
                    chosenCenterId: v.chosenCenterId,
                    randomize: v.randomize,
                    rng: makeSeededRng(UInt32(seed))
                )
            } else {
                placement = BoardPlacement.placeBoard(
                    items: pool,
                    gridSize: v.gridSize,
                    centerType: v.centerType,
                    chosenCenterId: v.chosenCenterId,
                    randomize: v.randomize
                )
            }
            XCTAssertEqual(ids(placement), v.expected, "Vector '\(v.name)'")
        }
    }
}
