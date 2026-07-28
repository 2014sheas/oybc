import Foundation

// MARK: - CounterName (Swift port of counterName.ts)
//
// A counting task's identity is the `(action, unit)` pair: `action` is a
// verb (e.g. "Do", "Read", "Run") — defaulting to `"Do"` when blank — and
// `unit` is a plural noun (e.g. "push-ups", "pages", "miles").
// `formatCounterName` derives a counter's display name from that pair,
// eliding the default `"Do"` verb so a plain counter reads as its activity
// rather than "Do push-ups":
//
// | action (verb)         | unit (noun) | formatCounterName |
// | ---------------------- | ----------- | ------------------ |
// | "Do" (or blank/nil)    | "push-ups"  | "Push-ups"          |
// | "Run"                  | "miles"     | "Run miles"         |
// | "Read"                 | "pages"     | "Read pages"        |
//
// No schema change — this is a pure display-time derivation over the
// existing `action`/`unit` columns; legacy rows with a blank action render
// via the same "Do" backfill this function already does. Empty inputs
// collapse to `""` so callers can fall back to a stored title (e.g.
// `SharedCounterGroups.swift` / `LinkableCounter.swift`:
// `CounterName.formatCounterName(...) || task.title`). The TypeScript twin
// is `packages/shared/src/algorithms/counterName.ts` (`formatCounterName`)
// — keep both in sync.
enum CounterName {

    /// Upper-cases only the first character; the rest of the string is untouched.
    private static func capitalizeFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    /// Derives a counter's display name from its `(action, unit)` pair.
    ///
    /// Both inputs are trimmed first. The effective verb is the trimmed
    /// `action`, or `"Do"` when it's blank/nil. When the effective verb is
    /// `"Do"` (case-insensitive), it's elided from the result and the
    /// trimmed noun is returned with only its first letter capitalized
    /// (e.g. `"push-ups"` → `"Push-ups"`). Otherwise the result is
    /// `"{Verb} {noun}"`, with only the verb's first letter capitalized —
    /// the noun is returned exactly as typed (e.g. `"run"`, `"miles"` →
    /// `"Run miles"`).
    ///
    /// - Parameters:
    ///   - action: Verb, e.g. "Run"; trimmed; nil/blank → "Do".
    ///   - unit: Noun, e.g. "miles"; trimmed.
    /// - Returns: The derived display name, or `""` when there's nothing to
    ///   show (a blank/nil noun paired with an effective "Do" verb) —
    ///   callers should fall back to a stored title in that case.
    static func formatCounterName(action: String?, unit: String?) -> String {
        let noun = (unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAction = (action ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let verb = trimmedAction.isEmpty ? "Do" : trimmedAction
        let verbIsDo = verb.lowercased() == "do"

        if verbIsDo {
            return noun.isEmpty ? "" : capitalizeFirst(noun)
        }

        let capitalizedVerb = capitalizeFirst(verb)
        return noun.isEmpty ? capitalizedVerb : "\(capitalizedVerb) \(noun)"
    }
}
