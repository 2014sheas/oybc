import Foundation

/// Counter kinds — Swift twin of `packages/shared/src/algorithms/countValue.ts`
/// (docs/COUNTER_KINDS.md §3), pinned by `countValueVectors.json`.

/// Every counting value (goal, count, delta, baseline, default log amount,
/// member-rule target). Integers are exact, so discrete counters are unchanged.
typealias CountValue = Double

/// A counting task's kind. A nil stored value resolves to `.discrete`.
enum CountKind: String, Codable, CaseIterable, Equatable {
    case discrete, continuous, duration
}

/// - Returns: `raw`, or `.discrete` when nil.
func resolveCountKind(_ raw: CountKind?) -> CountKind { raw ?? .discrete }

/// - Returns: True for `.discrete` and `.duration` (whole units).
func isWholeCountKind(_ kind: CountKind) -> Bool { kind != .continuous }

/// Rounds to 2 decimal places, half away from zero; `-0` → `0`.
/// Same arithmetic as the TS twin so both land on the identical double.
/// JS `Math.round` rounds half toward +∞; the argument is non-negative here,
/// so `.toNearestOrAwayFromZero` is the identical rule.
func quantizeCount(_ x: CountValue) -> CountValue {
    let q = (abs(x) * 100 + 1e-7).rounded(.toNearestOrAwayFromZero) / 100
    if q == 0 { return 0 }
    return x < 0 ? -q : q
}

/// - Returns: True when finite and already at 2dp.
func isQuantizedCount(_ x: CountValue) -> Bool { x.isFinite && quantizeCount(x) == x }

/// Low-clamp, quantize, then round half-up for whole kinds.
func finalizeWindowCount(_ sum: CountValue, kind: CountKind) -> CountValue {
    let q = quantizeCount(max(0, sum))
    return isWholeCountKind(kind) ? (q + 0.5).rounded(.down) : q
}

/// Display text: whole numbers for whole kinds, trimmed decimals for
/// continuous, `Xh Ym` for duration minutes. No grouping.
func formatCount(_ value: CountValue, kind: CountKind, locale: Locale = .current) -> String {
    if kind == .duration {
        let minutes = Int(max(0, (value + 0.5).rounded(.down)))
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
    let f = NumberFormatter()
    // Latin digits always (matches pre-feature output); only the decimal
    // separator follows the locale.
    f.locale = Locale(identifier: locale.identifier.components(separatedBy: "@").first! + "@numbers=latn")
    f.numberStyle = .decimal
    f.usesGroupingSeparator = false
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = kind == .continuous ? 2 : 0
    f.roundingMode = .halfUp
    let v = kind == .continuous ? quantizeCount(value) : (quantizeCount(value) + 0.5).rounded(.down)
    return f.string(from: NSNumber(value: v)) ?? "\(v)"
}

/// The string a text field is seeded with and later re-parsed from:
/// `en_US_POSIX` (ASCII digits, `.` separator), no grouping.
func formatCountForInput(_ value: CountValue, kind: CountKind) -> String {
    formatCount(value, kind: kind, locale: Locale(identifier: "en_US_POSIX"))
}

/// Discrete ⇄ continuous only (D4).
func canSwitchCountKind(from: CountKind, to: CountKind) -> Bool {
    from != to && from != .duration && to != .duration
}

/// The fields a kind switch writes.
struct CountKindSwitchPatch: Equatable {
    var maxCount: CountValue?
    var defaultLogAmount: CountValue?
}

/// - Returns: The patch, or nil when the switch is refused.
func planCountKindSwitch(
    maxCount: CountValue?,
    defaultLogAmount: CountValue?,
    from: CountKind,
    to: CountKind
) -> CountKindSwitchPatch? {
    guard canSwitchCountKind(from: from, to: to) else { return nil }
    func conv(_ v: CountValue) -> CountValue {
        isWholeCountKind(to) ? max(1, (quantizeCount(v) + 0.5).rounded(.down)) : quantizeCount(v)
    }
    return CountKindSwitchPatch(maxCount: maxCount.map(conv), defaultLogAmount: defaultLogAmount.map(conv))
}

/// - Returns: 1 for whole kinds, 0.1 for continuous.
func countTargetStep(_ kind: CountKind) -> CountValue { isWholeCountKind(kind) ? 1 : 0.1 }

// MARK: - Member-rule step rounding

// Twins of `ceilToCountStep` / `roundToCountStep` / `floorToCountStep` in
// countValue.ts, pinned by the same vectors. Whole kinds take the exact
// pre-feature integer ops (no quantize first — 1/366 must still ceil to 1);
// continuous steps in tenths, quantizing the tenths count first so a product
// like 6.1 × 10 = 60.999… reads as 61. Inputs are non-negative, so
// `.toNearestOrAwayFromZero` is JS `Math.round`.

/// Ceil to the kind's target step (1, or 0.1 for continuous).
func ceilToCountStep(_ x: CountValue, kind: CountKind) -> CountValue {
    if isWholeCountKind(kind) { return x.rounded(.up) }
    return quantizeCount((quantizeCount(x * 10) - 1e-9).rounded(.up) / 10)
}

/// Round half-up to the kind's target step (1, or 0.1 for continuous).
func roundToCountStep(_ x: CountValue, kind: CountKind) -> CountValue {
    if isWholeCountKind(kind) { return x.rounded(.toNearestOrAwayFromZero) }
    return quantizeCount((quantizeCount(x * 10) + 1e-9).rounded(.toNearestOrAwayFromZero) / 10)
}

/// Floor to the kind's target step (1, or 0.1 for continuous).
func floorToCountStep(_ x: CountValue, kind: CountKind) -> CountValue {
    if isWholeCountKind(kind) { return x.rounded(.down) }
    return quantizeCount((quantizeCount(x * 10) + 1e-9).rounded(.down) / 10)
}

// MARK: - Totals and ranges

/// A LIFETIME total — `formatCount` with thousands grouping (R7); duration unchanged.
func formatCountTotal(_ value: CountValue, kind: CountKind, locale: Locale = .current) -> String {
    if kind == .duration { return formatCount(value, kind: kind, locale: locale) }
    let f = NumberFormatter()
    f.locale = Locale(identifier: locale.identifier.components(separatedBy: "@").first! + "@numbers=latn")
    f.numberStyle = .decimal
    f.usesGroupingSeparator = true
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = kind == .continuous ? 2 : 0
    f.roundingMode = .halfUp
    let v = kind == .continuous ? quantizeCount(value) : (quantizeCount(value) + 0.5).rounded(.down)
    return f.string(from: NSNumber(value: v)) ?? "\(v)"
}

/// "lo–hi"; continuous renders both ends at the more precise end's precision.
func formatCountRange(_ lo: CountValue, _ hi: CountValue, kind: CountKind, locale: Locale = .current) -> String {
    guard kind == .continuous else {
        return "\(formatCount(lo, kind: kind, locale: locale))\u{2013}\(formatCount(hi, kind: kind, locale: locale))"
    }
    func digits(_ v: CountValue) -> Int {
        let s = formatCountForInput(v, kind: .continuous)
        guard let dot = s.firstIndex(of: ".") else { return 0 }
        return s.distance(from: dot, to: s.endIndex) - 1
    }
    let f = NumberFormatter()
    f.locale = Locale(identifier: locale.identifier.components(separatedBy: "@").first! + "@numbers=latn")
    f.numberStyle = .decimal
    f.usesGroupingSeparator = false
    f.minimumFractionDigits = max(digits(lo), digits(hi))
    f.maximumFractionDigits = 2
    f.roundingMode = .halfUp
    let a = f.string(from: NSNumber(value: quantizeCount(lo))) ?? "\(lo)"
    let b = f.string(from: NSNumber(value: quantizeCount(hi))) ?? "\(hi)"
    return "\(a)\u{2013}\(b)"
}
