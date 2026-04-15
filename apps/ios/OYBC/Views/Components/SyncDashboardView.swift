import SwiftUI

/// SyncDashboardView — playground sync control panel.
///
/// Displays the sync status for the currently authenticated user:
/// - Pending / Completed / Failed queue counts.
/// - A "Sync Now" button that triggers a full push+pull cycle.
/// - A scrollable event log showing the last sync activity.
///
/// Requires `AuthService` to be present in the SwiftUI environment
/// (injected automatically by `AuthGateView`).
struct SyncDashboardView: View {

    // MARK: - Dependencies

    @EnvironmentObject private var authService: AuthService

    /// The production SyncService instance owned by AuthService and
    /// injected as an @EnvironmentObject by AuthGateView. Using the
    /// shared instance means the dashboard observes the same
    /// `isSyncing` / `lastSyncResult` / `syncEvents` state as the
    /// live orchestrator — no second instance fighting for queue
    /// ownership.
    @EnvironmentObject private var syncService: SyncService

    // MARK: - State

    @State private var pendingCount: Int = 0
    @State private var completedCount: Int = 0
    @State private var failedCount: Int = 0
    @State private var countsError: String? = nil

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow
            queueCountsRow
            sessionActivityRow
            if let lastError = syncService.lastError {
                lastErrorRow(lastError)
            }
            syncNowButton
            if let result = syncService.lastSyncResult {
                lastResultSummary(result)
            }
            if !syncService.syncEvents.isEmpty {
                eventLog
            }
        }
        .padding(.vertical, 8)
        .onAppear { refreshCounts() }
        .onChange(of: syncService.isSyncing) { isSyncing in
            if !isSyncing, syncService.lastSyncResult != nil {
                refreshCounts()
            }
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(spacing: 6) {
            if syncService.isSyncing {
                ProgressView()
                    .scaleEffect(0.8)
            }
            Text(syncService.isSyncing ? "Syncing…" : "Sync Dashboard")
                .font(.headline)
                .foregroundStyle(syncService.isSyncing ? .secondary : .primary)
        }
    }

    private var queueCountsRow: some View {
        HStack(spacing: 16) {
            countBadge(label: "Pending", count: pendingCount, color: .orange)
            countBadge(label: "Done", count: completedCount, color: .green)
            countBadge(label: "Failed", count: failedCount, color: .red)
        }
    }

    /// Session-scoped cumulative counters from the new observability
    /// state (added in PR #20). Complements `queueCountsRow` — those
    /// are "what's in the pipeline right now", these are "what's
    /// happened since the sync loop started."
    private var sessionActivityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Session activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formattedLastEventAt)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                countBadge(label: "Pushed", count: syncService.totalPushed, color: .blue)
                countBadge(label: "Pulled", count: syncService.totalPulled, color: .teal)
                countBadge(label: "Conflicts", count: syncService.totalConflicts, color: .orange)
                countBadge(label: "Failed", count: syncService.totalFailed, color: .red)
            }
        }
    }

    private var formattedLastEventAt: String {
        guard let date = syncService.lastEventAt else { return "No activity yet" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return "Last: \(formatter.string(from: date))"
    }

    private func lastErrorRow(_ error: SyncService.SyncErrorRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Last error")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
            Text(error.message)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(3)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func countBadge(label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(count > 0 ? color : .secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 52)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var syncNowButton: some View {
        Button {
            guard let userId = authService.currentUser?.id else { return }
            _Concurrency.Task {
                _ = await syncService.fullSync(userId: userId)
                refreshCounts()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Sync Now")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(syncService.isSyncing || authService.currentUser == nil)
    }

    private func lastResultSummary(_ result: SyncResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last sync")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label("Pushed: \(result.push.pushed)", systemImage: "arrow.up.circle")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Label("Pulled: \(result.pull.pulled)", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.teal)
                if result.push.failed > 0 {
                    Label("Failed: \(result.push.failed)", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(8)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Event Log")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    syncService.syncEvents.removeAll()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                // Show at most 8 recent events to keep the panel compact.
                ForEach(syncService.syncEvents.prefix(8)) { event in
                    HStack(alignment: .top, spacing: 6) {
                        Text(eventTimestamp(event.timestamp))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .leading)
                        Text(event.message)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Helpers

    /// Formats a `Date` as `HH:mm:ss` for the event log timestamps.
    ///
    /// - Parameter date: The date to format.
    /// - Returns: A short time string.
    private func eventTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// Reloads the pending / completed / failed counts from the local sync queue.
    private func refreshCounts() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let allItems: [SyncQueueItem] = try AppDatabase.shared.read { db in
                    try SyncQueueItem.fetchAll(db)
                }
                let pending = allItems.filter { $0.status == .pending || $0.status == .inProgress }.count
                let completed = allItems.filter { $0.status == .completed }.count
                let failed = allItems.filter { $0.status == .failed }.count
                DispatchQueue.main.async {
                    pendingCount = pending
                    completedCount = completed
                    failedCount = failed
                    countsError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    countsError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let authService = AuthService()
    return SyncDashboardView()
        .environmentObject(authService)
        .environmentObject(authService.syncService)
        .padding()
}
