import Foundation

/// Long-press menu labels per kind (docs/COUNTER_KINDS.md §5). Discrete keeps
/// the shipped "+ Add {n} {action}" wording; the new kinds name the amount
/// with its unit ("+ Add 3.1 mi", "+ Add 1h 30m").
enum CountingMenuLabels {
    static func add(amount: CountValue, kind: CountKind, unit: String, action: String) -> String {
        kind == .discrete
            ? "+ Add \(formatCount(amount, kind: kind)) \(action)"
            : "+ Add \(formatCountWithUnit(amount, kind: kind, unit: unit))"
    }

    static func remove(amount: CountValue, kind: CountKind, unit: String, action: String) -> String {
        kind == .discrete
            ? "− Remove \(formatCount(amount, kind: kind)) \(action)"
            : "− Remove \(formatCountWithUnit(amount, kind: kind, unit: unit))"
    }
}
