import Foundation

// MARK: - Root → copy field propagation (board-scoped edits PR 3)
//
// Swift twin of `packages/shared/src/algorithms/rootFieldPropagation.ts`
// (docs/BOARD_SCOPED_TASK_EDITS.md §6). A counter ROOT's Task Detail edit
// reaches its live per-board copies: title / action / unit propagate; the
// goal never does (each board scales its own target); the kind is written by
// the kind switch (`AppDatabase+CountKindSwitch.swift`), which this planner
// only reads so an auto copy title tracks the copy's switch-rounded goal.
// `description` is not propagated: per-board counting copies are minted
// without one.
//
// Pinned by `rootFieldPropagationVectors.json`
// (`RootFieldPropagationVectorTests`). A change here is a change in two places.
enum RootFieldPropagation {

    /// The root's edit. A nil field is unchanged.
    struct EditPatch: Equatable {
        var title: String?
        var action: String?
        var unit: String?
        /// The root's new goal — decides whether its new title is auto; never propagated.
        var maxCount: CountValue?
        /// The root's requested kind (applied by the kind switch, read here).
        var countKind: CountKind?
    }

    /// A candidate copy (any row read by `sharedCounterId == root.id`), as stored BEFORE the edit.
    struct Copy {
        let task: Task
        /// Placed on a sealed (closed) board — a permanent record, never rewritten.
        let onSealedBoard: Bool
    }

    /// The fields a copy write carries — only those that differ from the copy.
    struct FieldPatch: Equatable {
        var title: String?
        var action: String?
        var unit: String?

        var isEmpty: Bool { title == nil && action == nil && unit == nil }
    }

    /// One planned copy write.
    struct Entry: Equatable {
        let copyId: String
        let patch: FieldPatch
    }

    /// The root-level outcome `planCopy` applies to one copy.
    private struct RootOutcome {
        let kindChanged: Bool
        let kindAfter: CountKind
        let actionChanged: Bool
        let actionAfter: String
        let unitChanged: Bool
        let unitAfter: String
        /// The root's new custom title every copy carries, or nil.
        let carriedTitle: String?
    }

    /// Plan the copy writes a root edit implies. Twin of `planRootFieldPropagation`.
    ///
    /// Rules (each copy judged on its own pre-edit fields):
    /// - Only a live COUNTING row linked to this root (`sharedCounterId == root.id`,
    ///   not deleted, not frozen by `BoardSources.isFrozenDerivedRow`, not on a
    ///   sealed board) is a candidate; a root that is itself linked plans nothing.
    /// - action / unit: a changed root value is copied verbatim.
    /// - title: when the root's NEW title is custom and changed, every live copy
    ///   carries it verbatim (the #542 mint rule). Otherwise an AUTO copy title
    ///   is regenerated from the copy's action / unit / own (switch-rounded)
    ///   goal / kind, and a CUSTOM copy title is kept.
    /// - The goal is never in a patch.
    ///
    /// - Parameters:
    ///   - root: The root before the edit.
    ///   - patch: The root's edit.
    ///   - copies: Candidate copies before the edit.
    ///   - now: ISO8601 freeze clock.
    /// - Returns: One entry per copy that changes, sorted by copy id.
    static func plan(root: Task, patch: EditPatch, copies: [Copy], now: String) -> [Entry] {
        guard root.type == .counting, root.sharedCounterId == nil else { return [] }

        let rootKind = resolveCountKind(root.countKind)
        let rootKindPatch = patch.countKind.flatMap { to in
            planCountKindSwitch(maxCount: root.maxCount, defaultLogAmount: root.defaultLogAmount, from: rootKind, to: to)
        }
        let kindAfter = rootKindPatch != nil ? (patch.countKind ?? rootKind) : rootKind
        let actionBefore = root.action ?? ""
        let unitBefore = root.unit ?? ""
        let titleAfter = (patch.title ?? root.title).trimmingCharacters(in: .whitespacesAndNewlines)
        let actionAfter = patch.action ?? actionBefore
        let unitAfter = patch.unit ?? unitBefore
        let goalAfter = patch.maxCount ?? rootKindPatch?.maxCount ?? root.maxCount

        let titleChanged = titleAfter != root.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionChanged = actionAfter != actionBefore
        let unitChanged = unitAfter != unitBefore
        let kindChanged = kindAfter != rootKind
        guard titleChanged || actionChanged || unitChanged || kindChanged else { return [] }

        let carryRootTitle = titleChanged && !TaskTitle.isAutoCounterTitle(
            title: titleAfter, action: actionAfter, maxCount: goalAfter, unit: unitAfter, countKind: kindAfter
        )
        let outcome = RootOutcome(
            kindChanged: kindChanged, kindAfter: kindAfter,
            actionChanged: actionChanged, actionAfter: actionAfter,
            unitChanged: unitChanged, unitAfter: unitAfter,
            carriedTitle: carryRootTitle ? titleAfter : nil
        )
        return copies
            .filter { isLiveCopy($0, rootId: root.id, now: now) }
            .compactMap { planCopy($0.task, root: outcome) }
            .sorted { $0.copyId < $1.copyId }
    }

    /// Whether `copy` is a live copy of `rootId` that a root edit may write.
    private static func isLiveCopy(_ copy: Copy, rootId: String, now: String) -> Bool {
        let task = copy.task
        return task.type == .counting
            && task.sharedCounterId == rootId
            && !task.isDeleted
            && !copy.onSealedBoard
            && !BoardSources.isFrozenDerivedRow(task, now: now)
    }

    /// One copy's patch under the root outcome, or nil when nothing changes.
    private static func planCopy(_ copy: Task, root: RootOutcome) -> Entry? {
        let actionBefore = copy.action ?? ""
        let unitBefore = copy.unit ?? ""
        let kindBefore = resolveCountKind(copy.countKind)
        let action = root.actionChanged ? root.actionAfter : actionBefore
        let unit = root.unitChanged ? root.unitAfter : unitBefore

        let title: String
        if let carried = root.carriedTitle {
            title = carried
        } else if TaskTitle.isAutoCounterTitle(
            title: copy.title, action: actionBefore, maxCount: copy.maxCount, unit: unitBefore, countKind: kindBefore
        ) {
            // The kind switch rounds the copy's goal; an auto title follows it.
            let switched = root.kindChanged
                ? planCountKindSwitch(
                    maxCount: copy.maxCount, defaultLogAmount: copy.defaultLogAmount, from: kindBefore, to: root.kindAfter
                )
                : nil
            let kind = switched != nil ? root.kindAfter : kindBefore
            let goal = switched?.maxCount ?? copy.maxCount
            title = TaskTitle.generateCounterTaskTitle(action: action, maxCount: goal, unit: unit, countKind: kind)
        } else {
            title = copy.title
        }

        var patch = FieldPatch()
        if title != copy.title { patch.title = title }
        if action != actionBefore { patch.action = action }
        if unit != unitBefore { patch.unit = unit }
        return patch.isEmpty ? nil : Entry(copyId: copy.id, patch: patch)
    }
}
