import Foundation

// MARK: - Debug-only console logging
//
// Diagnostic console output (internal ids, DB paths, sync events) should
// never ship in Release builds. `dlog` mirrors `print`'s variadic signature
// so call sites convert with a pure rename (`print(` -> `dlog(`), but the
// body compiles to a no-op outside `#if DEBUG` — the Release compiler drops
// the call entirely rather than just suppressing output at runtime.

/// Debug-only console logging. Compiles to a no-op in Release builds so
/// diagnostic output never ships. Mirrors `print`'s variadic signature so
/// call sites change only `print(` -> `dlog(`.
@inline(__always)
func dlog(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    #if DEBUG
    print(items.map { "\($0)" }.joined(separator: separator), terminator: terminator)
    #endif
}

// MARK: - Logged write attempt

/// Runs a throwing (typically DB) write, logging any failure via `dlog` with
/// `context`, and reports whether it landed. For fire-and-forget call sites
/// that must branch on success (e.g. never show a "Logged +N" toast for a
/// failed write) without a bare `try?` that swallows the error unseen.
///
/// - Parameters:
///   - context: Where the write came from, prefixed to the logged error.
///   - write: The write to perform.
/// - Returns: `true` if `write` completed without throwing, else `false`.
@discardableResult
func attemptLoggedWrite(_ context: String, _ write: () throws -> Void) -> Bool {
    do {
        try write()
        return true
    } catch {
        dlog("⚠️ \(context) failed: \(error)")
        return false
    }
}
