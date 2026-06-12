import SwiftUI

// MARK: - RisoCountingStepperSheet

/// Small sheet (`.presentationDetents([.height(140)])`) that surfaces
/// the counting stepper for a cell tap on a counting-type square.
///
/// Wires directly to the caller's `handleCountingTap` / `handleCountingDecrement`
/// via the `onIncrement` / `onDecrement` closures. The sheet itself carries no
/// write logic.
///
/// Per spec: the − button is disabled for linked derived counters
/// (`isLinkedCounter = true`) and when `currentCount == 0`.
struct RisoCountingStepperSheet: View {

    // MARK: - Data

    let taskTitle: String
    let currentCount: Int
    let maxCount: Int
    let unitText: String
    let isLinkedCounter: Bool

    // MARK: - Actions

    var onIncrement: () -> Void = {}
    var onDecrement: () -> Void = {}
    var onDismiss: () -> Void = {}

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.risoPaper.ignoresSafeArea()

            VStack(spacing: 16) {
                // ── Label pill ──
                labelPill

                // ── Stepper row ──
                stepperRow
            }
            .padding(.top, 20)
            .padding(.horizontal, Riso.gutter)
        }
        .presentationDetents([.height(140)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.risoPaper)
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

    private var stepperRow: some View {
        HStack(spacing: 0) {
            // − button
            Button {
                onDecrement()
            } label: {
                Text("−")
                    .font(.risoHead(22, .extraBold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 54, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(StepperButtonStyle())
            .disabled(currentCount == 0 || isLinkedCounter)

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
                onIncrement()
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
