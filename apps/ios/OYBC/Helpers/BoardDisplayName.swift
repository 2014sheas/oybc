import Foundation

/// Heals board names that were frozen from a clock-relative label.
///
/// Mirrors the shared TypeScript `boardDisplayName` in
/// `packages/shared/src/algorithms/boardDisplayName.ts` — keep the two in
/// lockstep.
///
/// ## Why this exists
///
/// Core boards are auto-named — the wizard locks the name field for them
/// (`isCore`), so the user never gets a chance to change it before save.
/// That name came from `formatTimeframeLabel`, whose daily branch returns
/// the literal `"Today"` when the window is the current calendar date. The
/// string is correct for one day and then **persists**, so every daily core
/// board a user has ever created is stored as `"Today"` — making them
/// indistinguishable in lists, in search, and on share posters.
///
/// The mint path now stores `formatWindowLabel`'s absolute label, so no
/// *new* board enters this state. This helper covers boards already in the
/// database. It deliberately derives rather than rewriting the rows: past
/// core boards are exactly the ones that get **sealed**, and sealed boards
/// must never mutate outside deterministic pull-path re-derivation (see
/// `docs/WINDOWED_COMPLETION.md`). A rename migration would have written to
/// precisely the rows that invariant protects.
enum BoardDisplayName {

    /// The bare clock-relative label the daily branch could freeze into a name.
    private static let staleWindowLabel = "Today"

    /// Separator `deriveSpawnedBoardName` puts between template name and window label.
    private static let spawnNameSeparator = " — "

    /// Returns the name to display for a board, healing a frozen "Today".
    ///
    /// Pure and clock-independent: the result depends only on the board's own
    /// fields, so it can never change under an already-painted view.
    ///
    /// Only the two strings the auto-namers could actually produce are
    /// treated as stale, matched exactly, and only on `isCore` boards:
    /// `"Today"` and `"<template name> — Today"`. Anything else is returned
    /// untouched, so a board the user renamed via Board Edit keeps its name
    /// even if that name contains the word "today".
    ///
    /// - Parameter board: The board to name.
    /// - Returns: The stored name, or an absolute window label when the
    ///   stored name is one of the known stale auto-generated forms.
    static func resolve(_ board: Board) -> String {
        // User-authored names are never rewritten. Only auto-named core
        // boards can hold a frozen label, so a non-core board is its own name.
        guard board.isCore else { return board.name }
        guard let startDate = parseISO8601Date(board.startDate) else { return board.name }

        if board.name == staleWindowLabel {
            return formatWindowLabel(timeframe: board.timeframe, startDate: startDate)
        }

        // Spawned form: "<template name> — Today". Heal only the window half
        // so the template's own name (which the user did author) survives.
        let staleSuffix = "\(spawnNameSeparator)\(staleWindowLabel)"
        if board.name.hasSuffix(staleSuffix) {
            let prefix = String(board.name.dropLast(staleSuffix.count))
            let windowLabel = formatWindowLabel(timeframe: board.timeframe, startDate: startDate)
            return "\(prefix)\(spawnNameSeparator)\(windowLabel)"
        }

        return board.name
    }
}

extension Board {
    /// The board's name as it should appear in the UI.
    ///
    /// Prefer this over `name` at every display site. See
    /// ``BoardDisplayName`` for why historical core boards need healing.
    var displayName: String {
        BoardDisplayName.resolve(self)
    }

    /// Returns a copy whose `name` is the healed display name.
    ///
    /// Applied by the read-path helpers in `AppDatabase+Boards` so every
    /// display site gets a sound name without having to remember to ask
    /// for one. Deliberately NOT applied by `fetchUnsyncedBoards` or the
    /// mutation paths (which re-read via `Board.fetchOne` inside their
    /// write block), so a healed name is never pushed to Firestore or
    /// written back over a sealed row.
    ///
    /// - Returns: `self` when the name needs no healing, otherwise a copy.
    func healingDisplayName() -> Board {
        let healed = displayName
        guard healed != name else { return self }
        var copy = self
        copy.name = healed
        return copy
    }
}

extension Array where Element == Board {
    /// ``Board/healingDisplayName()`` over a list.
    ///
    /// - Returns: The boards with display-safe names.
    func healingDisplayNames() -> [Board] {
        map { $0.healingDisplayName() }
    }
}
