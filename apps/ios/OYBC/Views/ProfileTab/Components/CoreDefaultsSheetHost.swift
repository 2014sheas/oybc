import SwiftUI

/// Data-loading host for `CoreDefaultsEditSheetView` when opened from the
/// the Edit screen's BOARD section (Board Edit redesign slice 2, D9 —
/// docs/BOARD_EDIT_REDESIGN.md). `CoreDefaultsEditSheetView` takes pools /
/// tasks / templates / roster mix / library as props — today only loaded by
/// `BoardSettingsView`. This host mounts the SAME set of loads (mirroring
/// `BoardSettingsView.reload()`) only while the sheet is open, so a core
/// board's menu can reuse the existing sheet without duplicating its form
/// logic.
struct CoreDefaultsSheetHost: View {
    let timeframe: Timeframe
    let userId: String
    let onSaved: () -> Void

    @State private var coreDefault: CoreBoardDefault?
    @State private var pools: [Pool] = []
    @State private var tasks: [Task] = []
    @State private var rosterVM: RecurringBoardTemplatesViewModel
    @State private var library: TaskLibraryViewModel
    @State private var isLoaded = false
    @State private var loadError: String?

    private let database: AppDatabase

    init(
        timeframe: Timeframe,
        userId: String,
        database: AppDatabase = .shared,
        onSaved: @escaping () -> Void
    ) {
        self.timeframe = timeframe
        self.userId = userId
        self.database = database
        self.onSaved = onSaved
        _rosterVM = State(initialValue: RecurringBoardTemplatesViewModel(database: database))
        _library = State(initialValue: TaskLibraryViewModel(database: database))
    }

    var body: some View {
        Group {
            if isLoaded {
                CoreDefaultsEditSheetView(
                    timeframe: timeframe,
                    coreDefault: coreDefault,
                    pools: pools,
                    tasks: tasks,
                    templates: rosterVM.templates,
                    // Written in the same load pass as `templates` below, so
                    // the two always describe the same roster.
                    achievableTaskIdsByTemplateId: rosterVM.mixByTemplateId,
                    library: library,
                    userId: userId,
                    onSaved: onSaved
                )
            } else {
                ZStack {
                    RisoPaperBackground()
                    if let loadError {
                        Text(loadError)
                            .font(.risoBody(13, .semibold))
                            .foregroundStyle(Color.risoRed)
                            .padding(.horizontal, Riso.gutter)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        await rosterVM.reload(userId: userId)
        await library.reload(userId: userId)
        let db = database
        let tf = timeframe
        let uid = userId
        do {
            let (defaults, poolsFetched, tasksFetched) = try await _Concurrency.Task.detached(priority: .userInitiated) {
                let defaults = try db.fetchCoreBoardDefaults(userId: uid)
                let poolsFetched = try db.fetchPools(userId: uid)
                let tasksFetched = try db.fetchTasks(userId: uid)
                return (defaults, poolsFetched, tasksFetched)
            }.value
            coreDefault = defaults.first { $0.timeframe == tf }
            pools = poolsFetched
            tasks = tasksFetched
            isLoaded = true
        } catch {
            loadError = "Failed to load core defaults: \(error.localizedDescription)"
        }
    }
}
