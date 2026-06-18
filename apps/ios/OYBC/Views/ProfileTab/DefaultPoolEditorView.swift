import SwiftUI

/// DefaultPoolEditorView — legacy per-timeframe pool editor, preserved for any
/// existing navigation paths. The Riso redesign replaced this with PoolEditSheet
/// (defined in DefaultPoolsListView.swift) presented as a bottom sheet from the
/// DefaultPoolsListView card tap. This file is kept so existing NavigationLink
/// destinations and any test references continue to compile.
///
/// If all call-sites have migrated to PoolEditSheet, this file can be deleted.
struct DefaultPoolEditorView: View {

    let timeframe: Timeframe
    let onSaved: () -> Void

    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var allTasks: [Task] = []
    @State private var existingPool: DefaultPool?
    @State private var selectedIds: Set<String> = []
    @State private var search: String = ""
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saving: Bool = false
    @State private var showClearConfirm: Bool = false

    private var pickableTasks: [Task] {
        allTasks.filter { $0.type != .achievement }
    }

    private var visibleTasks: [Task] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return pickableTasks }
        return pickableTasks.filter {
            $0.title.lowercased().contains(q) || ($0.description?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search tasks…", text: $search)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                }
            }
            if visibleTasks.isEmpty {
                Section {
                    Text(pickableTasks.isEmpty
                         ? "No tasks in your library yet. Create some from the Tasks tab."
                         : "No tasks match \"\(search)\".")
                        .foregroundColor(.secondary).font(.system(size: 14))
                }
            } else {
                Section {
                    ForEach(visibleTasks, id: \.id) { task in
                        Button { toggle(task.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedIds.contains(task.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedIds.contains(task.id) ? .blue : .secondary)
                                TypeBadgeView(type: task.type.rawValue)
                                Text(task.title.isEmpty ? "(untitled task)" : task.title)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let loadError { Section { Text(loadError).foregroundColor(.red).font(.system(size: 13)) } }
            if let saveError { Section { Text(saveError).foregroundColor(.red).font(.system(size: 13)) } }
        }
        .navigationTitle("\(timeframeLabel) pool")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("\(selectedIds.count) selected")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { performSave() }.disabled(saving)
            }
            if existingPool != nil {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) { showClearConfirm = true } label: {
                        Label("Clear pool", systemImage: "trash")
                    }.disabled(saving)
                }
            }
        }
        .alert("Clear \(timeframeLabel) pool?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { performClear() }
        } message: { Text("Removes this pool entirely. You can set it up again later.") }
        .onAppear(perform: load)
    }

    private var timeframeLabel: String {
        switch timeframe {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .custom: return "Custom"
        }
    }

    private func toggle(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    private func load() {
        guard let userId = authService.currentUser?.id else { return }
        _Concurrency.Task {
            do {
                let snapshot = try await _Concurrency.Task.detached(priority: .userInitiated) {
                    let tasks = try AppDatabase.shared.fetchTasks(userId: userId)
                    let pool = try AppDatabase.shared.fetchDefaultPool(userId: userId, timeframe: timeframe)
                    return (tasks, pool)
                }.value
                await MainActor.run {
                    allTasks = snapshot.0; existingPool = snapshot.1
                    selectedIds = Set(snapshot.1?.taskIds ?? []); loadError = nil
                }
            } catch { await MainActor.run { loadError = error.localizedDescription } }
        }
    }

    private func performSave() {
        guard let userId = authService.currentUser?.id else { return }
        let ids = Array(selectedIds); let tf = timeframe
        saving = true; saveError = nil
        _Concurrency.Task {
            do {
                _ = try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try AppDatabase.shared.upsertDefaultPool(userId: userId, timeframe: tf, taskIds: ids)
                }.value
                await MainActor.run { saving = false; onSaved(); dismiss() }
            } catch {
                await MainActor.run { saving = false; saveError = "Failed to save: \(error.localizedDescription)" }
            }
        }
    }

    private func performClear() {
        guard let pool = existingPool else { return }
        let poolId = pool.id; saving = true; saveError = nil
        _Concurrency.Task {
            do {
                try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try AppDatabase.shared.softDeleteDefaultPool(id: poolId)
                }.value
                await MainActor.run { saving = false; onSaved(); dismiss() }
            } catch {
                await MainActor.run { saving = false; saveError = "Failed to clear: \(error.localizedDescription)" }
            }
        }
    }
}
