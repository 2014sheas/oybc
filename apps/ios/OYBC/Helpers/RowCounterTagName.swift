import Foundation

/// The counter name a task row's dense `UnitTagView` shows (unit-tasks PR 2,
/// docs/SHARED_COUNTER_SETTINGS.md §3). Web twin:
/// `components/counters/rowCounterTagName.ts`.
///
/// Both relationships carry the same tag (no new mark): a linked copy
/// (`sharedCounterId`) and a unit task (`countsTowardCounterId`). A task with
/// both ids cannot exist; a counter root itself carries neither, so it never
/// gets a tag.
///
/// - Parameters:
///   - task: The row's task.
///   - pool: Tasks to resolve the counter root from (the library / pool in play).
/// - Returns: The root's `counterDisplayName`, or nil when the task has neither
///   id or the root isn't in `pool`.
func rowCounterTagName(task: Task, pool: [Task]) -> String? {
    guard !task.isCounter, let rootId = task.sharedCounterId ?? task.countsTowardCounterId else { return nil }
    guard let root = pool.first(where: { $0.id == rootId }) else { return nil }
    return CounterSettings.counterDisplayName(root)
}

/// `rowCounterTagName(task:pool:)` against a prebuilt id index — what a list
/// uses so each row is a dictionary hit rather than a pool scan.
func rowCounterTagName(task: Task, rootsById: [String: Task]) -> String? {
    guard !task.isCounter, let rootId = task.sharedCounterId ?? task.countsTowardCounterId,
          let root = rootsById[rootId] else { return nil }
    return CounterSettings.counterDisplayName(root)
}

/// The counter root a task's row tag names (`sharedCounterId ?? countsTowardCounterId`
/// resolved in `rootsById`), or nil. The search matchers read its full counter
/// match set from this.
func rowCounterRoot(task: Task, rootsById: [String: Task]) -> Task? {
    guard !task.isCounter, let rootId = task.sharedCounterId ?? task.countsTowardCounterId else { return nil }
    return rootsById[rootId]
}

extension CounterPlacement {
    /// ``taskSearchMatches(_:task:)`` plus the row's counter: typing the
    /// counter's display name or noun (its `unit`) finds its unit tasks and linked
    /// copies (Decision 7). Web twin: `taskSearchMatchesWithCounter`.
    static func taskSearchMatches(_ query: String, task: Task, counterRoot: Task?) -> Bool {
        if taskSearchMatches(query, task: task) { return true }
        guard let counterRoot, !normalizeSearchText(query).isEmpty else { return false }
        let q = normalizeSearchText(query)
        return [CounterSettings.counterDisplayName(counterRoot), counterRoot.unit]
            .map(normalizeSearchText).contains { !$0.isEmpty && $0.contains(q) }
    }
}
