import SwiftUI

/// How a pulled member currently participates in the board being assembled.
/// Web twin: `MemberState` in `MemberRuleRow.tsx`.
enum MemberRuleRowState {
    case included
    case excluded
    case filteredDone
}

/// The pure presentation model behind one member row — every "what shows,
/// and with what number in it" decision, resolved once from the member's
/// task, its stored rule and the two windows.
///
/// Extracted from the view so the decisions that are easy to get subtly
/// wrong (which controls a pool member gets, what a One-square compound's
/// note says, whether the last included part still offers a ✕) are unit
/// testable without mounting SwiftUI. Web has no twin struct — its
/// equivalents are inline consts in `MemberRuleRow.tsx` — so the SHAPE is
/// iOS-local; every value it computes comes from the shared
/// `BoardSources` helpers, which are vector-pinned across platforms.
struct MemberRuleRowModel: Equatable {

    /// What a member (or part) with no resolved task renders as — the
    /// mid-hydration case. Web literal (`MemberRuleRow.tsx`), shared by
    /// the title, the part names and every accessibility label so none of
    /// them can read as "Exclude  for this board".
    static let untitledTask = "(untitled task)"

    /// One part of a Split-up-capable compound member.
    struct Part: Equatable {
        let childId: String
        let name: String
        /// True when the part is currently suppressed (split mode only).
        let excluded: Bool
        /// The part's own `maxCount` when counting, else 0 — the stepper's
        /// ceiling and the number the caption quotes.
        let goal: Int
        /// Pro-rated (or explicit) target — meaningful only with a stepper.
        let target: Int
        /// The part's own dice level: its own in split mode, the parent's
        /// while One square (where the parent rolls for the whole square).
        let level: VaryLevel
        let showsStepper: Bool
        /// "of 210" — present exactly when the stepper is.
        let caption: String?
        let showsDice: Bool
        /// Hidden (not disabled) on the last included part — an inert ✕
        /// reads as a broken toggle, and the state layer would refuse it.
        let showsExclude: Bool
        /// Blue range line under this part's line; nil at vary `.off`.
        let rangeLabel: String?
    }

    /// Rule controls belong to members actually going on the board. An
    /// excluded / filtered-done member renders exactly what it did before
    /// B3 — editing a target for a square that isn't being placed is the
    /// same contradiction the part rows already avoid.
    let isOn: Bool
    /// The member's own dice level (also the One-square compound's).
    let memberVary: VaryLevel
    /// The member's `maxCount` when counting, else 0.
    let goal: Int
    /// Pro-rated (or explicit) target — meaningful only with a stepper.
    let target: Int
    /// Board sources only: a pool member has no window to pro-rate
    /// against, so it gets the dice alone (RC5).
    let showsStepper: Bool
    /// "/ 35 mi" — folded into the stepper pill (B3.1); present exactly
    /// when the stepper is. Was `caption`, a separate label beside the
    /// stepper, before B3.1.
    let targetSuffix: String?
    let showsDice: Bool
    /// Blue range line under the main row; nil at vary `.off`.
    let rangeLabel: String?
    /// A compound WITH children — a childless compound is a plain member.
    let isCompound: Bool
    let isSplit: Bool
    /// "1 square" / "N squares" beside the One square / Split up toggle.
    let squaresNote: String?
    /// One square rolls one dice for the whole compound, on the toggle
    /// line; Split up moves the dice onto the individual parts.
    let showsSplitLineDice: Bool
    /// True when this row has rule controls to disclose — a counting
    /// member, or a compound WITH parts, that is actually going on the
    /// board. A plain, excluded or filtered-done member has nothing to
    /// reveal and stays a single tappable-free line (B3.1).
    let isExpandable: Bool
    /// What the collapsed row shows in place of its controls, or nil when
    /// it shows nothing there: always nil for a non-expandable row, and
    /// also nil for a counting member whose chip would only restate its
    /// own auto-generated title (`vary off && target == goal`) — see
    /// ``BoardSources/countingSummary(target:level:goal:unit:)``. A row
    /// with no chip is still expandable: it has controls, it just has no
    /// answer worth repeating.
    let summary: BoardSources.MemberSummary?
    let parts: [Part]

    /// Resolve the row's model.
    ///
    /// - Parameters:
    ///   - task: The member's task (staged-overlaid), or nil mid-hydration.
    ///   - taskById: Title lookup, for compound part names.
    ///   - state: Whether the member is on the board, excluded, or done.
    ///   - rule: The member's stored rule (empty when it has none).
    ///   - parts: The member's `compound_children`. Empty = plain member.
    ///   - fromBoard: True when the supplying source is `kind == .board`.
    ///   - sourceWindow: The source board's own window, for pro-rating.
    ///   - wizardWindow: The window of the board being assembled.
    ///   - mode: Whether that board is one-off or repeating.
    init(
        task: Task?,
        taskById: [String: Task],
        state: MemberRuleRowState,
        rule: BoardSourceMemberRule,
        parts: [CompoundChild],
        fromBoard: Bool,
        sourceWindow: BoardSources.BoardWindow?,
        wizardWindow: BoardSources.BoardWindow,
        mode: BoardSources.PlanMode
    ) {
        let isOn = state == .included
        self.isOn = isOn
        let memberVary = rule.vary ?? .off
        self.memberVary = memberVary

        let goal = task?.type == .counting ? (task?.maxCount ?? 0) : 0
        self.goal = goal
        let isCounting = goal > 0
        let unit = task?.unit ?? ""
        let target = isCounting
            ? BoardSources.effectiveMemberTarget(
                goal: goal,
                explicit: rule.target,
                mode: mode,
                fromBoard: fromBoard,
                sourceWindow: sourceWindow,
                targetWindow: wizardWindow
            )
            : 0
        self.target = target
        let showsStepper = isOn && isCounting && fromBoard
        self.showsStepper = showsStepper
        self.targetSuffix = showsStepper
            ? "/ \(goal)\(unit.isEmpty ? "" : " \(unit)")"
            : nil
        self.showsDice = isOn && isCounting
        self.rangeLabel = (isOn && isCounting)
            ? BoardSources.varyRangeLabel(t: target, level: memberVary, goal: goal, unit: unit)
            : nil

        // `childIndex` order — the same order `applyMemberRules` expands a
        // split member in, so the lines match the squares it produces.
        let orderedParts = parts.sorted { $0.childIndex < $1.childIndex }
        let isCompound = task?.type == .compound && !orderedParts.isEmpty
        self.isCompound = isCompound
        let isSplit = rule.split == true
        self.isSplit = isSplit

        let partIds = orderedParts.map { $0.childTaskId }
        let excludedPartIds = Set(
            partIds.filter { BoardSources.partRule(for: $0, in: rule).excluded == true }
        )
        self.squaresNote = (isOn && isCompound)
            ? (isSplit
                ? BoardSources.splitSquaresNote(partIds: partIds, excludedPartIds: excludedPartIds)
                : "1 square")
            : nil
        self.showsSplitLineDice = isOn && isCompound && !isSplit

        // B3.1: the row collapses its controls behind a disclosure, so it
        // needs to know whether it HAS any, and what to say in their place
        // while closed. Both summaries come from the shared, vector-pinned
        // `BoardSources` helpers — never formatted here.
        let isExpandable = isOn && (isCounting || isCompound)
        self.isExpandable = isExpandable
        self.summary = !isExpandable ? nil
            : isCompound
                ? BoardSources.compoundSummary(
                    split: isSplit,
                    partIds: partIds,
                    excludedPartIds: excludedPartIds,
                    level: memberVary
                )
                : BoardSources.countingSummary(
                    target: target, level: memberVary, goal: goal, unit: unit
                )

        guard isOn, isCompound else {
            self.parts = []
            return
        }
        // Mirrors web's `canExclude`: the LAST included part keeps no ✕.
        let canExcludeAny = orderedParts.count - excludedPartIds.count > 1
        self.parts = orderedParts.map { link in
            let childId = link.childTaskId
            let partRule = BoardSources.partRule(for: childId, in: rule)
            let childTask = taskById[childId]
            let partGoal = childTask?.type == .counting ? (childTask?.maxCount ?? 0) : 0
            let partIsCounting = partGoal > 0
            let level: VaryLevel = isSplit ? (partRule.vary ?? .off) : memberVary
            let partTarget = partIsCounting
                ? BoardSources.effectiveMemberTarget(
                    goal: partGoal,
                    explicit: partRule.target,
                    mode: mode,
                    fromBoard: fromBoard,
                    sourceWindow: sourceWindow,
                    targetWindow: wizardWindow
                )
                : 0
            let showsStepper = partIsCounting && fromBoard
            return Part(
                childId: childId,
                name: childTask?.title ?? MemberRuleRowModel.untitledTask,
                excluded: isSplit && partRule.excluded == true,
                goal: partGoal,
                target: partTarget,
                level: level,
                showsStepper: showsStepper,
                caption: showsStepper ? "of \(partGoal)" : nil,
                showsDice: partIsCounting && isSplit,
                showsExclude: isSplit && canExcludeAny,
                rangeLabel: partIsCounting
                    ? BoardSources.varyRangeLabel(
                        t: partTarget, level: level, goal: partGoal, unit: ""
                    )
                    : nil
            )
        }
    }
}

/// RisoMemberRuleRowView — one member row inside an expanded source panel,
/// with the per-member rule controls (docs/BOARD_SOURCES.md §Member rules;
/// handoff "Expanded source panel" item 3).
///
/// Three shapes, all driven by the member's own type. B3.1 collapses the
/// first two behind a disclosure: at 393pt the B3 inline layout left the
/// title ~102pt ("Run 30 M…"), so the controls now live on a second line
/// the whole row rect reveals.
///
/// - **Counting** — collapsed: badge · title · summary chip · chevron,
///   with the ✕ overlaid on the trailing edge. Expanded adds line 2 at
///   the 69pt indent: compact stepper (board sources only, its goal
///   folded into the pill as "/ {goal} {unit}") · dice · the blue vary
///   range INLINE, never on a third line.
/// - **Compound with parts** — the same collapsed line; expanded reveals
///   the One square / Split up pill plus the "N squares" note (dice on
///   that line only while One square), then one line per part: name ·
///   stepper · "of {goal}" · dice and ✕ while split. Parts stay single
///   line — a part name has ~155pt at the indent.
/// - **Anything else** (normal, achievement, childless compound, and
///   EVERY excluded or filtered-done member) — no disclosure at all: just
///   the title and the shared exclude control, inline exactly as in B3.
///
/// Owns the whole row (not just the rule strip) so `RisoSourceRowView`
/// stays a header + range-block renderer. Web twin: `MemberRuleRow.tsx`.
struct RisoMemberRuleRowView: View {

    /// The member's task (staged-overlaid), or nil mid-hydration.
    let task: Task?
    /// Title lookup, for compound part names.
    let taskById: [String: Task]
    let state: MemberRuleRowState
    /// Counter-family exclusivity hint ("shares a counter with …").
    var clashTitle: String? = nil
    /// This member's stored rule — an empty rule when it has none.
    let rule: BoardSourceMemberRule
    /// The member's `compound_children`. Empty = plain member.
    var parts: [CompoundChild] = []
    /// True when the supplying source is `kind == .board`.
    let fromBoard: Bool
    /// The source board's own window, for pro-rating an auto target.
    var sourceWindow: BoardSources.BoardWindow? = nil
    /// The window of the board being assembled.
    let wizardWindow: BoardSources.BoardWindow
    /// Whether the board being assembled is one-off or repeating.
    let mode: BoardSources.PlanMode

    let onToggleExclude: () -> Void
    let onSetTarget: (Int?) -> Void
    let onSetVary: (VaryLevel) -> Void
    let onSetSplit: (Bool) -> Void
    let onSetPartExcluded: (_ childId: String, _ excluded: Bool) -> Void
    let onSetPartTarget: (_ childId: String, _ target: Int?) -> Void
    let onSetPartVary: (_ childId: String, _ level: VaryLevel) -> Void

    /// Seeds the disclosure OPEN on first render. Snapshot use only —
    /// production always opens collapsed (B3.1), so every call site leaves
    /// this at its default.
    var initiallyExpanded: Bool = false

    /// The 69pt indent range lines / the split line / part lines sit at:
    /// the row's own 40pt leading padding plus 20pt badge + 8pt gap + 1pt.
    private static let indent: CGFloat = 29

    /// Disclosure state, owned by the row: every row opens collapsed, so
    /// row height never depends on stored rules and a long source stays
    /// scannable (B3.1). The chip keeps a saved rule legible closed.
    ///
    /// Held as an optional OVERRIDE rather than a seeded `@State` so
    /// `initiallyExpanded` needs no 18-parameter explicit init; nil until
    /// the person taps, after which the seed no longer applies.
    @State private var expandedOverride: Bool? = nil

    /// Whether the controls line is currently revealed — the person's own
    /// choice once they have made one, else the (snapshot-only) seed.
    ///
    /// - Returns: True while the controls line should render.
    private var isExpanded: Bool { expandedOverride ?? initiallyExpanded }

    /// The disclosure's spoken label: the title, plus the counter-clash
    /// warning when there is one.
    ///
    /// Under `.accessibilityElement(children: .contain)` the children stay
    /// reachable as their own elements, so folding the warning in is a
    /// choice, not a rescue — the row states its own warning as part of
    /// itself instead of only on a separate swipe. Because the child is
    /// still there, `mainLine` hides the clash `Text` from VoiceOver on
    /// exactly the rows that fold it in, so it is announced once rather
    /// than twice.
    ///
    /// - Returns: The title, plus the clash sentence when there is one.
    private var accessibilityTitle: String {
        guard let clashTitle else { return title }
        return "\(title), shares a counter with \u{201C}\(clashTitle)\u{201D} · one per board"
    }

    private var model: MemberRuleRowModel {
        MemberRuleRowModel(
            task: task,
            taskById: taskById,
            state: state,
            rule: rule,
            parts: parts,
            fromBoard: fromBoard,
            sourceWindow: sourceWindow,
            wizardWindow: wizardWindow,
            mode: mode
        )
    }

    private var title: String { task?.title ?? MemberRuleRowModel.untitledTask }

    var body: some View {
        let model = self.model
        VStack(alignment: .leading, spacing: 0) {
            // The disclosure carries the row's own padding so the WHOLE
            // row rect is the hit area — a short title must not leave a
            // dead row. `.contentShape` is load-bearing: without it a
            // SwiftUI HStack label takes taps only on its opaque children.
            if model.isExpandable {
                mainLine(model)
                    .padding(.vertical, 7)
                    .padding(.leading, 40)
                    // 39 = the overlaid ✕'s 28 plus the row's own 11, so
                    // the chevron never sits under it and the ✕ lands at
                    // the same x as a non-expandable row's inline one.
                    .padding(.trailing, 39)
                    .contentShape(Rectangle())
                    .onTapGesture { expandedOverride = !isExpanded }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(accessibilityTitle)
                    .accessibilityValue(model.summary?.text ?? "")
                    .accessibilityHint(isExpanded ? "Collapse rule controls" : "Expand rule controls")
                    .accessibilityAddTraits(.isButton)
            } else {
                mainLine(model)
                    .padding(.vertical, 7)
                    .padding(.leading, 40)
                    .padding(.trailing, 11)
            }

            if model.isExpandable, isExpanded {
                // One block, one rhythm: 4pt between the controls line and
                // each part line, 8pt under the whole thing — so a
                // compound's last part gets the same breathing room a
                // counting row's controls line does and never crowds the
                // next row's hairline.
                VStack(alignment: .leading, spacing: 4) {
                    controlsLine(model)
                    if model.isCompound {
                        ForEach(model.parts, id: \.childId) { part in
                            partLine(part)
                        }
                    }
                }
                .padding(.leading, 40 + Self.indent)
                .padding(.trailing, 11)
                .padding(.bottom, 8)
            }
        }
        .opacity(state == .included ? 1 : 0.45)
        // Pre-flight ruling C2: ONLY an expandable row overlays its
        // trailing control into the 39pt gutter. The ✕ (28pt) and ✓ (22pt)
        // fit; the excluded state's UNDO pill (~60pt) does not — and a
        // non-expandable row needs no full-rect hit area anyway, so it
        // keeps its pre-B3.1 inline control and 11pt trailing padding.
        // Both paddings are the row's OWN padding, so the overlaid ✕ lands
        // exactly where the inline one does on a non-expandable row above
        // or below it. Trailing 11: the main line reserves 39 = 28 + 11.
        // Top 7: the row's vertical padding, so the ✕ occupies 7…35 in a
        // 42pt row either way. (Top 4 was calibrated against the badge-
        // driven ~34pt row that existed before `minHeight: 28`, and left
        // the ✕ ~3pt high once the row grew — and would drift further on a
        // counter-clash row, whose two-line title makes the row taller
        // still while an absolute top padding stays put.)
        .overlay(alignment: .topTrailing) {
            if model.isExpandable { trailingControl.padding(.trailing, 11).padding(.top, 7) }
        }
        .overlay(alignment: .top) { hairline }
        // M4: a row that was expanded, then excluded, must not come back
        // expanded on UNDO — "always collapsed on open" is a rule about
        // the row's whole lifecycle, not just first render.
        .onChange(of: state) { _, newState in
            if newState != .included { expandedOverride = nil }
        }
    }

    /// The 1.5pt hair top border every member row carries (there is no
    /// `Color.risoHair` token — this is the source row's own hairline at
    /// the same effective 14 % ink).
    private var hairline: some View {
        Rectangle()
            .fill(Color.risoInk.opacity(0.24))
            .frame(height: Riso.Keyline.dense)
            .opacity(0.6)
    }

    // MARK: - Main line

    private func mainLine(_ model: MemberRuleRowModel) -> some View {
        HStack(spacing: 8) {
            RisoTypeBadge(
                kind: RisoTaskKind(taskType: task?.type ?? .normal),
                style: .letterSquare
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.risoBody(13, .semibold))
                    .foregroundStyle(Color.risoInk)
                    .strikethrough(state == .excluded)
                    .lineLimit(1)
                if let clashTitle {
                    Text("shares a counter with \u{201C}\(clashTitle)\u{201D} · one per board")
                        .font(.risoBody(10.5, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                        // Announced once. An expandable row folds this
                        // sentence into `accessibilityTitle`, and `.contain`
                        // would otherwise leave the child readable too. A
                        // NON-expandable row has no container label — an
                        // excluded counting member can still clash — so
                        // there the child stays the only announcement.
                        .accessibilityHidden(model.isExpandable)
                }
            }
            Spacer(minLength: 6)
            // The row's current answer, never a second control: the vary
            // range while the dice is lit, else the target / square count.
            if let summary = model.summary, !isExpanded {
                Text(summary.text)
                    .font(.risoBody(10.5, .bold))
                    .foregroundStyle(summary.varying ? Color.risoBlue : Color.risoMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
            if model.isExpandable {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(width: 14)
            } else {
                // Ruling C2: a non-expandable row keeps its inline control
                // (an UNDO pill would not fit the expandable overlay's
                // 39pt gutter).
                trailingControl
            }
        }
        // Every row in a panel shares a height. Before B3.1 that fell out
        // of the inline 28pt ✕; moving it to an overlay on EXPANDABLE rows
        // only would leave their 20pt badge setting the height, mixing
        // ~34pt and ~42pt rows in one list. Pinning the pre-B3.1 control
        // height restores B3 exactly for an INCLUDED row (28 + 7 + 7 = 42)
        // and deliberately LIFTS the two states that were already shorter
        // than that — filtered-done's 22pt ✓ and excluded's ~24pt UNDO
        // pill — so the list is uniform rather than merely unchanged.
        .frame(minHeight: 28)
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch state {
        case .included:
            Button(action: onToggleExclude) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exclude \(title) for this board")
        case .excluded:
            Button(action: onToggleExclude) {
                Text("UNDO")
                    .font(.risoBody(11.5, .extraBold))
                    .foregroundStyle(Color.risoInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(
                        Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo excluding \(title)")
        case .filteredDone:
            Circle()
                .strokeBorder(Color.risoGreen, lineWidth: Riso.Keyline.container)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.risoGreen)
                )
                .accessibilityElement()
                .accessibilityLabel("\(title) is done")
        }
    }

    // MARK: - Range line

    private func rangeLine(_ text: String) -> some View {
        Text(text)
            .font(.risoBody(10.5, .semibold))
            .foregroundStyle(Color.risoBlue)
    }

    // MARK: - Expanded: the controls line

    /// The expanded row's second line: the target pill (board sources
    /// only), the dice, and the vary range inline — the range does NOT
    /// take a third line (B3.1). A compound shows its One square / Split
    /// up pill and squares note here instead of a stepper.
    private func controlsLine(_ model: MemberRuleRowModel) -> some View {
        HStack(spacing: 8) {
            if model.isCompound {
                splitToggle(model)
                if let note = model.squaresNote {
                    Text(note)
                        .font(.risoBody(10, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                }
                if model.showsSplitLineDice {
                    RisoDiceButton(level: model.memberVary) {
                        onSetVary(model.memberVary.next)
                    }
                }
            } else {
                if model.showsStepper {
                    RisoInlineStepperView(
                        value: Binding(get: { model.target }, set: { onSetTarget($0) }),
                        min: 1,
                        max: model.goal,
                        style: .compact,
                        suffix: model.targetSuffix
                    )
                }
                if model.showsDice {
                    RisoDiceButton(level: model.memberVary) {
                        onSetVary(model.memberVary.next)
                    }
                }
                if let range = model.rangeLabel {
                    rangeLine(range).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Compound: One square / Split up

    /// The One square / Split up pill on the expanded controls line — the
    /// segmented control alone, with its indent and its neighbours (the
    /// squares note, the One-square dice) supplied by ``controlsLine(_:)``.
    ///
    /// - Parameter model: The resolved row model, for the current mode.
    /// - Returns: The toggle, wired to `onSetSplit`.
    private func splitToggle(_ model: MemberRuleRowModel) -> some View {
        RisoSegmented(
            options: [(value: false, label: "One square"), (value: true, label: "Split up")],
            selection: Binding(get: { model.isSplit }, set: { onSetSplit($0) }),
            style: .pill,
            size: .compact
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Squares for \(title)")
    }

    // MARK: - Compound: one line per part

    @ViewBuilder
    private func partLine(_ part: MemberRuleRowModel.Part) -> some View {
        if part.excluded {
            HStack(spacing: 8) {
                Text(part.name)
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoInk)
                    .strikethrough()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { onSetPartExcluded(part.childId, false) } label: {
                    Text("UNDO")
                        .font(.risoBody(10.5, .extraBold))
                        .tracking(0.6)
                        .foregroundStyle(Color.risoInk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.risoPaper2))
                        .overlay(
                            Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Undo excluding \(part.name)")
            }
            .opacity(0.45)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(part.name)
                        .font(.risoBody(12, .semibold))
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if part.showsStepper {
                        RisoInlineStepperView(
                            value: Binding(
                                get: { part.target },
                                set: { onSetPartTarget(part.childId, $0) }
                            ),
                            min: 1,
                            max: Swift.max(1, part.goal),
                            style: .compact
                        )
                    }
                    if let caption = part.caption {
                        Text(caption)
                            .font(.risoBody(10, .semibold))
                            .foregroundStyle(Color.risoMuted)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if part.showsDice {
                        RisoDiceButton(level: part.level) {
                            onSetPartVary(part.childId, part.level.next)
                        }
                    }
                    if part.showsExclude {
                        Button { onSetPartExcluded(part.childId, true) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.risoMuted)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "Exclude \(part.name) for this board"
                        )
                    }
                }
                if let range = part.rangeLabel {
                    rangeLine(range).padding(.top, 2)
                }
            }
        }
    }
}
