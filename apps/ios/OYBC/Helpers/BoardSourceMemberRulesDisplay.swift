import Foundation

// MARK: - Board Sources §Member rules — display + rule-editing (B3)
//
// Swift twin of `packages/shared/src/algorithms/memberRulesDisplay.ts`.
// `BoardSourceMemberRules.swift` (B1 + B2) is the planning/materialisation
// pipeline that runs at persist/spawn time; this file is the UI-facing half
// that READS and WRITES the stored rule a person edits in the Sources sheet:
// the pro-rated target a rule row previews before it is saved
// (`effectiveMemberTarget`), the human-readable vary range / split note
// (`varyRangeLabel`, `splitSquaresNote`), the accessors that read a rule off
// a `BoardSource` without three levels of optional-chaining
// (`memberRule(for:in:)`, `partRule(for:in:)`), and the immutable setters
// that write one back with the same "omit when empty" serialisation
// `BoardSource.memberRules` already promises (`withMemberRule`,
// `withPartRule`).
//
// Split out of `BoardSourceMemberRules.swift` (rather than appended to it)
// to keep that file under the 1000-line god-file guardrail; the call surface
// is `BoardSources.<fn>` either way.
//
// Pinned by the `display` section of the byte-identical vector fixture
// (`OYBCTests/Fixtures/memberRuleVectors.json` ↔
// `packages/shared/tests/fixtures/memberRuleVectors.json`) — a change here
// is a change in two places.
extension BoardSources {

    // MARK: - Preview arithmetic

    /// The target a rule-editing surface previews for a counting member —
    /// the same pro-rated math `planDerivedTasks` applies at mint time,
    /// without requiring a full plan run.
    ///
    /// One-off boards never auto-target (`explicit ?? goal`); recurring
    /// boards only auto-target when the member came from a BOARD source —
    /// `fromBoard` mirrors `resolveTarget`'s real gate inside
    /// `planDerivedTasks` (`fromBoard && mode == .recurring`), so a
    /// pool-sourced or hand-added member falls straight to `explicit ?? goal`
    /// even in recurring mode. When the gate is open the target pro-rates via
    /// ``autoTarget(goal:sourceDays:targetDays:)`` over the nominal
    /// day-lengths of the two windows; a missing `sourceWindow` behaves
    /// exactly like `autoTarget` with a nil source (falls back to `goal`).
    /// Either way the result is floored and clamped to `1…goal`.
    ///
    /// - Parameters:
    ///   - goal: The member's own `maxCount` (integer ≥ 1).
    ///   - explicit: A stored member-/part-level `target` override, if any.
    ///   - mode: Whether the board being assembled is one-off or recurring.
    ///   - fromBoard: Whether the supplying source is `kind == .board`.
    ///   - sourceWindow: The window the member was pulled from, if known.
    ///   - targetWindow: The window of the board being assembled.
    /// - Returns: The effective target (integer ≥ 1, ≤ `goal`).
    static func effectiveMemberTarget(
        goal: Int,
        explicit: Int? = nil,
        mode: PlanMode,
        fromBoard: Bool,
        sourceWindow: BoardWindow? = nil,
        targetWindow: BoardWindow
    ) -> Int {
        let targetDays = nominalWindowDays(
            targetWindow.timeframe,
            startDate: targetWindow.startDate,
            endDate: targetWindow.endDate
        )
        let base: Int
        if let explicit {
            base = explicit
        } else if fromBoard, mode == .recurring {
            base = autoTarget(
                goal: goal,
                sourceDays: sourceWindow.flatMap {
                    nominalWindowDays($0.timeframe, startDate: $0.startDate, endDate: $0.endDate)
                },
                targetDays: targetDays
            )
        } else {
            base = goal
        }
        return Swift.min(Swift.max(1, base), goal)
    }

    /// Human-readable vary range for a rule-editing surface — the inclusive
    /// `lo...hi` from ``varyRange(t:level:goal:)``, rendered as
    /// `"lo–hi unit"` (EN DASH, U+2013; the unit omitted entirely when empty).
    ///
    /// - Parameters:
    ///   - t: The pre-vary target (see ``effectiveMemberTarget``).
    ///   - level: Vary level. `.off` renders nothing — there is no range.
    ///   - goal: The member's own `maxCount`, the hard ceiling.
    ///   - unit: The counting member's unit, or `""` when it has none.
    /// - Returns: The label, or nil at vary level `.off`.
    static func varyRangeLabel(t: Int, level: VaryLevel, goal: Int, unit: String) -> String? {
        guard level != .off else { return nil }
        let range = varyRange(t: t, level: level, goal: goal)
        let suffix = unit.isEmpty ? "" : " \(unit)"
        return "\(range.lowerBound)\u{2013}\(range.upperBound)\(suffix)"
    }

    /// Human-readable "N squares" note for a Split-up compound member — how
    /// many of its parts actually contribute to the board.
    ///
    /// `excludedPartIds` is INTERSECTED against `partIds` (the member's own,
    /// live part ids) rather than counted on its own, so a stale excluded id
    /// that no longer names one of the member's parts is silently inert — the
    /// same "stale rule does nothing" idiom ``applyMemberRules`` uses. The
    /// result floors at 1: this is a display note, not the expansion itself,
    /// so it never claims "0 squares" even when every part is excluded.
    ///
    /// - Parameters:
    ///   - partIds: The member's own, live part ids.
    ///   - excludedPartIds: Part ids excluded by this member's split rule.
    /// - Returns: `"1 square"` or `"N squares"`.
    static func splitSquaresNote(partIds: [String], excludedPartIds: Set<String>) -> String {
        let included = Swift.max(1, partIds.filter { !excludedPartIds.contains($0) }.count)
        return included == 1 ? "1 square" : "\(included) squares"
    }

    /// How many more occurrences a counting member's goal needs this window,
    /// given how many windows already ran — the one-off wizard's "remaining"
    /// prefill and a recurring-series countdown note. Floors at 1 so the note
    /// never reads "0 more".
    ///
    /// - Parameters:
    ///   - goal: The member's own `maxCount`.
    ///   - windowCount: Progress toward the goal already made in the window.
    /// - Returns: The remaining target (integer ≥ 1).
    static func remainingTarget(goal: Int, windowCount: Int) -> Int {
        Swift.max(1, goal - windowCount)
    }

    // MARK: - Collapsed-row summaries (B3.1)

    /// What a collapsed member row shows in place of its controls — the
    /// row's current answer, never a second control. TS twin:
    /// `MemberSummary` in `memberRulesDisplay.ts`.
    struct MemberSummary: Equatable {
        /// The chip's text.
        let text: String
        /// True when this member's dice is lit — the row tints the chip
        /// `risoBlue` rather than `risoMuted`.
        let varying: Bool
    }

    /// Collapsed-row summary for a counting member: the vary range when the
    /// dice is lit, otherwise the plain target (with its unit, when it has
    /// one). Dispatches to ``varyRangeLabel(t:level:goal:unit:)`` so the chip
    /// and the expanded row's blue range line can never disagree.
    ///
    /// - Parameters:
    ///   - target: The pre-vary target (see ``effectiveMemberTarget``).
    ///   - level: The member's vary level.
    ///   - goal: The member's own `maxCount`, the hard ceiling.
    ///   - unit: The counting member's unit, or `""` when it has none.
    /// - Returns: The chip's text and whether the dice is lit.
    static func countingSummary(target: Int, level: VaryLevel, goal: Int, unit: String) -> MemberSummary {
        if let range = varyRangeLabel(t: target, level: level, goal: goal, unit: unit) {
            return MemberSummary(text: range, varying: true)
        }
        return MemberSummary(text: unit.isEmpty ? "\(target)" : "\(target) \(unit)", varying: false)
    }

    /// Collapsed-row summary for a compound member: how many squares it
    /// contributes. While split the dice lives on the parts, so the
    /// member-level chip never reports varying; while One square the
    /// member's dice rolls for the whole square.
    ///
    /// - Parameters:
    ///   - split: Whether the member is in Split up mode.
    ///   - partIds: The member's own, live part ids.
    ///   - excludedPartIds: Part ids excluded by this member's split rule.
    ///   - level: The member's own vary level.
    /// - Returns: The chip's text and whether the dice is lit.
    static func compoundSummary(
        split: Bool,
        partIds: [String],
        excludedPartIds: Set<String>,
        level: VaryLevel
    ) -> MemberSummary {
        if split {
            return MemberSummary(
                text: splitSquaresNote(partIds: partIds, excludedPartIds: excludedPartIds),
                varying: false
            )
        }
        return MemberSummary(text: "1 square", varying: level != .off)
    }

    /// The delete-confirm line warning that window-stamped derived counters
    /// made from this task will go with it (B3 RC12).
    ///
    /// Copy is VERBATIM from web's `CounterDeleteConfirmDialog` — singular
    /// "counter" at one, plural otherwise. Lives here so the two iOS confirm
    /// sheets (`CounterDeleteConfirmView`, `TaskDeleteConfirmView`) can never
    /// word it differently from each other or from web.
    ///
    /// - Parameter count: `TaskDeletionImpact.derivedWindowCounterCount`.
    /// - Returns: The sentence, or `nil` when there is nothing to warn about.
    static func derivedCounterRemovalNote(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) board counter\(count == 1 ? "" : "s") made from this one will be removed."
    }

    // MARK: - Rule accessors

    /// Read a member's rule off a source, never nil — an absent rule reads as
    /// an all-nil `BoardSourceMemberRule`, so a caller can read `.target` /
    /// `.vary` / `.split` straight off the result.
    ///
    /// - Parameters:
    ///   - taskId: The member's task id.
    ///   - source: The `BoardSource` the member was pulled through.
    /// - Returns: The stored rule, or an empty rule when there isn't one.
    static func memberRule(for taskId: String, in source: BoardSource) -> BoardSourceMemberRule {
        source.memberRules?[taskId] ?? BoardSourceMemberRule()
    }

    /// Read a part's rule off its parent member rule, never nil.
    ///
    /// - Parameters:
    ///   - childId: The part's `compound_children.childTaskId`.
    ///   - rule: The parent member's rule (from ``memberRule(for:in:)``).
    /// - Returns: The stored part rule, or an empty part rule.
    static func partRule(for childId: String, in rule: BoardSourceMemberRule) -> BoardSourcePartRule {
        rule.parts?[childId] ?? BoardSourcePartRule()
    }

    // MARK: - Immutable setters

    /// One field of a rule patch. Three-state on purpose: Swift cannot tell
    /// "field absent from the patch" from "field explicitly cleared" with a
    /// plain `Value?`, which is exactly the distinction TS expresses by
    /// passing `undefined` to delete a key. `.keep` leaves the stored value
    /// alone, `.clear` removes it, `.set` overwrites it.
    enum RulePatchField<Value> {
        case keep
        case clear
        case set(Value)

        /// Apply this field to a current value.
        func applied(to current: Value?) -> Value? {
            switch self {
            case .keep: return current
            case .clear: return nil
            case .set(let value): return value
            }
        }
    }

    /// A patch over one member's rule — see ``RulePatchField``.
    struct MemberRulePatch {
        var target: RulePatchField<Int> = .keep
        var vary: RulePatchField<VaryLevel> = .keep
        var split: RulePatchField<Bool> = .keep
        var parts: RulePatchField<[String: BoardSourcePartRule]> = .keep

        init(
            target: RulePatchField<Int> = .keep,
            vary: RulePatchField<VaryLevel> = .keep,
            split: RulePatchField<Bool> = .keep,
            parts: RulePatchField<[String: BoardSourcePartRule]> = .keep
        ) {
            self.target = target
            self.vary = vary
            self.split = split
            self.parts = parts
        }
    }

    /// A patch over one part's rule — see ``RulePatchField``.
    struct PartRulePatch {
        var target: RulePatchField<Int> = .keep
        var vary: RulePatchField<VaryLevel> = .keep
        var excluded: RulePatchField<Bool> = .keep

        init(
            target: RulePatchField<Int> = .keep,
            vary: RulePatchField<VaryLevel> = .keep,
            excluded: RulePatchField<Bool> = .keep
        ) {
            self.target = target
            self.vary = vary
            self.excluded = excluded
        }
    }

    /// `vary == .off` / `split == false` are the field defaults — pruned so a
    /// rule carrying only defaults reads as empty and is dropped by the
    /// setters below.
    ///
    /// An empty `parts` map is deliberately NOT pruned here: the TS twin's
    /// `pruneMemberRule` doesn't either, and matching it byte-for-byte
    /// matters more than the marginally tidier alternative. `withPartRule`
    /// normalises an emptied `parts` to nil on its own before calling this,
    /// so the only way to reach a stored `parts: {}` is an explicit
    /// `.set([:])` — which no caller makes on either platform.
    private static func pruned(_ rule: BoardSourceMemberRule) -> BoardSourceMemberRule {
        var out = rule
        if out.vary == .off { out.vary = nil }
        if out.split == false { out.split = nil }
        return out
    }

    /// `vary == .off` / `excluded == false` are the field defaults — pruned
    /// the same way as ``pruned(_:)`` above.
    private static func pruned(_ rule: BoardSourcePartRule) -> BoardSourcePartRule {
        var out = rule
        if out.vary == .off { out.vary = nil }
        if out.excluded == false { out.excluded = nil }
        return out
    }

    /// True when every field of the rule is absent — nothing left to store.
    private static func isEmpty(_ rule: BoardSourceMemberRule) -> Bool {
        rule.target == nil && rule.vary == nil && rule.split == nil && rule.parts == nil
    }

    /// True when every field of the part rule is absent.
    private static func isEmpty(_ rule: BoardSourcePartRule) -> Bool {
        rule.target == nil && rule.vary == nil && rule.excluded == nil
    }

    /// Store `rules` back on `source`, dropping the whole `memberRules` key
    /// when the map came out empty (so a rule-less source serialises
    /// byte-identically whether or not the rule editor ever touched it).
    private static func withRules(
        _ source: BoardSource,
        _ rules: [String: BoardSourceMemberRule]
    ) -> BoardSource {
        var out = source
        out.memberRules = rules.isEmpty ? nil : rules
        return out
    }

    /// Immutably set (or clear) fields of ONE member's rule on `source`.
    ///
    /// A `.clear` field deletes that field; the merged rule is then pruned of
    /// default values (`vary .off`, `split false`, an empty `parts`) — so
    /// patching a rule back to all-defaults, or clearing every field it had,
    /// leaves NO entry for `taskId`, and clearing the last rule on a source
    /// drops the `memberRules` key entirely.
    ///
    /// - Parameters:
    ///   - source: The source to update (a value type — never mutated).
    ///   - taskId: The member's task id.
    ///   - patch: Fields to set / clear.
    /// - Returns: A new `BoardSource` with the rule applied.
    static func withMemberRule(
        _ source: BoardSource,
        taskId: String,
        patch: MemberRulePatch
    ) -> BoardSource {
        let current = memberRule(for: taskId, in: source)
        var merged = BoardSourceMemberRule(
            target: patch.target.applied(to: current.target),
            vary: patch.vary.applied(to: current.vary),
            split: patch.split.applied(to: current.split),
            parts: patch.parts.applied(to: current.parts)
        )
        merged = pruned(merged)
        var rules = source.memberRules ?? [:]
        if isEmpty(merged) {
            rules.removeValue(forKey: taskId)
        } else {
            rules[taskId] = merged
        }
        return withRules(source, rules)
    }

    /// Immutably set (or clear) fields of ONE part's rule, nested under its
    /// parent member's rule on `source`. Same emptiness pruning as
    /// ``withMemberRule(_:taskId:patch:)``, applied at both levels: a cleared
    /// part drops out of `parts`, an empty `parts` drops out of the member
    /// rule, an all-default-or-empty member rule drops out of `memberRules`,
    /// and an empty `memberRules` drops off the source entirely.
    ///
    /// - Parameters:
    ///   - source: The source to update (a value type — never mutated).
    ///   - taskId: The parent compound member's task id.
    ///   - childId: The part's `compound_children.childTaskId`.
    ///   - patch: Fields to set / clear.
    /// - Returns: A new `BoardSource` with the part rule applied.
    static func withPartRule(
        _ source: BoardSource,
        taskId: String,
        childId: String,
        patch: PartRulePatch
    ) -> BoardSource {
        let currentRule = memberRule(for: taskId, in: source)
        let currentPart = partRule(for: childId, in: currentRule)
        let mergedPart = pruned(BoardSourcePartRule(
            target: patch.target.applied(to: currentPart.target),
            vary: patch.vary.applied(to: currentPart.vary),
            excluded: patch.excluded.applied(to: currentPart.excluded)
        ))

        var parts = currentRule.parts ?? [:]
        if isEmpty(mergedPart) {
            parts.removeValue(forKey: childId)
        } else {
            parts[childId] = mergedPart
        }

        var mergedRule = currentRule
        mergedRule.parts = parts.isEmpty ? nil : parts
        mergedRule = pruned(mergedRule)

        var rules = source.memberRules ?? [:]
        if isEmpty(mergedRule) {
            rules.removeValue(forKey: taskId)
        } else {
            rules[taskId] = mergedRule
        }
        return withRules(source, rules)
    }

    // MARK: - Wizard-level transitions

    /// Apply a member-rule patch to ONE source row of `sources` (every other
    /// row passes through untouched). A patch for a source that isn't pulled
    /// is a no-op. Web twin: `withMemberRuleInSource`.
    ///
    /// - Parameters:
    ///   - sources: The current source rows.
    ///   - sourceId: The row the member was pulled through.
    ///   - taskId: The member's task id.
    ///   - patch: Fields to set / clear.
    /// - Returns: The next rows.
    static func withMemberRuleInSource(
        _ sources: [BoardSource],
        sourceId: String,
        taskId: String,
        patch: MemberRulePatch
    ) -> [BoardSource] {
        sources.map { source in
            source.sourceId == sourceId
                ? withMemberRule(source, taskId: taskId, patch: patch)
                : source
        }
    }

    /// Apply a PART-rule patch to ONE source row. Web twin:
    /// `withPartRuleInSource`.
    ///
    /// - Parameters:
    ///   - sources: The current source rows.
    ///   - sourceId: The row the parent member was pulled through.
    ///   - taskId: The parent compound member's task id.
    ///   - childId: The part's `compound_children.childTaskId`.
    ///   - patch: Fields to set / clear.
    /// - Returns: The next rows.
    static func withPartRuleInSource(
        _ sources: [BoardSource],
        sourceId: String,
        taskId: String,
        childId: String,
        patch: PartRulePatch
    ) -> [BoardSource] {
        sources.map { source in
            source.sourceId == sourceId
                ? withPartRule(source, taskId: taskId, childId: childId, patch: patch)
                : source
        }
    }

    /// The parts of a split member that currently contribute a square — the
    /// member's live part ids minus the ones its rule excludes. Stale
    /// excluded ids subtract nothing, matching ``applyMemberRules``.
    ///
    /// - Parameters:
    ///   - rule: The member's rule.
    ///   - partIds: The member's own, live part ids.
    /// - Returns: The included part ids, in `partIds` order.
    static func includedPartIds(rule: BoardSourceMemberRule, partIds: [String]) -> [String] {
        partIds.filter { partRule(for: $0, in: rule).excluded != true }
    }

    /// Whether excluding `childId` is allowed — a split member always
    /// contributes at least one square, so the LAST included part can't be
    /// excluded (``applyMemberRules``' own last-part guard would silently
    /// ignore it, which reads as a broken toggle). Un-excluding is always
    /// allowed. Web twin: `canSetPartExcluded`.
    ///
    /// - Parameters:
    ///   - rule: The member's rule.
    ///   - partIds: The member's own, live part ids.
    ///   - childId: The part being toggled.
    ///   - excluded: The requested state.
    /// - Returns: True when the toggle may be applied.
    static func canSetPartExcluded(
        rule: BoardSourceMemberRule,
        partIds: [String],
        childId: String,
        excluded: Bool
    ) -> Bool {
        guard excluded else { return true }
        let included = includedPartIds(rule: rule, partIds: partIds)
        // Already excluded — an idempotent no-op, never a refusal.
        guard included.contains(childId) else { return true }
        return included.count > 1
    }

    /// RC14 exclusivity — drop a member's PART rules once the member itself
    /// is excluded from a source. A member that supplies nothing must not
    /// keep stale per-part state: re-including it later starts from a clean
    /// split, not from whichever parts were suppressed in a past session.
    /// `split` itself is kept (it is the member's shape, not per-part state).
    /// A no-op when the member is NOT excluded in that source, so a caller
    /// can run it unconditionally after a toggle. Web twin:
    /// `pruneRulesForExcludedMember`.
    ///
    /// - Parameters:
    ///   - sources: The current source rows (post-toggle).
    ///   - sourceId: The row the member was pulled through.
    ///   - taskId: The member just toggled.
    /// - Returns: The next rows (the input rows when there was nothing to prune).
    static func pruneRulesForExcludedMember(
        _ sources: [BoardSource],
        sourceId: String,
        taskId: String
    ) -> [BoardSource] {
        guard let index = sources.firstIndex(where: { $0.sourceId == sourceId }) else {
            return sources
        }
        let source = sources[index]
        guard source.excludedTaskIds.contains(taskId),
              memberRule(for: taskId, in: source).parts != nil
        else { return sources }
        var next = sources
        next[index] = withMemberRule(source, taskId: taskId, patch: MemberRulePatch(parts: .clear))
        return next
    }

    /// Set a HAND-ADDED counter's dice level. Level `.off` is the field
    /// default, so it is stored as an ABSENCE — keeping the map identical to
    /// one that was never touched.
    ///
    /// Dice belong to counting rows only (spec §Member rules), and the STATE
    /// layer is the guard — not just the UI: a level written for a normal,
    /// compound or achievement task would serialise onto the record and read
    /// as authored intent forever. A non-counting (or unknown) task is a
    /// no-op. Web twin: `withManualVary`.
    ///
    /// - Parameters:
    ///   - manualTaskVary: The current map.
    ///   - taskId: The hand-added task.
    ///   - level: The new dice level.
    ///   - task: That task, for the counting guard (nil = unknown → no-op).
    /// - Returns: The next map (the input map when the write was refused).
    static func withManualVary(
        _ manualTaskVary: [String: VaryLevel],
        taskId: String,
        level: VaryLevel,
        task: Task?
    ) -> [String: VaryLevel] {
        guard task?.type == .counting else { return manualTaskVary }
        var next = manualTaskVary
        if level == .off {
            next.removeValue(forKey: taskId)
        } else {
            next[taskId] = level
        }
        return next
    }

    /// Drop a task's dice when it LEAVES the hand-added layer (deselect /
    /// remove). Unguarded on purpose — this is the purge half, and a stale
    /// entry for a task that is no longer counting (or no longer exists) is
    /// exactly what must go. Without it the entry survives into the draft
    /// blob and onto `RecurringBoardTemplate.manualTaskVary`. Web twin:
    /// `pruneManualVary`.
    ///
    /// - Parameters:
    ///   - manualTaskVary: The current map.
    ///   - taskId: The task leaving the manual layer.
    /// - Returns: The next map (the input map when there was nothing to drop).
    static func pruneManualVary(
        _ manualTaskVary: [String: VaryLevel],
        taskId: String
    ) -> [String: VaryLevel] {
        guard manualTaskVary[taskId] != nil else { return manualTaskVary }
        var next = manualTaskVary
        next.removeValue(forKey: taskId)
        return next
    }

    /// Whether a supplied task may be DESELECTED from the wizard's square
    /// list. Only one thing can refuse: a task that entered the supply as a
    /// Split-up PART and is the last included part of its compound — a split
    /// member always contributes at least one square, so excluding it would
    /// be ignored by ``applyMemberRules``' last-part guard and the square
    /// would come straight back on the next selection recompute (a
    /// self-reverting control, the late-mutation shape this codebase bans).
    /// Web twin: `canDeselectFromSources`.
    ///
    /// - Parameters:
    ///   - supplies: The Split-up-expanded supplies.
    ///   - childrenByCompoundId: The live compound-children map.
    ///   - taskId: The id being deselected.
    /// - Returns: False when the deselect must be refused.
    static func canDeselectFromSources(
        supplies: [ExpandedSupply],
        childrenByCompoundId: [String: [CompoundChild]],
        taskId: String
    ) -> Bool {
        for supply in supplies {
            guard let parentId = supply.partOf[taskId] else { continue }
            let partIds = (childrenByCompoundId[parentId] ?? []).map { $0.childTaskId }
            if !canSetPartExcluded(
                rule: memberRule(for: parentId, in: supply.source),
                partIds: partIds,
                childId: taskId,
                excluded: true
            ) {
                return false
            }
        }
        return true
    }
}
