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
