import Foundation

// MARK: - CoreBoardSetupDefaults (Swift port of coreBoardSetupDefaults.ts)
//
// Per-timeframe core-board setup defaults (docs/POOLS_RECURRING.md
// §Per-timeframe size + centre, owner-decided 2026-09-29).
//
// A `CoreBoardDefault` row may carry a per-timeframe `defaultBoardSize` /
// `defaultCenterType` override; a nil field inherits the global
// `UserPreferences.defaultBoardSize` / `defaultCenterType`. This is the ONE
// resolver both wizards call at their existing core-prefill point — never
// read the raw row fields for a board's setup.
//
// Pinned to the same fixture as the TS original:
// `packages/shared/tests/fixtures/coreBoardSetupDefaultsVectors.json`
// (`OYBCTests/CoreBoardSetupDefaultsVectorTests.swift`).

/// Wizard-ready setup: size + a centre already consistent with that size.
struct CoreBoardSetupDefaults: Equatable {
    /// 3, 4 or 5 — the wizard's `size`.
    let boardSize: Int
    /// `.free` or `.none` — never `.chosen` (a per-board pick, not a default).
    let centerType: CenterSquareType
}

/// Resolves the size + centre a core board of one timeframe should START
/// with: the row's override where set, else the global preference — then
/// the wizard's even-size rule (a 4×4 has no centre → `.none`). The result
/// is exactly what `BoardWizardViewModel.coerceCenterType` / web
/// `coerceCenterType(size, desired)` would produce, so a wizard may still
/// run its own coercion afterwards harmlessly.
///
/// Defaults PRE-FILL setup like pools do; they never own the board — a saved
/// draft or a repeat series keeps its own size (the caller's concern).
///
/// - Parameters:
///   - coreDefault: The timeframe's row; nil = no row for this timeframe.
///   - preferences: The user's global preferences (only `defaultBoardSize` /
///     `defaultCenterType` are read).
/// - Returns: The resolved `{ boardSize, centerType }`.
func resolveCoreBoardSetupDefaults(
    coreDefault: CoreBoardDefault?,
    preferences: UserPreferences
) -> CoreBoardSetupDefaults {
    resolveCoreBoardSetupDefaults(
        defaultBoardSize: coreDefault?.defaultBoardSize,
        defaultCenterType: coreDefault?.defaultCenterType,
        preferences: preferences
    )
}

/// Same resolution as `resolveCoreBoardSetupDefaults(coreDefault:preferences:)`,
/// taking the two override fields directly rather than a full
/// `CoreBoardDefault` row. Lets a caller resolve against an in-progress,
/// not-yet-persisted draft (e.g. `CoreDefaultsEditSheetView`'s BOARD
/// section, which tracks its own local overrides until Save) without
/// constructing a throwaway row.
///
/// - Parameters:
///   - defaultBoardSize: The override, or nil to inherit.
///   - defaultCenterType: The override, or nil to inherit.
///   - preferences: The user's global preferences.
/// - Returns: The resolved `{ boardSize, centerType }`.
func resolveCoreBoardSetupDefaults(
    defaultBoardSize: DefaultBoardSize?,
    defaultCenterType: DefaultCenterSquareType?,
    preferences: UserPreferences
) -> CoreBoardSetupDefaults {
    let boardSize = (defaultBoardSize ?? preferences.defaultBoardSize).rawValue
    let desired = defaultCenterType ?? preferences.defaultCenterType
    let isOdd = boardSize % 2 != 0
    return CoreBoardSetupDefaults(
        boardSize: boardSize,
        centerType: isOdd ? centerSquareType(from: desired) : .none
    )
}

/// Whether a row explicitly sets EITHER override (size or centre). Drives the
/// Board-settings per-timeframe summary suffix ("3×3 · free space"), which
/// appears only when a timeframe overrides something — an inheriting row
/// shows no suffix even though it still resolves to a size.
///
/// - Parameter coreDefault: The timeframe's row, or nil.
/// - Returns: `true` when `defaultBoardSize` or `defaultCenterType` is set.
func hasExplicitCoreBoardSetup(_ coreDefault: CoreBoardDefault?) -> Bool {
    coreDefault?.defaultBoardSize != nil || coreDefault?.defaultCenterType != nil
}

/// Widens the two-valued default centre to the board-level enum.
///
/// - Parameter value: A default centre (`.free` / `.none`).
/// - Returns: The matching `CenterSquareType` case.
private func centerSquareType(from value: DefaultCenterSquareType) -> CenterSquareType {
    switch value {
    case .free: return .free
    case .none: return .none
    }
}
