import SwiftUI

// MARK: - RisoCountingStepperSheet

/// Small sheet (`.presentationDetents`, height varies with content) that
/// surfaces the counting stepper for a cell tap on a counting-type square.
///
/// Wires directly to the caller's `handleCountingTap` / `handleCountingDecrement`
/// via the `onIncrement` / `onDecrement` closures. The sheet itself carries no
/// write logic; its chip / amount state is the pure `CountingStepperModel`.
///
/// Counter kinds (docs/COUNTER_KINDS.md §5):
/// - Discrete standalone: the plain −/+ stepper (±1), no chips.
/// - Discrete shared: `+1 · +10 · #` (gold selected, ink-static content) with
///   the custom row + OK.
/// - Continuous / Duration (any square): ¼ · ½ · goal · # chips set the
///   always-open amount field (decimal pad / h:m wheel); − and + apply the
///   field's amount; no OK. An edited field is custom.
///
/// Both `+`/`-` share ONE amount (decrement mirrors the amount added); only an
/// explicit custom amount marks `persistAsDefault: true`.
struct RisoCountingStepperSheet: View {

    // MARK: - Data

    let taskTitle: String
    let currentCount: CountValue
    let maxCount: CountValue
    let unitText: String
    /// The square's family kind (a linked row follows its root).
    let countKind: CountKind
    /// True when this task has `sharedCounterId != nil` (a linked derived counter).
    /// Kept for BoardPlayView routing; does not disable the `−` button (P2).
    let isLinkedCounter: Bool
    /// True when this square participates in a shared-counter group (source,
    /// linked, or a P5 promoted zero-link counter) — gates the Discrete chip row.
    var isSharedCounter: Bool = false
    /// The counter's remembered last-used amount (the SOURCE task's for a
    /// shared square, the square's own task otherwise) — seeds the selection.
    var defaultLogAmount: CountValue? = nil
    /// When non-nil, a full-width "Task details ›" row is appended; the tap
    /// handler opens this square's task detail.
    var onOpenTask: (() -> Void)? = nil

    // MARK: - Actions

    /// `(amount, persistAsDefault)`. `persistAsDefault` is `true` only when
    /// the amount just used is an explicit custom entry (one-tap chips never
    /// overwrite the counter's default).
    var onIncrement: (CountValue, Bool) -> Void = { _, _ in }
    var onDecrement: (CountValue, Bool) -> Void = { _, _ in }

    // MARK: - State

    @State private var model: CountingStepperModel
    /// Discrete shared: the custom-amount row.
    @State private var customOpen = false
    @State private var customDraft = ""

    init(
        taskTitle: String,
        currentCount: CountValue,
        maxCount: CountValue,
        unitText: String,
        countKind: CountKind = .discrete,
        isLinkedCounter: Bool,
        isSharedCounter: Bool = false,
        defaultLogAmount: CountValue? = nil,
        onOpenTask: (() -> Void)? = nil,
        onIncrement: @escaping (CountValue, Bool) -> Void = { _, _ in },
        onDecrement: @escaping (CountValue, Bool) -> Void = { _, _ in }
    ) {
        self.onOpenTask = onOpenTask
        self.taskTitle = taskTitle
        self.currentCount = currentCount
        self.maxCount = maxCount
        self.unitText = unitText
        self.countKind = countKind
        self.isLinkedCounter = isLinkedCounter
        self.isSharedCounter = isSharedCounter
        self.defaultLogAmount = defaultLogAmount
        self.onIncrement = onIncrement
        self.onDecrement = onDecrement
        _model = State(initialValue: CountingStepperModel.initial(
            kind: countKind, goal: maxCount, defaultLogAmount: defaultLogAmount, isShared: isSharedCounter
        ))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.risoPaper.ignoresSafeArea()

            VStack(spacing: 12) {
                labelPill
                stepperRow
                if model.showsChips { chipRow }
                if countKind == .discrete, isSharedCounter, customOpen { customInputRow }
                if countKind != .discrete {
                    GoalEntryView(
                        kind: countKind,
                        text: Binding(get: { model.amountText }, set: { model.setText($0) }),
                        placeholder: "Amount",
                        suffix: unitText.isEmpty ? nil : unitText,
                        startsOpen: countKind == .duration,
                        invalid: model.amount == nil
                    )
                }
                if let onOpenTask { taskDetailsRow(onOpenTask) }
            }
            .padding(.top, 18)
            .padding(.horizontal, Riso.gutter)
        }
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.risoPaper)
    }

    private var sheetHeight: CGFloat {
        140 + (model.showsChips ? 56 : 0) + (countKind == .continuous ? 52 : 0) + (countKind == .duration ? 190 : 0)
            + (countKind == .discrete && isSharedCounter && customOpen ? 44 : 0) + (onOpenTask != nil ? 56 : 0)
    }

    /// "Task details ›" row — same chrome as `RisoTaskRowView`.
    private func taskDetailsRow(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RisoTypeBadge(kind: .counting, style: .letterSquare)
                Text("Task details")
                    .font(.risoBody(13, .semibold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .risoCard(keyline: Riso.Keyline.dense)
            // Plain-style buttons hit-test only opaque content.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Task details")
    }

    // MARK: - Label pill

    /// "{cur}/{max}" at the square's kind — "12.4/26.2", "4h 30m/10h 30m".
    private var progressText: String {
        "\(formatCount(currentCount, kind: countKind))/\(formatCount(maxCount, kind: countKind))"
    }

    private var labelPill: some View {
        Text("\(taskTitle) · \(progressText)\(countUnitSuffix(countKind, unit: unitText))")
            .font(.risoHead(13, .bold))
            .foregroundStyle(Color.risoPaper)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.risoInk))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: - Stepper

    /// Whether the amount in effect is an explicit custom entry — only this
    /// marks `persistAsDefault: true` upstream.
    private var effectivePersist: Bool {
        model.isCustom && (countKind != .discrete || isSharedCounter)
    }

    private var stepperRow: some View {
        HStack(spacing: 0) {
            // − button: disabled at 0 or with no valid amount (P2: not for isLinkedCounter)
            Button {
                if let amount = model.amount { onDecrement(amount, effectivePersist) }
            } label: {
                Text("−")
                    .font(.risoHead(22, .extraBold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 54, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(StepperButtonStyle())
            .disabled(model.amount == nil || currentCount == 0)
            .accessibilityLabel("Remove")

            // Value display
            Text(progressText)
                .font(.risoHead(15, .extraBold))
                .foregroundStyle(Color.risoInk)
                .frame(minWidth: 70)
                .padding(.horizontal, 6)
                .frame(height: 44)
                .overlay(
                    HStack {
                        Rectangle()
                            .fill(Color.risoInk)
                            .frame(width: Riso.Keyline.container)
                        Spacer()
                        Rectangle()
                            .fill(Color.risoInk)
                            .frame(width: Riso.Keyline.container)
                    }
                )

            // + button
            Button {
                if let amount = model.amount { onIncrement(amount, effectivePersist) }
            } label: {
                Text("+")
                    .font(.risoHead(22, .extraBold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 54, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(StepperButtonStyle())
            .disabled(model.amount == nil)
            .accessibilityLabel(model.addLabel(unit: unitText))
        }
        .background(Color.risoPaper2)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
        .background(
            Capsule()
                .fill(Color.risoInk)
                .offset(x: Riso.Shadow.button, y: Riso.Shadow.button)
        )
        .fixedSize()
    }

    // MARK: - Amount chips

    private var selectedChipIndex: Int? {
        if model.isCustom { return model.chips.count - 1 }
        return model.chips.firstIndex(where: { $0.value == model.selectedAmount })
    }

    private func openCustomInput() {
        customDraft = model.isCustom ? formatCountForInput(model.selectedAmount, kind: .discrete) : ""
        customOpen = true
    }

    private func confirmCustomInput() {
        guard let parsed = CounterLogAmount.parseCustom(customDraft, kind: .discrete) else { return }
        model.selectedAmount = parsed
        model.isCustom = true
        customOpen = false
    }

    private func chipLabel(_ chip: LogChip, isSelected: Bool) -> String {
        guard chip.value == nil, isSelected, let amount = model.amount else { return chip.label }
        return CounterLogAmount.customChipLabel(amount, kind: countKind)
    }

    /// Chip row — selected = gold fill + `risoInkStatic` (dark-mode-safe
    /// content on gold); idle = ink-bordered/ink-text on the sheet's cream.
    private var chipRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.chips.enumerated()), id: \.offset) { index, chip in
                let isSelected = index == selectedChipIndex
                Button {
                    if let value = chip.value {
                        model.selectChip(value)
                        customOpen = false
                    } else if countKind == .discrete {
                        openCustomInput()
                    } else {
                        model.isCustom = true
                    }
                } label: {
                    Text(chipLabel(chip, isSelected: isSelected))
                        .font(.risoHead(13, .extraBold))
                        .foregroundStyle(isSelected ? Color.risoInkStatic : Color.risoInk)
                        .lineLimit(1)
                        .frame(minWidth: 40)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(isSelected ? Color.risoGold : Color.clear))
                        .contentShape(Capsule()) // whole pill is the tap target, not just the label glyphs (unselected fill is Color.clear)
                        .overlay(
                            Capsule().strokeBorder(
                                isSelected ? Color.risoInk : Color.risoInk.opacity(0.35),
                                lineWidth: Riso.Keyline.dense
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    private var customInputRow: some View {
        HStack(spacing: 8) {
            RisoNumberField(placeholder: "Amount", text: $customDraft)
            Button("OK", action: confirmCustomInput)
                .font(.risoHead(13, .extraBold))
                .foregroundStyle(Color.risoInkStatic)
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(Capsule().fill(Color.risoGold))
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                .disabled(CounterLogAmount.parseCustom(customDraft) == nil)
                .opacity(CounterLogAmount.parseCustom(customDraft) == nil ? 0.5 : 1)
        }
    }
}

// MARK: - Stepper button style (gold flash on press)

private struct StepperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.risoGold : Color.clear)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Preview

#Preview("Counting stepper sheet") {
    Color.risoPaper
        .sheet(isPresented: .constant(true)) {
            RisoCountingStepperSheet(
                taskTitle: "10k steps",
                currentCount: 6,
                maxCount: 10,
                unitText: "k",
                isLinkedCounter: false
            )
        }
}

#Preview("Counting stepper sheet — shared amount chips") {
    Color.risoPaper
        .sheet(isPresented: .constant(true)) {
            RisoCountingStepperSheet(
                taskTitle: "Do 200 push-ups",
                currentCount: 132,
                maxCount: 200,
                unitText: "Push-ups",
                isLinkedCounter: false,
                isSharedCounter: true,
                defaultLogAmount: 10
            )
        }
}

#Preview("Counting stepper sheet — Continuous") {
    Color.risoPaper
        .sheet(isPresented: .constant(true)) {
            RisoCountingStepperSheet(
                taskTitle: "Run 26.2 mi",
                currentCount: 12.4,
                maxCount: 26.2,
                unitText: "mi",
                countKind: .continuous,
                isLinkedCounter: false,
                defaultLogAmount: 3.1,
                onOpenTask: {}
            )
        }
}

#Preview("Counting stepper sheet — Duration") {
    Color.risoPaper
        .sheet(isPresented: .constant(true)) {
            RisoCountingStepperSheet(
                taskTitle: "Practice 10h 30m",
                currentCount: 270,
                maxCount: 630,
                unitText: "",
                countKind: .duration,
                isLinkedCounter: false,
                onOpenTask: {}
            )
        }
}
