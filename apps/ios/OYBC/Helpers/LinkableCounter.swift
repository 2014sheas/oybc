import Foundation

// MARK: - LinkableCounter (Swift port of linkableCounter.ts)
//
// When a user creates a new COUNTING task, if its `action + unit` match an
// existing counter (source / standalone), the create form surfaces a one-tap
// "link to it" suggestion (the user confirms — never silent). This is the
// pure MATCH: given the typed action+unit, which existing counter should the
// new task join?
//
// A candidate is a live COUNTING task that is NOT itself derived
// (`sharedCounterId == nil`). Derived tasks aren't link targets; you link to
// their source, which itself matches. When several candidates match, the
// most-established counter wins (most member tasks → highest all-time count →
// stable id tie-break).
//
// Linking sets the new task's `sharedCounterId` to the returned `counterId`
// and a baseline (start-from-zero by default). No engine change — this feeds
// the existing linked-counter create path.
//
// Keep in sync with `packages/shared/src/algorithms/linkableCounter.ts`.
// The 8 test cases in `OYBCTests/LinkableCounterTests.swift` mirror those in
// `packages/shared/tests/algorithms/linkableCounter.test.ts`.

// MARK: - Types

/// The existing counter a new task can join, plus display stats for the
/// suggestion banner. Mirror of the TypeScript `LinkableCounter` interface.
struct LinkableCounterSuggestion {
    /// The source counting task id — set as the new task's `sharedCounterId`.
    let counterId: String
    /// Display label for the suggestion — the counter's activity (source `action`).
    let name: String
    /// All-time lifetime = the source's `currentCount`.
    let lifetime: Int
    /// Tasks already sharing this counter (source + linkers) — for "N tasks".
    let memberCount: Int
}

// MARK: - Algorithm

/// Find the existing counter a new counting task (with the given action+unit)
/// should be suggested to join.
///
/// Normalisation is case-insensitive + trim-only; the caller passes raw field
/// values as the user typed them. Returns `nil` when action or unit is blank
/// or nothing matches (no suggestion shown).
///
/// - Parameters:
///   - action: The new task's action (activity) as typed.
///   - unit: The new task's unit as typed.
///   - excludeTaskId: Exclude this task id from candidates (pass the edited
///     task's own id when editing, so a task can't suggest itself).
///   - tasks: All tasks to search (non-deleted inclusive; internal filter
///     removes soft-deleted rows and non-counting types).
/// - Returns: The counter to suggest, or `nil` when no match exists.
func findLinkableCounter(
    action: String,
    unit: String,
    excludeTaskId: String? = nil,
    tasks: [Task]
) -> LinkableCounterSuggestion? {
    let a = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let u = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !a.isEmpty, !u.isEmpty else { return nil }

    let live = tasks.filter { !$0.isDeleted && $0.type == .counting }

    // Count linker tasks per source id (derived tasks point at their source).
    var linkerCountBySource: [String: Int] = [:]
    for t in live {
        if let srcId = t.sharedCounterId {
            linkerCountBySource[srcId, default: 0] += 1
        }
    }

    // Candidates: live COUNTING sources / standalones (not derived) whose
    // normalised action+unit match the new task's. Never suggest derived tasks
    // as link targets — always the source they already point at.
    let candidates = live.filter { t in
        t.id != excludeTaskId &&
        t.sharedCounterId == nil &&
        (t.action ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == a &&
        (t.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == u
    }
    guard !candidates.isEmpty else { return nil }

    // Most-established first: member count (source counts as 1), then
    // highest all-time currentCount, then stable id tie-break.
    let best = candidates.sorted { x, y in
        let mx = 1 + (linkerCountBySource[x.id] ?? 0)
        let my = 1 + (linkerCountBySource[y.id] ?? 0)
        if mx != my { return mx > my }
        let cx = x.currentCount ?? 0
        let cy = y.currentCount ?? 0
        if cx != cy { return cx > cy }
        return x.id < y.id
    }.first!

    // Name: prefer the source's trimmed `action` (the activity), falling back
    // to `title` (mirrors TS: `(best.action ?? '').trim() || best.title`).
    let trimmedAction = (best.action ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let name = trimmedAction.isEmpty ? best.title : trimmedAction

    return LinkableCounterSuggestion(
        counterId: best.id,
        name: name,
        lifetime: best.currentCount ?? 0,
        memberCount: 1 + (linkerCountBySource[best.id] ?? 0)
    )
}

// MARK: - Hub-create dedupe classification (P5)

/// What the hub "+ New counter" form's typed action+unit collided with.
/// Mirrors the TypeScript `CounterCreateMatch['kind']` union.
enum CounterCreateMatchKind: Equatable {
    /// An established counter (has linked tasks or is flagged `isCounter`)
    /// — the UI blocks create and offers jump-to.
    case established
    /// A standalone counting task — the UI offers one-tap promote (set
    /// `isCounter: true` on it).
    case standalone
}

/// P5 — hub-create dedupe classification result. Mirror of the TypeScript
/// `CounterCreateMatch` type.
struct CounterCreateMatch {
    let kind: CounterCreateMatchKind
    /// The matched source/standalone Task row (promote target when standalone).
    let task: Task
    let lifetime: Int
    let memberCount: Int
}

/// Classify what the hub "+ New counter" form's typed action+unit collides
/// with: an ESTABLISHED counter (has linked tasks or is flagged `isCounter`)
/// → the UI blocks create and offers jump-to; a STANDALONE counting task →
/// the UI offers one-tap promote (set `isCounter: true` on it). `nil` when
/// nothing matches (create proceeds). Wraps `findLinkableCounter`; the task
/// row is looked up because `memberCount` alone cannot distinguish a
/// standalone from a flagged single-member counter
/// (docs/SHARED_COUNTERS.md §P5 decision 7).
///
/// - Parameters:
///   - action: The new task's action (activity) as typed.
///   - unit: The new task's unit as typed.
///   - excludeTaskId: Exclude this task id from matches (when editing an
///     existing task).
///   - tasks: All tasks to search (non-deleted inclusive; internal filter
///     removes soft-deleted rows and non-counting types).
/// - Returns: The classification, or `nil` when nothing matches.
func classifyCounterCreateMatch(
    action: String,
    unit: String,
    excludeTaskId: String? = nil,
    tasks: [Task]
) -> CounterCreateMatch? {
    guard let match = findLinkableCounter(
        action: action,
        unit: unit,
        excludeTaskId: excludeTaskId,
        tasks: tasks
    ) else { return nil }

    guard let task = tasks.first(where: { $0.id == match.counterId }) else { return nil }

    let established = match.memberCount > 1 || task.isCounter == true
    return CounterCreateMatch(
        kind: established ? .established : .standalone,
        task: task,
        lifetime: match.lifetime,
        memberCount: match.memberCount
    )
}
