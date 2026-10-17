import SwiftUI

/// How Task Detail is presented — the nav row differs (docs/TASK_DETAIL_REDESIGN.md §A/§B).
enum TaskDetailPresentation: Equatable {
    /// Pushed from the Tasks tab: a back chevron on the left.
    case route
    /// "Open in library" sheet: no chevron, a Done pill beside ⋯; `returnTo` names the
    /// task an in-sheet swap came from (its return pill takes the chevron slot).
    case sheet(returnTo: ReturnTarget?)

    struct ReturnTarget: Equatable {
        let taskId: String
        let title: String
        let kind: RisoTaskKind
    }

    var isSheet: Bool { if case .sheet = self { return true } else { return false } }
}

/// Task Detail's callbacks. Defaults are no-ops so snapshot hosts pass only what they use.
struct TaskDetailActions {
    var onBack: () -> Void = {}
    var onDone: () -> Void = {}
    var onReturn: () -> Void = {}
    var onEdit: () -> Void = {}
    var onMarkDone: () -> Void = {}
    /// A chip / entry log: `(taskId, amount, persistAsDefault)`.
    var onLog: (String, CountValue, Bool) -> Void = { _, _, _ in }
    var onRemove: (String, CountValue) -> Void = { _, _ in }
    var onToggleChild: (String) -> Void = { _ in }
    var onUndo: () -> Void = {}
    /// Another task's detail (a child, a parent compound).
    var onOpenTask: (String) -> Void = { _ in }
    var onOpenCounter: (String) -> Void = { _ in }
    var onOpenBoard: (String) -> Void = { _ in }
    var onOpenCounterSettings: () -> Void = {}
    var onDelete: () -> Void = {}
}
