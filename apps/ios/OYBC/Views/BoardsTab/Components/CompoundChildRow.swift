import SwiftUI

/// One child row of the compound detail sheet (`BoardPlayView.compoundDetailContent`).
///
/// A normal / nested-compound child is a tap-toggle row (check + title); a
/// COUNTING child shows its windowed count with a −/+ stepper instead — its
/// count is driven, never toggled (a linked child's count is its counter's).
/// Web twin: the compound child list in `InteractiveTaskSquare`'s DetailModal.
struct CompoundChildRow: View {

    /// A counting child's count on the host board (`Count.make`).
    struct Count {
        let current: CountValue
        let max: CountValue
        let unit: String
        let kind: CountKind
        /// The amount one stepper tap logs: a linked child steps by its
        /// counter's default log amount, a plain one by 1.
        let step: CountValue

        /// The count model for `task`, or `nil` for a non-counting child.
        ///
        /// - Parameters:
        ///   - task: The child task.
        ///   - current: Its windowed count on the host board (`BoardPlayView.windowedCount`).
        ///   - root: Its counter root when linked (default amount + kind).
        static func make(task: Task, current: CountValue, root: Task?) -> Count? {
            guard task.type == .counting else { return nil }
            return Count(
                current: current,
                max: task.maxCount ?? 0,
                unit: task.unit ?? "",
                kind: resolveCountKind(root?.countKind ?? task.countKind),
                step: root?.defaultLogAmount ?? 1
            )
        }
    }

    let title: String
    let isDone: Bool
    /// Windowed Completion (docs Decision 9) — the child's only live
    /// completions are sealed-window-immune: the toggle is disabled + explained.
    let sealBlocked: Bool
    let disabled: Bool
    /// Counting children only — turns the row into a stepper row.
    var count: Count? = nil
    let onToggle: () -> Void
    /// Stepper taps: `1` logs a step, `-1` removes one.
    var onStep: (Int) -> Void = { _ in }
    let onInfo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                if let count {
                    label.padding(.vertical, 6)
                    stepper(count)
                } else {
                    Button(action: onToggle) {
                        label.padding(.vertical, 6).contentShape(Rectangle()) // whole row (incl. Spacer) is the tap target
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled || sealBlocked)
                }

                // Info button — opens the child task's detail, stacked on top of the sheet.
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.risoMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(title) in library")
            }
            if sealBlocked {
                Text("Closed window")
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .padding(.leading, 24)
            }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? Color.risoGreen : Color.risoMuted)
            Text(title)
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoInk)
            Spacer(minLength: 0)
        }
    }

    private func stepper(_ count: Count) -> some View {
        HStack(spacing: 6) {
            stepButton(
                system: "minus", enabled: count.current > 0 && !disabled,
                label: "Remove \(formatCountWithUnit(count.step, kind: count.kind, unit: count.unit)) from \(title)"
            ) { onStep(-1) }
            Text("\(formatCount(count.current, kind: count.kind)) / \(formatCount(count.max, kind: count.kind))")
                .font(.risoBody(12, .bold))
                .monospacedDigit()
                .foregroundStyle(Color.risoInk)
                .frame(minWidth: 52)
                .accessibilityLabel(
                    "\(formatCount(count.current, kind: count.kind)) of \(formatCountWithUnit(count.max, kind: count.kind, unit: count.unit))"
                )
            stepButton(
                system: "plus", enabled: !disabled,
                label: "Add \(formatCountWithUnit(count.step, kind: count.kind, unit: count.unit)) to \(title)"
            ) { onStep(1) }
        }
        .accessibilityElement(children: .contain)
    }

    /// A compact version of the counting card's `detailStepperButton`.
    private func stepButton(system: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .bold))
                // Enabled glyph sits on gold — non-inverting ink for dark mode.
                .foregroundStyle(enabled ? Color.risoInkStatic : Color.risoMuted)
                .frame(width: 30, height: 30)
                .risoCard(fill: enabled ? .risoGold : .risoPaper)
                // 44pt hit target around the compact 30pt card.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(RisoButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
