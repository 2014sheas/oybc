import Foundation

/// Counter kinds — Swift twin of `packages/shared/src/algorithms/countEntry.ts`
/// (docs/COUNTER_KINDS.md §5), pinned by `countEntryVectors.json`. Every Goal /
/// custom-amount field parses through `parseCountInput`; every kind picker
/// derives its locks from `kindPickerLock`.

extension CountKind {
    /// On-screen label (D1 / §5), in picker order via `allCases`.
    var label: String {
        switch self {
        case .discrete: return "Discrete"
        case .continuous: return "Continuous"
        case .duration: return "Duration"
        }
    }
}

/// Whether the picker is on a task that does not exist yet.
enum KindPickerMode: String, Decodable { case create, edit }

/// Which picker segments are locked.
enum KindPickerLock: String, Decodable { case none, duration, all }

/// - Returns: `.none` on create; `.all` for an existing Duration; else `.duration` (D4).
func kindPickerLock(mode: KindPickerMode, kind: CountKind) -> KindPickerLock {
    guard mode == .edit else { return .none }
    return kind == .duration ? .all : .duration
}

/// - Returns: Whether `segment` ignores taps under `lock`.
func isKindSegmentLocked(_ lock: KindPickerLock, segment: CountKind) -> Bool {
    lock == .all || (lock == .duration && segment == .duration)
}

/// - Returns: Whether `segment` carries the lock glyph (only the selected one under `.all`).
func kindSegmentShowsLock(_ lock: KindPickerLock, segment: CountKind, selected: CountKind) -> Bool {
    if lock == .all { return segment == selected }
    return isKindSegmentLocked(lock, segment: segment) && segment != selected
}

/// Any entry above this is refused (an overflow digit string reads as invalid,
/// never as a huge goal). Twin of `MAX_COUNT_INPUT`.
private let maxCountInput: CountValue = 1_000_000_000

private func isASCIIDigits(_ s: Substring) -> Bool {
    !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
}

/// Doubles throughout: a huge digit string must read as a large finite value
/// (then refused by the cap), never trap on integer overflow.
private func parseDurationMinutes(_ s: String) -> CountValue? {
    if isASCIIDigits(Substring(s)) { return CountValue(s) }
    if let colon = s.firstIndex(of: ":") {
        let h = s[..<colon], m = s[s.index(after: colon)...]
        guard isASCIIDigits(h), isASCIIDigits(m), m.count <= 2,
              let hv = CountValue(h), let mv = CountValue(m), mv <= 59 else { return nil }
        return hv * 60 + mv
    }
    // "Xh Ym" / "Xh" / "Ym", spaces optional, case-insensitive — the same
    // grammar as the TS DURATION_HM regex.
    let pattern = #"^(?:([0-9]+)\s*h)?\s*(?:([0-9]+)\s*m)?$"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    func group(_ i: Int) -> CountValue? {
        guard let r = Range(match.range(at: i), in: s) else { return nil }
        return CountValue(s[r])
    }
    let h = group(1), m = group(2)
    guard h != nil || m != nil else { return nil }
    return (h ?? 0) * 60 + (m ?? 0)
}

/// Parses a Goal / custom-amount field for a kind. ASCII digits only (R10).
///
/// - Parameters:
///   - raw: The field text.
///   - kind: The counter's kind.
///   - allowZero: Admits 0 (the hub's optional "Start from").
/// - Returns: The value (minutes for duration), or nil when not a valid entry.
func parseCountInput(_ raw: String, kind: CountKind, allowZero: Bool = false) -> CountValue? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    var value: CountValue?
    switch kind {
    case .discrete:
        value = isASCIIDigits(Substring(s)) ? CountValue(s) : nil
    case .continuous:
        let sepIndex = s.firstIndex(where: { $0 == "." || $0 == "," })
        let whole = sepIndex.map { s[..<$0] } ?? Substring(s)
        let frac = sepIndex.map { s[s.index(after: $0)...] } ?? Substring("")
        let wholeOK = whole.isEmpty || isASCIIDigits(whole)
        let fracOK = frac.isEmpty || (isASCIIDigits(frac) && frac.count <= 2)
        if wholeOK, fracOK, !(whole.isEmpty && frac.isEmpty) {
            value = CountValue("\(whole.isEmpty ? "0" : String(whole)).\(frac.isEmpty ? "0" : String(frac))").map(quantizeCount)
        }
    case .duration:
        value = parseDurationMinutes(s)
    }
    guard let v = value, v.isFinite, v >= 0, v <= maxCountInput else { return nil }
    if v == 0 && !allowZero { return nil }
    return v
}

/// Splits stored minutes into hours / zero-padded minutes strings (both "" when nil).
func durationToFields(_ minutes: CountValue?) -> (hours: String, minutes: String) {
    guard let minutes else { return ("", "") }
    let total = Int(max(0, min((minutes + 0.5).rounded(.down), maxCountInput * 60)))
    return (String(total / 60), String(format: "%02d", total % 60))
}

/// Joins the two Duration fields into a `parseCountInput`-parsable string ("" when both blank).
func durationFromFields(hours: String, minutes: String) -> String {
    let h = hours.trimmingCharacters(in: .whitespaces), m = minutes.trimmingCharacters(in: .whitespaces)
    if h.isEmpty && m.isEmpty { return "" }
    return "\(h.isEmpty ? "0" : h)h \(m.isEmpty ? "0" : m)m"
}

/// - Returns: False only for duration (its unit is time).
func countKindNeedsUnit(_ kind: CountKind) -> Bool { kind != .duration }

/// - Returns: " unit", or "" for duration or a blank unit.
func countUnitSuffix(_ kind: CountKind, unit: String?) -> String {
    let u = (unit ?? "").trimmingCharacters(in: .whitespaces)
    return kind == .duration || u.isEmpty ? "" : " \(u)"
}

/// `formatCount` + `countUnitSuffix` — "3.1 mi", "1h 30m".
func formatCountWithUnit(_ value: CountValue, kind: CountKind, unit: String?, locale: Locale = .current) -> String {
    formatCount(value, kind: kind, locale: locale) + countUnitSuffix(kind, unit: unit)
}

/// A row's effective kind: a linked row follows its root (D5 / R19); a lost
/// root falls back to the row's own kind.
func resolveFamilyCountKind(_ task: Task, lookup: (String) -> Task?) -> CountKind {
    if let rootId = task.sharedCounterId, let root = lookup(rootId) { return resolveCountKind(root.countKind) }
    return resolveCountKind(task.countKind)
}
