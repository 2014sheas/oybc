import SwiftUI

/// The blue Log card on Counter Detail (docs/COUNTER_KINDS.md §5): fixed chips
/// per kind (`CounterLogAmount.hubChips`), a decimal / h:m custom row with OK,
/// and −/＋ Add. Owns only its selection state (seeded once from the counter's
/// remembered amount); logging is the caller's `onLog`. Web twin:
/// `CounterDetailLogCard.tsx`.
struct CounterDetailLogCard: View {

    let group: SharedCounterGroup
    let activeMemberCount: Int
    var isLogging: Bool
    var logError: String?
    var onLog: (CountValue, CounterLogDirection) -> Void

    @State private var model: Model
    @State private var customOpen = false
    @State private var customDraft = ""

    init(
        group: SharedCounterGroup,
        activeMemberCount: Int,
        isLogging: Bool = false,
        logError: String? = nil,
        /// Snapshot-testability seams: force the selected amount / the "#"
        /// chip's selected state. Production call sites never pass these.
        initialSelectedAmount: CountValue? = nil,
        initialCustomActive: Bool = false,
        onLog: @escaping (CountValue, CounterLogDirection) -> Void = { _, _ in }
    ) {
        self.group = group
        self.activeMemberCount = activeMemberCount
        self.isLogging = isLogging
        self.logError = logError
        self.onLog = onLog
        _model = State(initialValue: Model(
            kind: group.countKind, unit: group.unit ?? "", defaultLogAmount: group.defaultLogAmount,
            initialAmount: initialSelectedAmount, initialCustom: initialCustomActive
        ))
    }

    private var unitLabel: String { group.unit ?? "" }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Log \(unitLabel)")
                    .font(.risoHead(15, .extraBold))
                    .foregroundStyle(Color.risoPaper)
                Text("counts toward \(activeMemberCount) active task\(activeMemberCount == 1 ? "" : "s")")
                    .font(.risoBody(11, .regular))
                    .foregroundStyle(Color.risoPaper.opacity(0.85))
            }

            chipRow

            if customOpen {
                customInputRow
            }

            logActionsRow

            if let logError {
                Text(logError)
                    .font(.risoBody(11, .regular))
                    .foregroundStyle(Color.risoPaper.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Riso.cardPadding)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoBlue))
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
        .risoHardShadow(Riso.Shadow.card, radius: Riso.cardRadius)
    }

    // MARK: - Chip actions

    private func openCustomInput() {
        customDraft = model.isCustom ? formatCountForInput(model.selectedAmount, kind: model.kind) : ""
        customOpen = true
    }

    // MARK: - Chip row

    /// Selected = gold fill + `risoInkStatic` (dark-mode-safe content on gold);
    /// idle = transparent with an on-color (`risoPaper`) border/text.
    private var chipRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.chips.enumerated()), id: \.offset) { index, chip in
                let isSelected = index == model.selectedChipIndex
                Button {
                    if let value = chip.value {
                        model.select(value)
                        customOpen = false
                    } else {
                        openCustomInput()
                    }
                } label: {
                    Text(model.chipLabel(at: index))
                        .font(.risoHead(13, .extraBold))
                        .foregroundStyle(isSelected ? Color.risoInkStatic : Color.risoPaper)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(minWidth: 40)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(isSelected ? Color.risoGold : Color.clear)).contentShape(Capsule()) // whole pill tappable (unselected fill is clear)
                        .overlay(
                            Capsule().strokeBorder(
                                isSelected ? Color.risoInk : Color.risoPaper.opacity(0.6),
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
        let valid = CounterLogAmount.parseCustom(customDraft, kind: model.kind) != nil
        return HStack(spacing: 8) {
            GoalEntryView(
                kind: model.kind, text: $customDraft, placeholder: "Amount",
                suffix: model.unit.isEmpty || model.kind == .duration ? nil : model.unit
            )
            Button("OK") {
                if model.confirmCustom(customDraft) { customOpen = false }
            }
            .font(.risoHead(13, .extraBold))
            .foregroundStyle(Color.risoInkStatic)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(Capsule().fill(Color.risoGold))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            .disabled(!valid)
            .opacity(valid ? 1 : 0.5)
        }
    }

    private var logActionsRow: some View {
        HStack(spacing: 12) {
            Button {
                onLog(model.selectedAmount, .remove)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.risoPaper)
                    .frame(width: 52, height: 44).contentShape(Rectangle()) // whole 52×44 frame is the tap target
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .strokeBorder(Color.risoPaper.opacity(0.7), lineWidth: Riso.Keyline.dense)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isLogging || group.lifetime == 0)
            .accessibilityLabel(model.removeA11y)

            Button {
                onLog(model.selectedAmount, .add)
            } label: {
                HStack(spacing: 6) {
                    if isLogging {
                        ProgressView()
                            .tint(Color.risoInk)
                            .scaleEffect(0.85)
                    }
                    Text(model.addLabel)
                        .font(.risoHead(15, .extraBold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                // Adaptive fill (`risoPaper`) → adaptive content (`risoInk`).
                // Static ink on the adaptive fill went ink-on-ink in dark mode.
                .foregroundStyle(Color.risoInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                )
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small))
            .disabled(isLogging)
            .accessibilityLabel(model.addA11y)
        }
    }
}

extension CounterDetailLogCard {
    /// Chips + selection for the Log card (docs/COUNTER_KINDS.md §5). Unit-tested.
    struct Model: Equatable {
        let kind: CountKind
        let unit: String
        let chips: [LogChip]
        var selectedAmount: CountValue
        var isCustom: Bool

        init(kind: CountKind, unit: String, defaultLogAmount: CountValue?, initialAmount: CountValue? = nil, initialCustom: Bool = false) {
            self.kind = kind
            self.unit = unit
            chips = CounterLogAmount.hubChips(kind: kind)
            let sel = CounterLogAmount.initialSelection(kind: kind, chips: chips, defaultLogAmount: defaultLogAmount)
            selectedAmount = initialAmount ?? sel.amount
            isCustom = initialCustom || (initialAmount == nil && sel.isCustom)
        }

        var selectedChipIndex: Int? {
            isCustom ? chips.count - 1 : chips.firstIndex { $0.value == selectedAmount }
        }

        /// The selected `#` chip shows the custom amount: "#3.1" for the new
        /// kinds, the bare number for Discrete (today's Detail).
        func chipLabel(at i: Int) -> String {
            guard chips[i].value == nil, i == selectedChipIndex else { return chips[i].label }
            return kind == .discrete
                ? formatCount(selectedAmount, kind: kind)
                : CounterLogAmount.customChipLabel(selectedAmount, kind: kind)
        }

        var addLabel: String {
            kind == .discrete
                ? "＋ Add \(formatCount(selectedAmount, kind: kind))"
                : "＋ Add \(formatCountWithUnit(selectedAmount, kind: kind, unit: unit))"
        }

        var addA11y: String { "Add \(formatCountWithUnit(selectedAmount, kind: kind, unit: unit))" }
        var removeA11y: String { "Remove \(formatCountWithUnit(selectedAmount, kind: kind, unit: unit))" }

        mutating func select(_ v: CountValue) { selectedAmount = v; isCustom = false }

        mutating func confirmCustom(_ draft: String) -> Bool {
            guard let v = CounterLogAmount.parseCustom(draft, kind: kind) else { return false }
            selectedAmount = v
            isCustom = true
            return true
        }
    }
}
