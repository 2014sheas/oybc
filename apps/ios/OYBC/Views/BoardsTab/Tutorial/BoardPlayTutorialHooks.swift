import SwiftUI

extension BoardPlayViewModel {

    /// Row-major slots of the placed squares that are not complete right now
    /// (display state, so an optimistic count or an Undo shows at once). The
    /// lesson-3 finale lights exactly these.
    func tutorialIncompleteSlots() -> [Int] {
        let size = gridSize
        guard size > 0 else { return [] }
        return derived.placementsByPosition.compactMap { key, placement -> Int? in
            guard let slot = Self.tutorialSlot(key, size: size) else { return nil }
            return displayCompleted(of: placementRender(for: placement)) ? nil : slot
        }.sorted()
    }

    /// Where each placed task's title sits now (row-major slot), so a lesson's
    /// `.square` anchor follows its square after an Edit move or swap.
    func tutorialSlotsByTitle() -> [String: Int] {
        let size = gridSize
        guard size > 0 else { return [:] }
        var slots: [String: Int] = [:]
        for (key, placement) in derived.placementsByPosition {
            guard let slot = Self.tutorialSlot(key, size: size), let task = taskMap[placement.taskId] else { continue }
            slots[task.title] = slot
        }
        return slots
    }

    /// The row-major slot of a `"row-col"` position key.
    private static func tutorialSlot(_ key: String, size: Int) -> Int? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * size + parts[1]
    }
}

extension BoardPlayView {

    /// Tells a running lesson which squares are still incomplete and where each
    /// title sits. Inert outside a lesson.
    func reportTutorialIncompleteSquares() {
        guard let coach = tutorialCoach else { return }
        coach.reportIncomplete(slots: viewModel.tutorialIncompleteSlots())
        coach.reportSlots(byTitle: viewModel.tutorialSlotsByTitle())
    }
}
