import SwiftUI

extension BoardPlayViewModel {

    /// Row-major slots of the placed squares that are not complete right now
    /// (display state, so an optimistic count or an Undo shows at once). The
    /// lesson-3 finale lights exactly these.
    func tutorialIncompleteSlots() -> [Int] {
        let size = gridSize
        guard size > 0 else { return [] }
        return derived.placementsByPosition.compactMap { key, placement -> Int? in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return displayCompleted(of: placementRender(for: placement)) ? nil : parts[0] * size + parts[1]
        }.sorted()
    }
}

extension BoardPlayView {

    /// Tells a running lesson which squares are still incomplete. Inert outside
    /// a lesson.
    func reportTutorialIncompleteSquares() {
        tutorialCoach?.reportIncomplete(slots: viewModel.tutorialIncompleteSlots())
    }
}
