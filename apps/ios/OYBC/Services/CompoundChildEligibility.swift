import Foundation

/// Compound child eligibility — may an EXISTING library task be linked as a
/// sub-task of a compound?
///
/// Swift twin of @oybc/shared's `compoundChildEligibility.ts`
/// (`compoundChildLinkProblem`): identical strings, identical check order.
/// Shared by the Task Detail save (`applyTaskEditPatch`, which refuses with
/// the message), the board wizard's staged-edit apply (which skips an
/// ineligible link silently) and the sub-task picker (which disables
/// ineligible rows with the message).
///
/// Nested compounds ARE allowed (a child can be another compound — see
/// docs/TASK_SYSTEM.md); only a link that would close a loop is refused.
/// Hidden wizard drafts (`createdInWizard`) are excluded by the picker via
/// the browsable-tasks filter, not here.
enum CompoundChildEligibility {

    /// The six user-facing refusal messages (byte-identical on web).
    enum Message {
        static let selfContainment = "A compound can’t contain itself."
        static let duplicate = "That task is already a sub-task here."
        static let achievement = "Achievements can’t be sub-tasks."
        static let deleted = "That task was deleted."
        static let goalLessCounter = "Counters without a goal can’t be sub-tasks."
        static let loop = "That would create a loop — it already contains this compound."
    }

    /// Returns nil when `candidate` may be linked under `parentId`, else the
    /// user-facing reason. Checks run in this order: self, duplicate,
    /// achievement, deleted, goal-less counter, loop — the first failing
    /// check wins. The goal-less check mirrors the
    /// `BrowsableTasks.isGoalLessCounter` write guard every other
    /// compound-child write enforces.
    ///
    /// - Parameters:
    ///   - parentId: The compound the candidate would be linked under.
    ///   - candidate: The existing task being linked.
    ///   - allLinks: Live links across ALL compounds (soft-deleted rows are
    ///     ignored by the loop walk).
    ///   - currentChildIds: The editor's current kept children (existing +
    ///     already-picked).
    /// - Returns: nil if eligible, otherwise one of `Message`.
    static func linkProblem(
        parentId: String,
        candidate: Task,
        allLinks: [CompoundChild],
        currentChildIds: Set<String>
    ) -> String? {
        if candidate.id == parentId { return Message.selfContainment }
        if currentChildIds.contains(candidate.id) { return Message.duplicate }
        if candidate.type == .achievement { return Message.achievement }
        if candidate.isDeleted { return Message.deleted }
        if BrowsableTasks.isGoalLessCounter(candidate) { return Message.goalLessCounter }
        // A loop closes iff the candidate already (transitively) contains the parent.
        if DerivationPass.findTransitiveParentCompounds(changedTaskId: parentId, children: allLinks)
            .contains(candidate.id) {
            return Message.loop
        }
        return nil
    }

    /// A counting task the compound editor can't keep as a sub-task: no
    /// positive goal (`maxCount`) or a blank unit. `TaskEditPatch.validate`
    /// refuses such a counting sub-task on save, so the picker hides it.
    /// Twin of web `isIncompleteCountingChild`.
    ///
    /// - Parameter task: The candidate task.
    /// - Returns: `true` when the task is COUNTING and lacks a goal or unit.
    static func isIncompleteCountingChild(_ task: Task) -> Bool {
        guard task.type == .counting else { return false }
        let hasGoal = (task.maxCount ?? 0) > 0
        let hasUnit = !(task.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !hasGoal || !hasUnit
    }

    /// The "+ Existing task…" picker's candidate list: the browsable library
    /// narrowed to tasks `linkProblem` accepts under `parentId` and that would
    /// survive save validation (not `isIncompleteCountingChild`), ordered by
    /// lower-cased title (plain code-unit order, locale-independent so it
    /// matches web), then id. Twin of web `compoundChildPickerCandidates`.
    ///
    /// - Parameters:
    ///   - parentId: The compound being edited.
    ///   - browsable: The browsable library (`TaskLibraryViewModel.browsableTasks`).
    ///   - allLinks: Live links across ALL compounds.
    ///   - currentChildIds: The editor's current kept children.
    /// - Returns: The eligible tasks.
    static func pickerCandidates(
        parentId: String,
        browsable: [Task],
        allLinks: [CompoundChild],
        currentChildIds: Set<String>
    ) -> [Task] {
        browsable
            .filter {
                !isIncompleteCountingChild($0)
                    && linkProblem(parentId: parentId, candidate: $0, allLinks: allLinks, currentChildIds: currentChildIds) == nil
            }
            .sorted { a, b in
                let ta = Array(a.title.lowercased().utf16)
                let tb = Array(b.title.lowercased().utf16)
                if ta != tb { return ta.lexicographicallyPrecedes(tb) }
                return Array(a.id.utf16).lexicographicallyPrecedes(Array(b.id.utf16))
            }
    }

    /// Case-insensitive title search over picker candidates (a blank query
    /// keeps every row). Twin of web `searchCompoundChildCandidates`.
    ///
    /// - Parameters:
    ///   - tasks: The candidates.
    ///   - query: The search text.
    /// - Returns: The candidates whose title contains `query`.
    static func searchCandidates(_ tasks: [Task], query: String) -> [Task] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return tasks }
        return tasks.filter { $0.title.lowercased().contains(q) }
    }
}
