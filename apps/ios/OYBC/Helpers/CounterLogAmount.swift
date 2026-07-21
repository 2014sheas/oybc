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
}
