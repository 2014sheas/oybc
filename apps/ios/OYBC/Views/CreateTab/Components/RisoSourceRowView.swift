import SwiftUI

/// One pulled source's row in the wizard's "On your board" list (Board
/// Sources P2 — docs/BOARD_SOURCES.md §Surfaces item 1; handoff frames
/// 2a/4a). Collapsed: letter square (pool = ink "P", board = gold +
/// ink-static "B" per the dark contract), name, live subtitle, chevron,
/// ✕. Tapping the header toggles the expanded panel: (boards only) the
/// All squares / Not done yet segmented, the range block (kicker, range
/// label, "Use all", the two-handle `RisoRangeSlider`, the non-default
/// note line), then the member rows — each a `RisoMemberRuleRowView`,
/// which owns the ✕ exclude / UNDO pill / filtered-done green ✓ AND
/// the §Member rules controls (target stepper, dice, One square /
/// Split up + part lines).
///
/// Fully props/callback-driven — no VM import; `BoardWizardTasksStepView`
/// wires it to `BoardWizardViewModel`'s sources actions.
struct RisoSourceRowView: View {
    let source: BoardSource
    let supply: WizardSourceSupply
    /// Post-exclude, post-filter count — the slider's N and "of N".
    let availableCount: Int
    let isExpanded: Bool
    /// Member titles + type badges (the step's `effectiveTaskById` so
    /// staged inline edits show through).
    let taskById: [String: Task]
    let onToggleExpanded: () -> Void
    let onRemove: () -> Void
    let onSetFilter: (BoardSource.Filter) -> Void
    let onSetRange: (_ min: Int, _ max: Int?) -> Void
    let onToggleExclude: (String) -> Void
    /// Counter-family exclusivity (2026-09-08) — member id → the OTHER
    /// family member's title, when both are visible in the pool ("one
    /// per board" hint).
    var counterClashByTaskId: [String: String] = [:]

    // §Member rules (B3, docs/BOARD_SOURCES.md) — the per-member rule
    // controls each included member row carries.
    //
    // Defaulted so the snapshot-test mounts (`RisoSourceSnapshotTests`,
    // which exercise the row CHROME, not the rules) don't have to name
    // eight arguments. The wizard step is the only production caller and
    // it passes all of them. A future read-only mount MUST pass the real
    // `wizardWindow` / `mode`: the defaults below are a daily one-off
    // board, so a mount that leaves them alone renders targets pro-rated
    // against the wrong window rather than rendering nothing.

    /// Children per compound (the step's effective map) — feeds the
    /// Split-up part lines.
    var compoundChildrenByCompound: [String: [CompoundChild]] = [:]
    /// Whether the board being assembled is one-off or repeating.
    var mode: BoardSources.PlanMode = .oneOff
    /// The window of the board being assembled (the pro-rating target).
    var wizardWindow: BoardSources.BoardWindow = .init(timeframe: .daily)
    var onSetMemberTarget: (_ taskId: String, _ target: Int?) -> Void = { _, _ in }
    var onSetMemberVary: (_ taskId: String, _ level: VaryLevel) -> Void = { _, _ in }
    var onSetMemberSplit: (_ taskId: String, _ split: Bool) -> Void = { _, _ in }
    var onSetPartExcluded: (_ taskId: String, _ childId: String, _ excluded: Bool) -> Void = { _, _, _ in }
    var onSetPartTarget: (_ taskId: String, _ childId: String, _ target: Int?) -> Void = { _, _, _ in }
    var onSetPartVary: (_ taskId: String, _ childId: String, _ level: VaryLevel) -> Void = { _, _, _ in }

    private var isDefaultRange: Bool { source.min == 0 && source.max == nil }
    private var effectiveMax: Int { source.max ?? availableCount }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isExpanded {
                expandedPanel
            }
        }
        .background(Color.risoPaper2)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
    }

    // MARK: - Header

    /// Plain container + SIBLING remove button — never a Button nested in
    /// a Button (unreliable gesture arbitration; `RisoPoolListView`'s row
    /// pattern). The ✕ wins its own taps; the row's tap gesture handles
    /// the rest of the header area for expand/collapse.
    private var headerRow: some View {
        HStack(spacing: 10) {
            letterSquare
            VStack(alignment: .leading, spacing: 1) {
                Text(supply.displayName)
                    .font(.risoBody(14, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.risoBody(10.5, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.risoMuted)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 28, height: 28)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(supply.displayName)")
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(supply.displayName), \(subtitle)")
        .accessibilityHint(isExpanded ? "Collapses the source" : "Expands the source")
        .accessibilityAddTraits(.isButton)
    }

    /// Pool = ink fill + paper "P"; board = gold fill + ink-static "B"
    /// (content on gold always takes ink-static — the Riso dark contract).
    private var letterSquare: some View {
        RoundedRectangle(cornerRadius: Riso.cellRadius)
            .fill(source.kind == .pool ? Color.risoInk : Color.risoGold)
            .frame(width: 20, height: 20)
            .overlay(
                Text(source.kind == .pool ? "P" : "B")
                    .font(.risoBody(11, .extraBold))
                    .foregroundStyle(source.kind == .pool ? Color.risoPaper : Color.risoInkStatic)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
            )
    }

    /// docs/BOARD_SOURCES.md §Surfaces "Subtitles": pool — "8 tasks"
    /// (+ " · 1 excluded", + " · 3–5 on the board" only when range ≠
    /// default); board — "6 squares · 4 done" / "2 not done"; a board
    /// source with no board for the window being built — "No board for this
    /// window yet" (owner ruling 2026-09-24). Web twin: `buildSubtitle`.
    private var subtitle: String {
        if source.kind == .board && supply.noBoardForWindow {
            return BoardSources.noBoardForWindowNote
        }
        switch source.kind {
        case .pool:
            let total = supply.rawSupplyTaskIds.count
            var parts = ["\(total) task\(total == 1 ? "" : "s")"]
            let excludedCount = Set(source.excludedTaskIds)
                .intersection(supply.rawSupplyTaskIds).count
            if excludedCount > 0 { parts.append("\(excludedCount) excluded") }
            if !isDefaultRange { parts.append(rangeText + " on the board") }
            return parts.joined(separator: " · ")
        case .board:
            if source.filter == .todo {
                let notDone = BoardSources.availableSupplyIds(
                    source: source,
                    supplyTaskIds: supply.rawSupplyTaskIds,
                    doneTaskIds: supply.doneTaskIds
                ).count
                var parts = ["\(notDone) not done"]
                if !isDefaultRange { parts.append(rangeText + " on the board") }
                return parts.joined(separator: " · ")
            }
            let total = supply.rawSupplyTaskIds.count
            var parts = ["\(total) square\(total == 1 ? "" : "s") · \(supply.doneTaskIds.count) done"]
            if !isDefaultRange { parts.append(rangeText + " on the board") }
            return parts.joined(separator: " · ")
        }
    }

    private var rangeText: String {
        source.min == effectiveMax ? "\(source.min)" : "\(source.min)–\(effectiveMax)"
    }

    // MARK: - Expanded panel

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            hairline
            VStack(spacing: 0) {
                if source.kind == .board {
                    RisoSegmented(
                        options: [
                            (value: BoardSource.Filter.all, label: "All squares"),
                            (value: BoardSource.Filter.todo, label: "Not done yet"),
                        ],
                        selection: Binding(get: { source.filter }, set: { onSetFilter($0) }),
                        selectedFill: { _ in .risoInk }
                    )
                    .padding(.top, 10)
                    .padding(.horizontal, 16)
                }
                rangeBlock
                memberRows
            }
            .background(Color.risoPaper)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.risoInk.opacity(0.24))
            .frame(height: Riso.Keyline.dense)
    }

    private var rangeBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("ON THE BOARD")
                    .font(.risoBody(10, .extraBold))
                    .kerning(0.9)
                    .foregroundStyle(Color.risoMuted)
                Spacer()
                Text(rangeText)
                    .font(.risoHead(16, .extraBold))
                    .foregroundStyle(Color.risoInk)
                Text("of \(availableCount)")
                    .font(.risoBody(10.5, .semibold))
                    .foregroundStyle(Color.risoMuted)
                Button("Use all") { onSetRange(0, nil) }
                    .font(.risoBody(12, .bold))
                    .foregroundStyle(Color.risoBlue)
                    .buttonStyle(.plain)
                    .opacity(isDefaultRange ? 0.35 : 1)
                    .disabled(isDefaultRange)
            }
            RisoRangeSlider(
                available: availableCount,
                minValue: min(source.min, availableCount),
                maxValue: source.max,
                onChange: onSetRange
            )
            if !isDefaultRange {
                Text(rangeNote)
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoInk)
                    .padding(.bottom, 4)
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { hairline }
    }

    private var rangeNote: String {
        source.min == effectiveMax
            ? "\(source.min) of these will be on the board."
            : "Between \(source.min) and \(effectiveMax) of these will be on the board."
    }

    // MARK: - Member rows

    private func memberState(for taskId: String) -> MemberRuleRowState {
        if source.kind == .board, source.filter == .todo, supply.doneTaskIds.contains(taskId) {
            return .filteredDone
        }
        if source.excludedTaskIds.contains(taskId) { return .excluded }
        return .included
    }

    /// One `RisoMemberRuleRowView` per supplied member — it owns the whole
    /// row (title, ✕/UNDO/✓ AND the §Member rules controls), so this file
    /// stays a header + range-block renderer.
    private var memberRows: some View {
        VStack(spacing: 0) {
            ForEach(supply.rawSupplyTaskIds, id: \.self) { taskId in
                RisoMemberRuleRowView(
                    task: taskById[taskId],
                    taskById: taskById,
                    state: memberState(for: taskId),
                    clashTitle: counterClashByTaskId[taskId],
                    rule: BoardSources.memberRule(for: taskId, in: source),
                    parts: compoundChildrenByCompound[taskId] ?? [],
                    fromBoard: source.kind == .board,
                    sourceWindow: supply.sourceWindow,
                    wizardWindow: wizardWindow,
                    mode: mode,
                    onToggleExclude: { onToggleExclude(taskId) },
                    onSetTarget: { onSetMemberTarget(taskId, $0) },
                    onSetVary: { onSetMemberVary(taskId, $0) },
                    onSetSplit: { onSetMemberSplit(taskId, $0) },
                    onSetPartExcluded: { onSetPartExcluded(taskId, $0, $1) },
                    onSetPartTarget: { onSetPartTarget(taskId, $0, $1) },
                    onSetPartVary: { onSetPartVary(taskId, $0, $1) }
                )
            }
        }
    }
}
