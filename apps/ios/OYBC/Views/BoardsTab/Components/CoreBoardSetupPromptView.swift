import SwiftUI

/// Empty-window prompt for the core-board window pager.
///
/// No board row is written until the user taps the button (lazy) —
/// this view only surfaces the CTA. Past windows show "Backfill";
/// current/future windows show "Set up".
///
/// Mirrors the web `CoreBoardSetupPrompt` component.
struct CoreBoardSetupPromptView: View {
    let label: String
    let isPast: Bool
    let onSetUp: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("No board for \(label) yet.")
                .foregroundStyle(.secondary)

            Button(action: onSetUp) {
                Text("\(isPast ? "Backfill" : "Set up") \(label)")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
