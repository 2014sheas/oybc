import Foundation
import GRDB
import Observation

/// Owns the list of tasks placed on currently-active longer-window
/// "parent" boards for the wizard's selected timeframe. iOS twin of
/// web's `useParentBoardTasks` hook (Phase 6.1b).
///
/// Used by `BoardWizardTasksStepView` when the "From parent boards"
/// filter chip is active. Per Phase 6.1's locked design, selecting one
/// of these tasks places the SAME task on the new (child) board —
/// completion is shared globally.
///
/// Loading is imperative — the view calls `reload(userId:childTimeframe:)`
/// on appear and whenever the wizard's timeframe changes. Mirrors the
/// pattern used by `TaskLibraryViewModel` and friends.
@Observable
final class ParentBoardTasksViewModel {

    // MARK: - State

    /// Unique tasks placed on currently-active parent boards, ordered
    /// alphabetically by title for predictable UI.
    var tasks: [Task] = []

    /// Last load error — silently swallowed at the view layer (the
    /// "From parents" filter just shows an empty state on failure;
    /// blocking the whole tasks step would be too disruptive for what
    /// is a soft, opt-in convenience filter).
    var loadError: String?

    // MARK: - Race-condition guard
    //
    // The wizard's child timeframe can change faster than GRDB completes a
    // read (e.g., the user toggles back to step 1 and switches daily →
    // monthly within a frame). Both timeframes have parents, so the chip
    // stays visible — but their parent SETS differ (daily's parents include
    // weekly/monthly/yearly; monthly's parents are yearly only). Without a
    // latest-wins guard, the earlier reload's results can land *after* the
    // newer reload, overwriting `tasks` with weekly/monthly tasks that
    // shouldn't appear on a monthly board.
    //
    // `latestSeq` is bumped on the main actor at the start of every reload;
    // the result is committed only if no newer request has started in the
    // meantime. `@ObservationIgnored` so SwiftUI doesn't track it and
    // re-render on each bump.
    @ObservationIgnored private var latestSeq: UInt64 = 0

    // MARK: - DB injection

    /// Injected for tests; defaults to the production singleton.
    @ObservationIgnored private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Loading

    /// Loads parents + their board_tasks + resolves to deduped Task[].
    /// Returns early with `tasks = []` for child timeframes that have
    /// no parents (yearly, custom).
    func reload(userId: String, childTimeframe: Timeframe) async {
        let mySeq = await MainActor.run { () -> UInt64 in
            latestSeq &+= 1
            return latestSeq
        }

        let now = Date()
        let parentTimeframes = parentTimeframesByChild[childTimeframe] ?? []
        if parentTimeframes.isEmpty {
            await MainActor.run {
                guard mySeq == latestSeq else { return }
                self.tasks = []
                self.loadError = nil
            }
            return
        }

        do {
            let result = try await database.read { db -> [Task] in
                let userBoards = try Board
                    .filter(Column("userId") == userId && Column("isDeleted") == false)
                    .fetchAll(db)
                let parents = getParentBoards(
                    childTimeframe: childTimeframe,
                    allActiveBoards: userBoards,
                    now: now
                )
                if parents.isEmpty { return [] }

                let parentIds = Set(parents.map { $0.id })
                // Push the boardId filter into SQLite rather than loading
                // every BoardTask row and filtering in Swift — important
                // as the user accumulates more boards and placements over
                // time. Mirror of the web Dexie perf fix.
                let parentBoardTasks = try BoardTask
                    .filter(parentIds.contains(Column("boardId")) && Column("isDeleted") == false)
                    .fetchAll(db)
                let taskIds = Set(parentBoardTasks.map { $0.taskId })
                if taskIds.isEmpty { return [] }

                let tasks = try Task
                    .filter(taskIds.contains(Column("id")) && Column("isDeleted") == false)
                    .fetchAll(db)
                return tasks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }

            await MainActor.run {
                guard mySeq == latestSeq else { return }
                self.tasks = result
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                guard mySeq == latestSeq else { return }
                self.loadError = "Failed to load parent-board tasks: \(error.localizedDescription)"
                self.tasks = []
            }
        }
    }

    /// Sync shim for view-side fire-and-forget callers.
    func reloadAsync(userId: String, childTimeframe: Timeframe) {
        _Concurrency.Task { await reload(userId: userId, childTimeframe: childTimeframe) }
    }
}
