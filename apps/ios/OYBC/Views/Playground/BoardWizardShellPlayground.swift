import SwiftUI
import GRDB

/// BoardWizardShellPlayground — iOS playground harness for the
/// board-creation wizard. Mirrors web's `BoardWizardShellPlayground`.
///
/// Exposes two controls:
/// - **Reset wizard (fresh)** — remounts the wizard with no draft.
/// - **Resume latest draft** — fetches the most recent DRAFT board
///   for the playground user and hydrates the wizard from it so the
///   draft-resume path can be flexed end-to-end.
struct BoardWizardShellPlayground: View {
    @State private var log: [String] = []
    @State private var wizardKey: Int = 0
    @State private var prefs: UserPreferences = .defaults
    @State private var resumeDraft: (board: Board, boardTasks: [BoardTask])? = nil
    @State private var resumeStatus: String? = nil
    @State private var isResuming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("Reset wizard (fresh)") {
                    resumeDraft = nil
                    resumeStatus = nil
                    wizardKey += 1
                    appendLog("Wizard reset.")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    loadLatestDraft()
                } label: {
                    if isResuming {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Resume latest draft")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isResuming)

                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(.systemGray3), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )

            if let s = resumeStatus {
                Text(s)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }

            BoardWizardView(
                userId: playgroundUserId,
                preferences: prefs,
                draft: resumeDraft,
                onCancel: {
                    appendLog("Cancel resolved — wizard dismissed.")
                },
                onComplete: { boardId, status in
                    let action = status == "active" ? "Activated" : "Saved draft"
                    appendLog("\(action): boardId=\(String(boardId.prefix(8)))…")
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

    private func loadLatestDraft() {
        isResuming = true
        resumeStatus = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let draftBoards = try AppDatabase.shared.read { db in
                    try Board
                        .filter(Column("userId") == playgroundUserId
                            && Column("status") == "draft"
                            && Column("isDeleted") == false)
                        .order(Column("createdAt").desc)
                        .fetchAll(db)
                }
                guard let latest = draftBoards.first else {
                    DispatchQueue.main.async {
                        isResuming = false
                        resumeStatus = "No drafts found. Save one from the wizard first."
                    }
                    return
                }
                let boardTasks = try AppDatabase.shared.fetchBoardTasks(boardId: latest.id)
                DispatchQueue.main.async {
                    isResuming = false
                    resumeDraft = (latest, boardTasks)
                    wizardKey += 1
                    resumeStatus = "Resumed draft \"\(latest.name)\" — \(boardTasks.count) task\(boardTasks.count == 1 ? "" : "s") restored."
                    appendLog("Resumed draft boardId=\(String(latest.id.prefix(8)))…")
                }
            } catch {
                DispatchQueue.main.async {
                    isResuming = false
                    resumeStatus = "Failed to resume: \(error.localizedDescription)"
                }
            }
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
