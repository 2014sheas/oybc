import SwiftUI

/// BoardWizardShellPlayground — iOS spike harness for build-sequence
/// step 2 of the board-creation UX redesign. Mirrors web's
/// `BoardWizardShellPlayground`.
///
/// Mounts the production `BoardWizardView` with `UserPreferences.defaults`
/// and the playground user. Cancel / complete callbacks just append a
/// line to the activity log so the wizard can be exercised end-to-end
/// without any production routing or DB writes from the stubbed step 3.
struct BoardWizardShellPlayground: View {
    @State private var log: [String] = []
    @State private var wizardKey: Int = 0
    @State private var prefs: UserPreferences = .defaults

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("Reset wizard") {
                    wizardKey += 1
                    appendLog("Wizard reset.")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("Wizard mounts with UserPreferences.defaults + the playground user.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(.systemGray3), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )

            BoardWizardView(
                userId: playgroundUserId,
                preferences: prefs,
                onCancel: {
                    appendLog("Cancel tapped (would close wizard / show smart prompt in step 4).")
                },
                onComplete: { boardId, status in
                    let action = status == "active" ? "Activate" : "Save Draft"
                    appendLog("\(action) tapped → boardId=\(boardId) (stub).")
                }
            )
            .id(wizardKey)

            if !log.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ACTIVITY")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    ForEach(Array(log.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray6))
                )
            }
        }
        .onAppear {
            ensurePlaygroundUser()
        }
    }

    private func appendLog(_ message: String) {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        let entry = "\(f.string(from: Date())) — \(message)"
        log = ([entry] + log).prefix(8).map { $0 }
    }
}
