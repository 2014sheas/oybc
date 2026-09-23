import Foundation

/// Validates a raw custom-amount input string into a positive integer, or
/// `nil` when the input isn't one (empty, non-numeric, zero, negative,
/// fractional, or leading/trailing junk). Intentionally strict — ASCII
/// digits only on the trimmed string.
///
/// Shared (R3 board-play touchpoints) between `CounterDetailView`'s "#" chip
/// (R2) and `RisoCountingStepperSheet`'s "#" chip (R3) so the two amount-chip
/// UIs don't duplicate the rule. Swift twin of web's `parseCustomLogAmount`
/// (`apps/web/src/components/counters/amountChips.ts`) — keep both in sync
/// if the rule ever changes.
enum CounterLogAmount {
    static func parseCustom(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let n = Int(trimmed), n > 0 else { return nil }
        return n
    }

    /// The fixed preset amounts backing both chip rows (excludes custom "#").
    static let presets = [1, 10, 25]

    /// The chip to pre-select when a picker opens: the counter's remembered
    /// `defaultLogAmount` when it's a preset (so a habitual amount is one tap
    /// away), otherwise `1` — the fixed rows carry no dynamic chip for an
    /// off-preset default, and a non-preset initial value would leave nothing
    /// highlighted. `1` is the fallback because it matches the one-tap paths
    /// (plain cell tap, Hub "+ Log" pill), which log `defaultLogAmount ?? 1`;
    /// a fresh counter must not open on `+10` when everything else about it
    /// steps by one. Swift twin of web's `initialChipAmount`.
    static func initialChip(_ defaultLogAmount: Int?) -> Int {
        if let d = defaultLogAmount, presets.contains(d) { return d }
        return 1
    }
}
