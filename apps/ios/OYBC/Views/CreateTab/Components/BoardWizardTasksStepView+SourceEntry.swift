import SwiftUI

/// The "Add from a pool or board" entry row, split out of
/// `BoardWizardTasksStepView` (that file sits at the 1000-line ceiling).
extension BoardWizardTasksStepView {

    /// Dashed "Add from a pool or board" entry row — styled like the library
    /// entry row (2pt dashed keyline, grid icon, trailing count badge =
    /// pools + active boards).
    var sourceSheetEntry: some View {
        Button {
            showSourceSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
                Text("Add from a pool or board")
                    .font(.risoHead(13, .bold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
                Text("\(pools.count + sheetBoardEntries.count)")
                    .font(.risoBody(11, .extraBold))
                    .foregroundStyle(Color.risoPaper)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.risoInk))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(
                        Color.risoInk.opacity(0.5),
                        style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [5, 4])
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add from a pool or board")
    }
}
