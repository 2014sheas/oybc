import SwiftUI

/// CreateHubPlayground — iOS playground harness for the full Create
/// Hub flow. Mirrors web's `CreateHubPlayground`.
///
/// Mounts the production `CreateHubView` with the playground user
/// and `UserPreferences.defaults`. Replaces the earlier
/// wizard-only `BoardWizardShellPlayground`: the hub contains the
/// wizard, so this playground exercises everything the previous one
/// did plus the hub itself (CTA card, drafts list, library count,
/// quick-add).
struct CreateHubPlayground: View {
    @State private var log: [String] = []
    @State private var prefs: UserPreferences = .defaults

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hub + wizard mount with UserPreferences.defaults and the playground user. Save a draft, then return to the hub — the draft appears in the Drafts list.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(.systemGray3), style: StrokeStyle(lineWidth: 1, dash: [4]))
                )

            CreateHubView(
                userId: playgroundUserId,
                preferences: prefs,
                onBoardCompleted: { boardId, status in
                    let action = status == "active" ? "Activated" : "Saved draft"
                    appendLog("\(action): boardId=\(String(boardId.prefix(8)))…")
                }
            )

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
