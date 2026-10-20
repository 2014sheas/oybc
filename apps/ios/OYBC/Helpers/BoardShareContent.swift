import Foundation

// MARK: - BoardShareContent

/// Everything the share sheet and its story poster say about one moment —
/// titles, filenames, share text and the stats row — derived from the moment
/// kind and the board's numbers. Pure, so the sheet's copy rules are
/// unit-tested without rendering. Mirrors the web `ShareBoardSheet` model.
struct BoardShareContent: Equatable {
    let kind: MomentTrigger.Kind
    let boardName: String
    let completedTasks: Int
    let totalTasks: Int
    let linesCompleted: Int
    let boardSize: Int
    /// The streak for THIS kind (bingo streak for a bingo poster, greenlog
    /// streak for a greenlog); 0 when none / not computed.
    var streak: Int = 0
    var timeframe: Timeframe = .custom
    var isCore: Bool = false

    /// One stats card on the poster (paper card, value over label).
    struct Stat: Equatable { let value: String; let label: String }

    /// The "Show task names" toggle's default — ON for both kinds.
    static let showTaskNamesDefault = true

    var sheetTitle: String { kind == .bingo ? "Share bingo" : "Share greenlog" }
    var badge: String { kind == .bingo ? "BINGO" : "GREENLOG" }
    var tagline: String { "What's on your bingo card" }
    var shareTitle: String { "\(boardName) — \(badge)" }
    var fileName: String { "\(Self.slug(boardName))-\(kind == .bingo ? "bingo" : "greenlog").png" }

    var shareText: String {
        switch kind {
        case .bingo:
            return "Bingo on \(boardName)! \(linesCompleted) of \(BingoDetection.totalLineCount(gridSize: boardSize)) lines."
        case .greenlog:
            return "I crushed every square. Greenlog on On Your Bingo Card!"
        }
    }

    /// The streak card shows only for a core cadence AND a streak above 1 —
    /// the same rule as the moment overlay's chip.
    var showsStreakCard: Bool { isCore && streak > 1 && !streakUnitLabel(timeframe).isEmpty }

    /// SQUARES (the rail's numbers) always; STREAK under the chip rule.
    var stats: [Stat] {
        var out = [Stat(value: "\(completedTasks)/\(totalTasks)", label: "SQUARES")]
        if showsStreakCard { out.append(Stat(value: compactStreakLabel(streak, timeframe: timeframe), label: "STREAK")) }
        return out
    }

    /// Lowercase, non-alphanumeric runs → "-", trimmed, ≤ 60 chars (the web
    /// `slugify`, which does not re-trim after the cut). Falls back to "board" for a name with no usable characters.
    static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else {
                pendingDash = true
            }
        }
        let s = String(out.prefix(60))
        return s.isEmpty ? "board" : s
    }
}
