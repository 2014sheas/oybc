import SwiftUI

// MARK: - RisoCountingStepperSheet

/// Small sheet (`.presentationDetents`, height varies with content) that
/// surfaces the counting stepper for a cell tap on a counting-type square.
///
/// Wires directly to the caller's `handleCountingTap` / `handleCountingDecrement`
/// via the `onIncrement` / `onDecrement` closures. The sheet itself carries no
/// write logic.
///
/// P2: `sharedHint` adds an "↔ Shared · also counts on …" line beneath the
/// stepper when the task belongs to a shared-counter group and the group spans
/// other boards. `isLinkedCounter` no longer disables the `−` button — the
/// new `decrementSharedCounter` engine handles shared decrements.
///
/// R3 (board-play touchpoints): shared counting squares gain an amount-chip
/// row (`+1` / `+{default}` / `#`) matching Counter Detail's chip styling
/// (gold selected, ink-static content — dark-mode-safe), gated by
/// `isSharedCounter` per the copy contract ("Square quick actions — shared
/// counting squares only"). Standalone counters keep the plain +/- stepper
/// with no chips. Both `+`/`-` share ONE selected amount (decrement mirrors
/// the amount that was added); only an explicit custom "#" entry marks
/// `persistAsDefault: true` on the `onIncrement`/`onDecrement` callback.
struct RisoCountingStepperSheet: View {

    // MARK: - Data

    let taskTitle: String
    let currentCount: Int
    let maxCount: Int
    let unitText: String
    /// True when this task has `sharedCounterId != nil` (a linked derived counter).
    /// Kept for BoardPlayView routing but no longer disables the `−` button (P2).
    let isLinkedCounter: Bool
    /// Optional "also counts on …" hint shown beneath the stepper for shared-counter
    /// squares. Nil when the task is not in a shared group or has no other boards.
    /// Format (verbatim per spec): "↔ Shared · also counts on {board}" or
    /// "↔ Shared · also counts on {board} + {N} more"
    var sharedHint: String? = nil
    /// R3: true when this square participates in a shared-counter group
    /// (source, linked, or a P5 promoted zero-link counter) — gates the
    /// amount-chip row. Standalone counting squares get no chips (the copy
    /// contract scopes amount options to shared counting squares only).
    var isSharedCounter: Bool = false
    /// The shared counter's persisted default log amount (SOURCE task's
    /// `Task.defaultLogAmount`) — seeds the "+{default}" chip label and the
    /// initial selected amount (a plain tap of `+`/`-` therefore logs the
    /// default, matching the copy contract). `nil` → default chip shows "1"
    /// too (harmless — mirrors Counter Detail's `defaultLogAmount ?? 1`).
    var defaultLogAmount: Int? = nil

    // MARK: - Actions

    /// `(amount, persistAsDefault)`. `persistAsDefault` is `true` only when
    /// the amount just used came from an explicit custom "#" entry (Global
    /// Constraints: one-tap chips never overwrite the counter's default).
    /// For standalone (non-shared) squares, always `(1, false)`.
    var onIncrement: (Int, Bool) -> Void = { _, _ in }
    var onDecrement: (Int, Bool) -> Void = { _, _ in }

    // MARK: - Chip state (shared counters only)

    @State private var selectedAmount: Int
    @State private var isCustomActive = false
    @State private var customOpen = false
    @State private var customDraft = ""

    init(
        taskTitle: String,
        currentCount: Int,
        maxCount: Int,
        unitText: String,
        isLinkedCounter: Bool,
        sharedHint: String? = nil,
        isSharedCounter: Bool = false,
        defaultLogAmount: Int? = nil,
        onIncrement: @escaping (Int, Bool) -> Void = { _, _ in },
        onDecrement: @escaping (Int, Bool) -> Void = { _, _ in }
    ) {
        self.taskTitle = taskTitle
        self.currentCount = currentCount
        self.maxCount = maxCount
        self.unitText = unitText
        self.isLinkedCounter = isLinkedCounter
        self.sharedHint = sharedHint
        self.isSharedCounter = isSharedCounter
        self.defaultLogAmount = defaultLogAmount
        self.onIncrement = onIncrement
        self.onDecrement = onDecrement
        _selectedAmount = State(initialValue: defaultLogAmount ?? 1)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.risoPaper.ignoresSafeArea()

            VStack(spacing: 12) {
                // ── Label pill ──
                labelPill

                // ── Stepper row ──
                stepperRow

                // ── Amount chips (R3 — shared counting squares only) ──
                if isSharedCounter {
                    chipRow
                    if customOpen {
                        customInputRow
                    }
                }

                // ── Shared hint (P2) ──
                if let hint = sharedHint {
                    Text(hint)
                        .font(.risoBody(11, .regular))
                        .foregroundStyle(Color.risoBlue)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, Riso.gutter)
                }
            }
            .padding(.top, 18)
            .padding(.horizontal, Riso.gutter)
        }
        // Taller with the chip row / custom input / hint present.
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.risoPaper)
    }

    private var sheetHeight: CGFloat {
        var height: CGFloat = 140
        if isSharedCounter { height += 56 }
        if isSharedCounter && customOpen { height += 44 }
        if sharedHint != nil { height += 40 }
        return height
    }

    // MARK: - Label pill

    private var labelPill: some View {
        Text("\(taskTitle) · \(currentCount)/\(maxCount)\(unitText.isEmpty ? "" : " \(unitText)")")
            .font(.risoHead(13, .bold))
            .foregroundStyle(Color.risoPaper)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.risoInk))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: - Stepper

    /// The amount both `+`/`-` act on: the selected chip for shared
    /// counters, always 1 for standalone counters (no chip UI to select from).
    private var effectiveAmount: Int {
        isSharedCounter ? selectedAmount : 1
    }

    /// Whether the amount currently in effect came from an explicit custom
    /// "#" entry — only this marks `persistAsDefault: true` upstream.
    private var effectivePersist: Bool {
        isSharedCounter && isCustomActive
    }

    private var stepperRow: some View {
        HStack(spacing: 0) {
            // − button: disabled only when count is 0 (P2: no longer disabled for isLinkedCounter)
            Button {
                onDecrement(effectiveAmount, effectivePersist)
            } label: {
                Text("−")
                    .font(.risoHead(22, .extraBold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 54, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(StepperButtonStyle())
            .disabled(currentCount == 0)

            // Value display
            Text("\(currentCount)/\(maxCount)")
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
                onIncrement(effectiveAmount, effectivePersist)
            } label: {
                Text("+")
                    .font(.risoHead(22, .extraBold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 54, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(StepperButtonStyle())
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

    // MARK: - Amount chips (R3)

    private struct AmountChipOption {
        /// `nil` marks the trailing custom "#" chip.
        let value: Int?
        let label: String

        /// Keep-first dedupe by `value` (custom `nil` chip always kept) —
        /// mirrors web `amountChips.dedupeChips`. A fresh counter's default
        /// of 1 (or a default of 25 on Detail) would otherwise duplicate a
        /// fixed chip (device-testing feedback, R3).
        static func dedupingValues(_ chips: [AmountChipOption]) -> [AmountChipOption] {
            var seen = Set<Int>()
            return chips.filter { chip in
                guard let value = chip.value else { return true }
                return seen.insert(value).inserted
            }
        }
    }

    /// `+1` / `+{default}` / `#` — three options per the copy contract
    /// (deliberately NOT R2 Detail's 4-chip "1 / default / 25 / #" set; the
    /// design handoff mock for board-play squares shows exactly three).
    private var chips: [AmountChipOption] {
        let amount = defaultLogAmount ?? 1
        // Keep-first dedupe: a fresh counter's default of 1 would otherwise
        // render two "+1" chips (device-testing feedback, R3). Mirrors web's
        // dedupeChips; selection resolves by first index, so it's neutral.
        return AmountChipOption.dedupingValues([
            AmountChipOption(value: 1, label: "+1"),
            AmountChipOption(value: amount, label: "+\(amount)"),
            AmountChipOption(value: nil, label: "#"),
        ])
    }

    private var selectedChipIndex: Int? {
        if isCustomActive { return chips.count - 1 }
        return chips.firstIndex(where: { $0.value == selectedAmount })
    }

    private func selectChip(_ value: Int) {
        selectedAmount = value
        isCustomActive = false
        customOpen = false
    }

    private func openCustomInput() {
        customDraft = isCustomActive ? "\(selectedAmount)" : ""
        customOpen = true
    }

    private func confirmCustomInput() {
        guard let parsed = CounterLogAmount.parseCustom(customDraft) else { return }
        selectedAmount = parsed
        isCustomActive = true
        customOpen = false
    }

    /// Amount chip row: `+1` / `+{default}` / `#` — selected = gold fill +
    /// `risoInkStatic` (dark-mode-safe content on gold, per the copy
    /// contract); idle = ink-bordered/ink-text on this sheet's cream
    /// (`risoPaper`) background.
    private var chipRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                let isSelected = index == selectedChipIndex
                Button {
                    if let value = chip.value {
                        selectChip(value)
                    } else {
                        openCustomInput()
                    }
                } label: {
                    Text(chip.value == nil && isSelected ? "#\(selectedAmount)" : chip.label)
                        .font(.risoHead(13, .extraBold))
                        .foregroundStyle(isSelected ? Color.risoInkStatic : Color.risoInk)
                        .frame(minWidth: 40)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(isSelected ? Color.risoGold : Color.clear))
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

#Preview("Counting stepper sheet — shared hint") {
    Color.risoPaper
        .sheet(isPresented: .constant(true)) {
            RisoCountingStepperSheet(
                taskTitle: "Push-ups",
                currentCount: 20,
                maxCount: 30,
                unitText: "reps",
                isLinkedCounter: false,
                sharedHint: "↔ Shared · also counts on February Fitness"
            )
        }
}

#Preview("Counting stepper sheet — shared hint multi-board") {
    Color.risoPaper
        .sheet(isPresented: .constant(true)) {
            RisoCountingStepperSheet(
                taskTitle: "Push-ups",
                currentCount: 20,
                maxCount: 30,
                unitText: "reps",
                isLinkedCounter: true,
                sharedHint: "↔ Shared · also counts on February Fitness + 2 more"
            )
        }
}

#Preview("Counting stepper sheet — R3 amount chips") {
    Color.risoPaper
        .sheet(isPresented: .constant(true)) {
            RisoCountingStepperSheet(
                taskTitle: "Do 200 push-ups",
                currentCount: 132,
                maxCount: 200,
                unitText: "Push-ups",
                isLinkedCounter: false,
                sharedHint: "↔ Shared · also counts on Daily Grind",
                isSharedCounter: true,
                defaultLogAmount: 10
            )
        }
}
