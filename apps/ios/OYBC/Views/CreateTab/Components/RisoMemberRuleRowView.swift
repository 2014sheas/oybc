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
    /// "of 35 mi" — present exactly when the stepper is.
    let caption: String?
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
        self.showsStepper = isOn && isCounting && fromBoard
        self.caption = (isOn && isCounting && fromBoard)
            ? "of \(goal)\(unit.isEmpty ? "" : " \(unit)")"
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
                name: childTask?.title ?? "",
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
/// Three shapes, all driven by the member's own type:
///
/// - **Counting** — a compact target stepper (board sources only), the
///   "of {goal} {unit}" caption, then the dice. A dice that's on adds a
///   blue range line under the row at the 69pt indent.
/// - **Compound with parts** — a One square / Split up pill plus the
///   "N squares" note (dice on that line only while One square), then one
///   line per part: name · stepper · "of {goal}" · dice and ✕ while split.
///   A part's range line sits under that part's line.
/// - **Anything else** (normal, achievement, childless compound) — just
///   the title and the shared exclude control.
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

    /// The 69pt indent range lines / the split line / part lines sit at:
    /// the row's own 40pt leading padding plus 20pt badge + 8pt gap + 1pt.
    private static let indent: CGFloat = 29

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

    private var title: String { task?.title ?? "" }

    var body: some View {
        let model = self.model
        VStack(alignment: .leading, spacing: 0) {
            mainLine(model)
            if let range = model.rangeLabel {
                rangeLine(range)
                    .padding(.top, 2)
                    .padding(.leading, Self.indent)
            }
            if model.isCompound, model.isOn {
                splitLine(model).padding(.top, 5)
                ForEach(model.parts, id: \.childId) { part in
                    partLine(part).padding(.top, 4)
                }
            }
        }
        .opacity(state == .included ? 1 : 0.45)
        .padding(.vertical, 7)
        .padding(.leading, 40)
        .padding(.trailing, 11)
        .overlay(alignment: .top) { hairline }
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
                }
            }
            Spacer(minLength: 6)
            if model.showsStepper {
                RisoInlineStepperView(
                    value: Binding(get: { model.target }, set: { onSetTarget($0) }),
                    min: 1,
                    max: model.goal,
                    style: .compact
                )
            }
            if let caption = model.caption {
                Text(caption)
                    .font(.risoBody(10, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
            if model.showsDice {
                RisoDiceButton(level: model.memberVary) {
                    onSetVary(nextVaryLevel(model.memberVary))
                }
            }
            trailingControl
        }
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
            .accessibilityLabel("Exclude \(title.isEmpty ? "task" : title) for this board")
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
            .accessibilityLabel("Undo excluding \(title.isEmpty ? "task" : title)")
        case .filteredDone:
            Circle()
                .strokeBorder(Color.risoGreen, lineWidth: Riso.Keyline.container)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.risoGreen)
                )
        }
    }

    // MARK: - Range line

    private func rangeLine(_ text: String) -> some View {
        Text(text)
            .font(.risoBody(10.5, .semibold))
            .foregroundStyle(Color.risoBlue)
    }

    // MARK: - Compound: One square / Split up

    private func splitLine(_ model: MemberRuleRowModel) -> some View {
        HStack(spacing: 8) {
            RisoSegmented(
                options: [(value: false, label: "One square"), (value: true, label: "Split up")],
                selection: Binding(get: { model.isSplit }, set: { onSetSplit($0) }),
                style: .pill,
                size: .compact
            )
            .accessibilityLabel("Squares for \(title.isEmpty ? "task" : title)")
            if let note = model.squaresNote {
                Text(note)
                    .font(.risoBody(10, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
            }
            if model.showsSplitLineDice {
                RisoDiceButton(level: model.memberVary) {
                    onSetVary(nextVaryLevel(model.memberVary))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.indent)
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
                .accessibilityLabel("Undo excluding \(part.name.isEmpty ? "sub-task" : part.name)")
            }
            .opacity(0.45)
            .padding(.leading, Self.indent)
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
                            onSetPartVary(part.childId, nextVaryLevel(part.level))
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
                            "Exclude \(part.name.isEmpty ? "sub-task" : part.name) for this board"
                        )
                    }
                }
                if let range = part.rangeLabel {
                    rangeLine(range).padding(.top, 2)
                }
            }
            .padding(.leading, Self.indent)
        }
    }
}
