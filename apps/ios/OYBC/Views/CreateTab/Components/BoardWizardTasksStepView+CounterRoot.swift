import Foundation

extension BoardWizardTasksStepView {
    /// The stored task behind a hand-added counter ROOT row, whose inline-edit
    /// goal lands on this board's placement (`saveCounterRootEdit`); nil for
    /// any other row, or where the surface wires no placement parameters.
    ///
    /// - Parameter row: The row's (staged-overlaid) task.
    /// - Returns: The root as stored, or nil.
    func counterRootBase(_ row: OYBC.Task) -> OYBC.Task? {
        guard onSetPlacementParams != nil else { return nil }
        return QuickAddCounterPlacement.counterRootEditBase(
            row, pending: pendingTasks?[row.id]?.task, library: library.libraryTasks, all: Array(effectiveTaskById.values)
        )
    }
}
