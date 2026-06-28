import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `RearrangeGrid` — the Phase 3 rearrange interaction grid.
///
/// Strategy: snapshot `RearrangeGrid` directly as a static leaf (no database, no auth)
/// with `rearrange = false` (display-only, jiggle off) for deterministic output.
/// The drag / tap / jiggle interactions are exercised manually per the iOS testing
/// convention (relay steps to user; no sim-driving from agents).
///
/// Two grid configurations are covered:
///   - 3×3 with 7 task cells + 1 FREE center + 1 empty slot
///   - 5×5 with 22 task cells + 1 FREE center + 2 empty slots
///
/// Light + dark variants for both.
final class RearrangeGridSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - 3×3 display-only (light)

    func testGrid3x3Light() {
        let view = makeGridView(gridSize: 3, rearrange: false)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 440)),
            record: recordMode
        )
    }

    // MARK: - 3×3 display-only (dark)

    func testGrid3x3Dark() {
        let view = makeGridView(gridSize: 3, rearrange: false)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 440),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - 5×5 display-only (light)

    func testGrid5x5Light() {
        let view = makeGridView(gridSize: 5, rearrange: false)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 600)),
            record: recordMode
        )
    }

    // MARK: - 5×5 display-only (dark)

    func testGrid5x5Dark() {
        let view = makeGridView(gridSize: 5, rearrange: false)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 600),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - 3×3 rearrange mode — static frame (no jiggle in snapshot; jiggle off via rearrange: false)

    func testGrid3x3RearrangeStaticLight() {
        // rearrange: false here for snapshot determinism — jiggle and drag are
        // exercised manually. The static visual shows the correct cell styling.
        let view = makeGridView(gridSize: 3, rearrange: false, showCompletedCell: true)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 440)),
            record: recordMode
        )
    }

    func testGrid3x3RearrangeStaticDark() {
        let view = makeGridView(gridSize: 3, rearrange: false, showCompletedCell: true)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 440),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - View builders

    /// Builds a `RearrangeGrid` wrapped in a Riso paper background for snapshotting.
    ///
    /// - Parameters:
    ///   - gridSize: 3 or 5.
    ///   - rearrange: When `false` the grid is display-only (deterministic for snapshots).
    ///   - showCompletedCell: When `true`, the first task cell is marked completed (green fill).
    private func makeGridView(
        gridSize: Int,
        rearrange: Bool,
        showCompletedCell: Bool = false
    ) -> some View {
        let (cells, taskMap) = makeFixtures(gridSize: gridSize, showCompletedCell: showCompletedCell)

        return ZStack {
            Color.risoPaper.ignoresSafeArea()
            VStack(spacing: 0) {
                RearrangeGrid(
                    cells: cells,
                    gridSize: gridSize,
                    taskMap: taskMap,
                    centerSquareType: .free,
                    centerCustomName: "",
                    rearrange: rearrange,
                    onReorder: { _ in }  // no-op for snapshot
                )
                .padding(.horizontal, Riso.gutter)
                .padding(.vertical, 24)
            }
        }
    }

    /// Produces a deterministic set of `RearrangeCellData` + `[String: Task]` for the
    /// given grid size. The centre slot (mid, mid) is a FREE center; all others are
    /// task cells or empty (last two slots for 5×5).
    private func makeFixtures(
        gridSize: Int,
        showCompletedCell: Bool
    ) -> (cells: [RearrangeCellData], taskMap: [String: Task]) {
        let mid = gridSize / 2
        let hasFreeCenter = gridSize % 2 == 1

        // A short list of deterministic task titles
        let titles = [
            "Hydrate", "Stretch", "Walk", "Read", "Journal",
            "Meditate", "Sleep 8h", "No sugar", "Tidy", "Gratitude",
            "Push-ups", "Plan day", "Floss", "Budget", "Yoga",
            "Connect", "Learn", "Steps", "Reflect", "Early rise",
            "Breathe", "Dishes", "Inbox 0", "Walk dog"
        ]
        let types: [TaskType] = [.normal, .counting, .normal, .compound, .normal,
                                  .normal, .counting, .normal, .normal, .achievement]

        var cells: [RearrangeCellData] = []
        var taskMap: [String: Task] = [:]
        var taskIdx = 0

        // Reserve the last two non-center slots as empty for 5×5 grids (to test empty handling).
        let totalSlots = gridSize * gridSize
        let centerCount = hasFreeCenter ? 1 : 0
        let taskSlots = totalSlots - centerCount
        let emptySlots = gridSize == 5 ? 2 : (gridSize == 3 ? 1 : 0)
        let taskCount = taskSlots - emptySlots

        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let isCenter = hasFreeCenter && row == mid && col == mid
                if isCenter {
                    cells.append(RearrangeCellData(
                        id: "center",
                        taskId: nil,
                        isCenter: true,
                        isEmpty: false,
                        originalRow: row,
                        originalCol: col
                    ))
                } else if taskIdx < taskCount {
                    // Distinct boardTaskId (cell.id) vs taskId (taskMap key) so the
                    // test catches a regression to looking up by the wrong key.
                    let btId = "bt-\(row)-\(col)"
                    let taskId = "task-\(row)-\(col)"
                    let title = titles[taskIdx % titles.count]
                    let type = types[taskIdx % types.count]
                    let isCompleted = showCompletedCell && taskIdx == 0
                    let task = makeTask(
                        id: taskId,
                        title: title,
                        type: type,
                        isCompleted: isCompleted
                    )
                    taskMap[taskId] = task
                    cells.append(RearrangeCellData(
                        id: btId,
                        taskId: taskId,
                        isCenter: false,
                        isEmpty: false,
                        originalRow: row,
                        originalCol: col
                    ))
                    taskIdx += 1
                } else {
                    cells.append(RearrangeCellData(
                        id: "empty-\(row)-\(col)",
                        taskId: nil,
                        isCenter: false,
                        isEmpty: true,
                        originalRow: row,
                        originalCol: col
                    ))
                }
            }
        }

        return (cells, taskMap)
    }

    // MARK: - Task builder

    private func makeTask(
        id: String,
        title: String,
        type: TaskType,
        isCompleted: Bool = false
    ) -> Task {
        Task(
            id: id,
            userId: "snapshot-user-1",
            title: title,
            type: type,
            action: type == .counting ? "do" : nil,
            unit: type == .counting ? "times" : nil,
            maxCount: type == .counting ? 10 : nil,
            operatorType: type == .compound ? .and : nil,
            threshold: type == .compound ? 2 : nil,
            achievementTrigger: type == .achievement ? .greenlog : nil,
            totalCompletions: isCompleted ? 1 : 0,
            totalInstances: 1,
            isCompleted: isCompleted,
            completedAt: isCompleted ? SnapshotFixtures.fixedTimestamp : nil,
            createdAt: SnapshotFixtures.fixedTimestamp,
            updatedAt: SnapshotFixtures.fixedTimestamp,
            version: 1,
            isDeleted: false
        )
    }
}
