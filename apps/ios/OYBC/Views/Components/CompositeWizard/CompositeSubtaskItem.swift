import Foundation
import Combine

/// Whether a subtask slot references an existing task/composite or is
/// being authored inline inside the composite.
enum SubtaskMode {
    case existing
    case inline_
}

/// Inline subtask types available from the card. Composites can't be
/// authored inline — a nested composite has to be created separately
/// and selected as an existing subtask.
enum InlineSubtaskType: String, CaseIterable, Identifiable {
    case normal = "Normal"
    case counting = "Counting"
    case progress = "Progress"
    var id: String { rawValue }
}

/// A single mutable subtask slot in the flat composite list. Shared
/// across `CompositeTaskWizardView`, `CompositeWizardBuildStepView`,
/// `CompositeWizardReviewStepView`, and `CompositeSubtaskCardView`.
///
/// The legacy stage-1 `isConfirmed` / `confirmError` fields are kept to
/// preserve ABI while the rest of the wizard ignores them — Stage 1 of
/// the redesign retired the chip-collapse pattern in favour of a
/// persistent card form driven by live readiness checks.
class SubtaskItem: ObservableObject, Identifiable {
    let id = UUID()

    @Published var mode: SubtaskMode

    // Existing mode — exactly one of these is set
    @Published var selectionType: SelectionType = .task
    @Published var selectedTaskId: String = ""
    @Published var selectedCompositeId: String = ""

    // Inline mode
    @Published var inlineType: InlineSubtaskType = .normal
    @Published var inlineTitle: String = ""
    @Published var inlineAction: String = ""
    @Published var inlineUnit: String = ""
    @Published var inlineMaxCountStr: String = ""
    @Published var inlineSteps: [ProgressStepFormState] = []
    @Published var isConfirmed: Bool = false
    @Published var confirmError: String?
    /// When set, the card is showing the type-switch confirmation panel
    /// (user tried to change inline type while fields were dirty). `nil`
    /// means no pending switch. See `CompositeSubtaskCardView`.
    @Published var pendingTypeSwitch: InlineSubtaskType?

    enum SelectionType {
        case task
        case composite
    }

    init(mode: SubtaskMode = .existing) {
        self.mode = mode
    }
}

/// Observable wrapper around `[SubtaskItem]` that re-publishes whenever
/// ANY child item's `@Published` properties change.
///
/// SwiftUI's default parent-child observation stops at the `@ObservedObject`
/// boundary: if a child `SubtaskItem`'s `inlineTitle` flips from empty to
/// non-empty, the card view re-renders, but the parent Build-step's
/// derived state (`readyCount`, `canAdvance`, Next-button disabled) does
/// not. We lift the array into this wrapper and subscribe to each item's
/// `objectWillChange` so the parent re-evaluates readiness on every edit.
final class CompositeSubtaskList: ObservableObject {
    @Published private(set) var items: [SubtaskItem] = []
    private var cancellables: [UUID: AnyCancellable] = [:]

    func append(_ item: SubtaskItem) {
        subscribe(item)
        items.append(item)
    }

    func remove(where predicate: (SubtaskItem) -> Bool) {
        for item in items where predicate(item) {
            cancellables.removeValue(forKey: item.id)
        }
        items.removeAll(where: predicate)
    }

    func removeAll() {
        cancellables.removeAll()
        items.removeAll()
    }

    /// Replace the backing array wholesale. Used by the library sheet's
    /// commit path which computes its own next-state array.
    func replace(with newItems: [SubtaskItem]) {
        cancellables.removeAll()
        items = newItems
        for item in newItems { subscribe(item) }
    }

    private func subscribe(_ item: SubtaskItem) {
        cancellables[item.id] = item.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}
