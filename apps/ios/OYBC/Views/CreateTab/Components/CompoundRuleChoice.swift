import Foundation

/// Compound completion-rule choices, shown as pill chips by the shared
/// `RisoCompoundRulePicker` — used by both compound builders: the create
/// panel (`RisoCompoundFieldsView`) and the inline pool-row editor
/// (`RisoPoolRowEditorView`).
///
/// Promoted out of `RisoCompoundFieldsView` (Inline Compound Editor Rework)
/// so both builders share one picker component instead of two vocabularies
/// drifting apart. Bridges two persisted-shape representations:
///   - `CreateFormViewModel.CompoundRule` — the create-panel's VM-layer rule,
///     consumed by `handleCreateCompoundAndAddToPool` (creates a fresh Task).
///   - `OperatorType` (+ `Task.threshold`) — the persisted Task-row shape,
///     consumed directly by the inline editor's `TaskEditPatch` (edits an
///     existing Task in place).
enum CompoundRuleChoice: String, CaseIterable, Equatable {
    case allOf    = "All of"
    case anyOf    = "Any of"
    case atLeastN = "At least N"

    /// Converts to the create-panel's VM-layer rule (threshold is only used
    /// for `.atLeastN`).
    func toVMRule(threshold: Int) -> CreateFormViewModel.CompoundRule {
        switch self {
        case .allOf:    return .allOf
        case .anyOf:    return .anyOf
        case .atLeastN: return .atLeastN(threshold: threshold)
        }
    }

    /// Converts to the persisted `OperatorType` — the inline editor writes
    /// this straight onto `TaskEditPatch.operatorType`.
    func toOperator() -> OperatorType {
        switch self {
        case .allOf:    return .and
        case .anyOf:    return .or
        case .atLeastN: return .mOfN
        }
    }

    /// Reconstructs a rule choice from a persisted `OperatorType`. Falls
    /// back to `.allOf` for an absent operator (matches the create panel's
    /// default and a legacy/never-set compound row).
    init(operator op: OperatorType?) {
        switch op {
        case .and, .none: self = .allOf
        case .or:         self = .anyOf
        case .mOfN:       self = .atLeastN
        }
    }
}
