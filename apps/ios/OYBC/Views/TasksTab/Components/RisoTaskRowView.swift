import SwiftUI

/// Riso-styled Tasks-tab list row.
///
/// Shows the type badge (letterSquare), title, subtitle line, and a
/// right column with "N bds" + green "N active". Mirrors the `TTRow`
/// component in `proto/tabs.jsx`.
///
/// This view is intentionally not a `Button` — the caller wraps it.
struct RisoTaskRowView: View {
    let task: Task
    let placementCount: Int
    let activePlacementCount: Int
    /// False while the placement join is unresolved — the usage column
    /// shows "—" rather than claiming "0 bds" (late-mutation audit).
    /// Defaults true so previews/snapshot fixtures render their seeds.
    var usageCountsLoaded: Bool = true
    let childCount: Int
    /// Owner ruling 2026-09-22 — this task HEADS a shared-counter family
    /// (`sharedCounterRootIds`). The library shows ONE generic row per
    /// family: the pair-derived `CounterName.formatCounterName` label
    /// ("Read pages") in place of the stored title, no target count anywhere
    /// on the row, and a tap that opens the Counters hub rather than Task
    /// detail (the caller routes; this flag changes the copy and the
    /// accessibility label so the two agree). Defaults false so every
    /// existing call site and snapshot fixture is unaffected.
    var isFamilyRoot: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // ── Type badge (letter square) ──────────────────────────────
            RisoTypeBadge(kind: risoKind, style: .letterSquare)

            // ── Title + subtitle ────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle.isEmpty ? "(untitled task)" : displayTitle)
                    .font(.risoBody(15, .semibold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                if let sub = subtitle {
                    Text(sub)
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ── Right usage column ──────────────────────────────────────
            VStack(alignment: .trailing, spacing: 2) {
                if usageCountsLoaded {
                    HStack(spacing: 2) {
                        Text("\(placementCount)")
                            .font(.risoBody(13, .bold))
                            .foregroundStyle(Color.risoInk)
                        Text(placementCount == 1 ? " bd" : " bds")
                            .font(.risoBody(13, .regular))
                            .foregroundStyle(Color.risoMuted)
                    }
                    Text("\(activePlacementCount) active")
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoGreen)
                } else {
                    // Unknown ≠ zero: never claim "0 bds" before the
                    // placement join resolves (late-mutation audit).
                    Text("—")
                        .font(.risoBody(13, .bold))
                        .foregroundStyle(Color.risoMuted)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: Riso.Keyline.dense)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Derived

    /// A family root reads as the counter itself ("Read pages"), never as one
    /// window's target ("Read 5 pages"). `formatCounterName` returns `""` when
    /// the (action, unit) pair can't produce a name — the same stored-title
    /// fallback `SharedCounterGroups.swift` uses.
    private var displayTitle: String {
        guard isFamilyRoot else { return task.title }
        let generic = CounterName.formatCounterName(action: task.action, unit: task.unit)
        return generic.isEmpty ? task.title : generic
    }

    private var accessibilityText: String {
        let name = displayTitle.isEmpty ? "untitled task" : displayTitle
        return isFamilyRoot ? "Open the \(name) counter" : "Open \(name) details"
    }

    private var risoKind: RisoTaskKind {
        switch task.type {
        case .normal: return .normal
        case .counting: return .counting
        case .compound: return .compound
        case .achievement: return .achievement
        }
    }

    /// One-line subtitle specific to each task type.
    private var subtitle: String? {
        switch task.type {
        case .counting:
            // A family root must not restate a goal anywhere on the row — the
            // whole point of the generic row is that the family's targets live
            // in the Counters hub, one per window. Keep the word in lockstep
            // with the web twin (`TaskRow.tsx` `computeSubtitle`).
            if isFamilyRoot { return "Counter" }
            guard let action = task.action, let unit = task.unit, let max = task.maxCount else { return nil }
            return "\(action) · goal \(max) \(unit)"
        case .compound:
            let n = childCount
            if n == 0 { return "No subtasks yet" }
            let ruleLabel: String
            if let op = task.operatorType {
                switch op {
                case .or: ruleLabel = "any of \(n)"
                case .and: ruleLabel = "all of \(n)"
                case .mOfN:
                    let threshold = task.threshold ?? n
                    ruleLabel = "≥\(threshold) of \(n)"
                }
            } else {
                ruleLabel = "all of \(n)"
            }
            return "\(n) sub-task\(n == 1 ? "" : "s") · \(ruleLabel)"
        case .achievement:
            let trigger = task.achievementTrigger ?? .greenlog
            return trigger == .bingo ? "First Bingo" : "GREENLOG"
        case .normal:
            return nil
        }
    }
}
