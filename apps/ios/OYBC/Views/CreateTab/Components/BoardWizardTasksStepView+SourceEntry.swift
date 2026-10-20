import SwiftUI

/// The "Add from a pool or board" entry row and its Getting Started hooks,
/// split out of `BoardWizardTasksStepView` (that file sits at the 1000-line
/// ceiling).
extension BoardWizardTasksStepView {

    /// Dashed "Add from a pool or board" entry row — styled like the library
    /// entry row (2pt dashed keyline, grid icon, trailing count badge =
    /// pools + active boards).
    var sourceSheetEntry: some View {
        Button {
            showSourceSheet = true
            tutorialCoach?.handle(.sourcesSheetOpened)
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
        .tutorialAnchor(.addFromPoolRow)
    }

    /// The tutorial's hook for the sources sheet closing: when a pulled pool now
    /// fills the board, report its line ("Fitness fills eight squares") and let
    /// the lesson move on; closed with nothing filling it, the lesson lights the
    /// entry row again. Inert outside a lesson.
    func tutorialSourceSheetClosed() {
        guard let coach = tutorialCoach else { return }
        guard isCountSatisfied else {
            coach.handle(.sourcesSheetClosedEmpty)
            return
        }
        let names = sources.compactMap { supplyInfoBySourceId[$0.sourceId]?.displayName }
        let subject = names.count == 1 ? names[0] : "Your pools"
        coach.reportPool(summary: "\(subject) \(names.count == 1 ? "fills" : "fill") \(Self.spelledCount(tasksRequired)) squares")
        coach.handle(.poolsPicked)
    }

    /// 1-12 spelled out for the coach line; digits beyond that.
    static func spelledCount(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        return words.indices.contains(n) ? words[n] : "\(n)"
    }
}
