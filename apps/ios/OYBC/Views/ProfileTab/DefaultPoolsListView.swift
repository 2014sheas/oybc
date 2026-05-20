import SwiftUI

/// DefaultPoolsListView — Profile sub-page that lists the four
/// recurring timeframes with a summary of each pool. Tapping a row
/// pushes `DefaultPoolEditorView` for that timeframe.
///
/// iOS twin of web `DefaultPoolsListPage`. Pools are loaded on appear
/// via `AppDatabase.shared.fetchDefaultPools` (one-shot — no live
/// query). The list is small (≤4 rows) so the trade-off of a manual
/// reload after editor dismiss is fine.
struct DefaultPoolsListView: View {
    @EnvironmentObject var authService: AuthService

    @State private var pools: [DefaultPool] = []
    @State private var loadError: String?

    private static let timeframes: [(Timeframe, String)] = [
        (.daily, "Daily"),
        (.weekly, "Weekly"),
        (.monthly, "Monthly"),
        (.yearly, "Yearly"),
    ]

    var body: some View {
        List {
            Section {
                Text(
                    "A default pool prefills the recurring-banner wizard with "
                    + "the same tasks every time you create a core board for "
                    + "that timeframe. You can still add or remove tasks before saving."
                )
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            }

            Section {
                ForEach(Self.timeframes, id: \.0) { timeframe, label in
                    let pool = pools.first { $0.timeframe == timeframe }
                    NavigationLink {
                        DefaultPoolEditorView(timeframe: timeframe, onSaved: load)
                    } label: {
                        HStack {
                            Text(label)
                            Spacer()
                            Text(summaryText(pool: pool))
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if let loadError {
                Section {
                    Text(loadError)
                        .foregroundColor(.red)
                        .font(.system(size: 13))
                }
            }
        }
        .navigationTitle("Default pools")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func summaryText(pool: DefaultPool?) -> String {
        guard let pool else { return "Not set" }
        let n = pool.taskIds.count
        return "\(n) task\(n == 1 ? "" : "s")"
    }

    private func load() {
        guard let userId = authService.currentUser?.id else { return }
        _Concurrency.Task {
            do {
                let result = try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try AppDatabase.shared.fetchDefaultPools(userId: userId)
                }.value
                await MainActor.run {
                    pools = result
                    loadError = nil
                }
            } catch {
                await MainActor.run { loadError = error.localizedDescription }
            }
        }
    }
}
