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
    rowCounterTagName(task: task, rootsById: Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
}

/// `rowCounterTagName(task:pool:)` against a prebuilt id index — what a list
/// uses so each row is a dictionary hit rather than a pool scan.
func rowCounterTagName(task: Task, rootsById: [String: Task]) -> String? {
    guard let root = rowCounterRoot(task: task, rootsById: rootsById) else { return nil }
    let name = CounterSettings.counterDisplayName(root)
    return name.isEmpty ? nil : name
}

/// The counter root a task's row tag names (`sharedCounterId ?? countsTowardCounterId`
/// resolved in `rootsById`), or nil. The search matchers read its full counter
/// match set from this.
func rowCounterRoot(task: Task, rootsById: [String: Task]) -> Task? {
    guard !task.isCounter, let rootId = task.sharedCounterId ?? task.countsTowardCounterId,
          rootId != task.id else { return nil }
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

extension CounterPlacement {
    /// Library-poll results for `query`: direct hits (title / the counter's own
    /// fields) first, then counter-name-only hits, each in input order. Web twin:
    /// `selectLibraryPickerResults`.
    ///
    /// - Parameters:
    ///   - tasks: Candidates, already minus excluded ids.
    ///   - query: The typed search.
    ///   - rootsById: The FULL task map counter roots resolve against.
    static func rankedTaskMatches(_ tasks: [Task], query: String, rootsById: [String: Task]) -> [Task] {
        var direct: [Task] = []
        var viaCounter: [Task] = []
        for task in tasks {
            if taskSearchMatches(query, task: task) {
                direct.append(task)
            } else if taskSearchMatches(query, task: task, counterRoot: rowCounterRoot(task: task, rootsById: rootsById)) {
                viaCounter.append(task)
            }
        }
        return direct + viaCounter
    }
}
