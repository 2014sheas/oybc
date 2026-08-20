import Foundation
import GRDB

/// Logical operator that ties a compound `Task`'s children together.
///
/// Lives on `Task.operatorType` for rows where `type == .compound`.
/// `M_OF_N` additionally consumes `Task.threshold` (how many children
/// must be complete). Mirrors the TypeScript `OperatorType` enum in
/// `@oybc/shared`.
///
/// This used to share a file with the now-retired `CompositeTask` /
/// `CompositeNode` GRDB models. Those were dropped in Phase 8 of the
/// compound-tasks unification, but the operator enum is still load-
/// bearing — `CompoundEvaluation` switches on these cases to evaluate
/// completion, and the shared `RisoCompoundRulePicker` (+ its
/// `CompoundRuleChoice` bridge) uses them for the rule-chip UI in both the
/// create panel and the inline pool-row editor. (`OperatorSelectorView`,
/// referenced here historically, was retired in the Riso redesign — compound
/// authoring is inline now, not a separate picker screen.)
enum OperatorType: String, Codable, DatabaseValueConvertible {
    case and = "AND"
    case or = "OR"
    case mOfN = "M_OF_N"
}
