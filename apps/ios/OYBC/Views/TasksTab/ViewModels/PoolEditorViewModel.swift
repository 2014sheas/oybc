import Foundation
import Observation

/// State + logic for the full-screen pool editor (`PoolEditorView`). The
/// pool editor mirrors the board wizard's Tasks step: the pool's tasks show
/// as the wizard's resting rows with an inline row editor whose Save STAGES a
/// `TaskEditPatch` (nothing touches the DB until the editor's Save, which
/// writes the staged edits + pool membership in one transaction —
/// `AppDatabase.savePoolWithStagedEdits`).
///
/// DB-injected (ROADMAP B3 seam): defaults to `.shared`, constructible against
/// `AppDatabase.makeTestInstance()`. Twin of web `PoolEditorBody` state.
@Observable
final class PoolEditorViewModel {

    /// What `save()` did.
    enum SaveOutcome {
        /// Saved. `created` is the new pool on a create-mode save, else nil.
        case saved(created: Pool?)
        /// Not saved; `errorMessage` says why.
        case failed
    }

    // MARK: - Inputs

    /// The pool being edited; `nil` ⇒ create mode.
    let pool: Pool?
    let userId: String
    /// Read reactively so a quick-added task resolves once the library reloads.
    let library: TaskLibraryViewModel
    /// Active repeating-board templates — only the deck-preview floor reads them.
    let templates: [RecurringBoardTemplate]
    @ObservationIgnored let database: AppDatabase

    // MARK: - Form state

    var name: String
    /// The pool's ordered `taskIds`, INCLUDING unresolvable ids (kept on save,
    /// per `Pool.taskIds`'s contract).
    var poolTaskIds: [String]
    /// Staged inline edits keyed by task id.
    var stagedEdits: [String: TaskEditPatch] = [:]

    // Inline row editor (at most one open).
    var editingTaskId: String?
    var editDraft = TaskEditPatch(title: "")
    /// The draft as it opened — Discard compares against it.
    var editBaseline = TaskEditPatch(title: "")

    /// Compound editor inputs from `fetchCompoundPickerInputs` (browsable
    /// library + live links).
    var pickerLibraryBase: [Task] = []
    var allLinks: [CompoundChild] = []

    var busy = false
    var errorMessage: String?

    init(
        pool: Pool?,
        userId: String,
        library: TaskLibraryViewModel,
        templates: [RecurringBoardTemplate] = [],
        initialTaskIds: [String] = [],
        database: AppDatabase = .shared
    ) {
        self.pool = pool
        self.userId = userId
        self.library = library
        self.templates = templates
        self.database = database
        self.name = pool?.name ?? ""
        self.poolTaskIds = pool?.taskIds ?? initialTaskIds
    }

    var isEditMode: Bool { pool != nil }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Effective (staged-overlaid) maps

    /// Library tasks (FULL set, so a draft-hidden task still resolves) with
    /// staged edits overlaid and brand-new staged sub-task placeholders added.
    var effectiveTaskById: [String: Task] {
        var by = Dictionary(library.libraryTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, patch) in stagedEdits {
            if let base = by[id] { by[id] = patch.applied(to: base) }
        }
        for (id, task) in stagedNewChildPlaceholders(userId: userId, stagedEdits: stagedEdits) {
            by[id] = task
        }
        return by
    }

    var effectiveChildrenByCompound: [String: [CompoundChild]] {
        effectiveCompoundChildrenByCompound(library: library, pendingTasks: [:], stagedEdits: stagedEdits)
    }

    /// taskId → count of distinct boards it is placed on.
    var sharedCountByTaskId: [String: Int] {
        var buckets: [String: Set<String>] = [:]
        for bt in library.allLibraryBoardTasks { buckets[bt.taskId, default: []].insert(bt.boardId) }
        return buckets.mapValues { $0.count }
    }

    /// The RESOLVABLE subset of `poolTaskIds`, in order, staged edits applied.
    var selectedTasks: [Task] {
        Self.resolveChips(taskIds: poolTaskIds, libraryTasks: Array(effectiveTaskById.values))
    }

    /// Browse-visible, supply-eligible tasks (achievements are banned from
    /// pools) with staged edits overlaid — the ADD surfaces' candidate list.
    var poolableBrowsableTasks: [Task] {
        let byId = effectiveTaskById
        return library.browsableTasks
            .filter { BoardSources.isSourceSupplyTask($0) }
            .map { byId[$0.id] ?? $0 }
    }

    /// Compound editor's sub-task quick-add match source (DB-backed browsable
    /// tasks, staged edits overlaid).
    var pickerLibraryTasks: [Task] {
        let byId = effectiveTaskById
        return pickerLibraryBase.map { byId[$0.id] ?? $0 }
    }

    func libraryResults(query: String) -> [Task] {
        Self.filterLibraryResults(
            browsableTasks: poolableBrowsableTasks,
            selectedIds: Set(poolTaskIds),
            query: query
        )
    }

    /// Save needs a name, at least one RESOLVABLE task, no open invalid
    /// editor state, and no write in flight.
    var canSave: Bool { !trimmedName.isEmpty && !selectedTasks.isEmpty && !busy }

    /// The claim is about what boards can PULL, so supply-eligible only.
    func deckPreviewText() -> String {
        PoolHealth.formatDeckPreview(
            taskCount: selectedTasks.filter { BoardSources.isSourceSupplyTask($0) }.count,
            deckFloor: PoolHealth.computeDeckFloor(templates: templates, poolId: pool?.id ?? "")
        )
    }

    // MARK: - Membership

    func add(_ taskId: String) {
        if !poolTaskIds.contains(taskId) { poolTaskIds.append(taskId) }
    }

    /// Remove a row; purges its staged edit and closes its editor.
    func remove(_ taskId: String) {
        poolTaskIds.removeAll { $0 == taskId }
        stagedEdits.removeValue(forKey: taskId)
        if editingTaskId == taskId { editingTaskId = nil }
    }

    /// Drops staged edits whose task is no longer a pool member or no longer
    /// resolves in the library (e.g. deleted by sync after staging), so the
    /// strict apply at Save can't throw for a row the user can't see.
    func pruneStaleStagedEdits() {
        stagedEdits = Self.pruneStagedEdits(
            stagedEdits, poolTaskIds: poolTaskIds,
            resolvableIds: Set(library.libraryTasks.map(\.id))
        )
        if let id = editingTaskId, stagedEdits[id] == nil, !Set(library.libraryTasks.map(\.id)).contains(id) {
            editingTaskId = nil
        }
    }

    /// Pure core of `pruneStaleStagedEdits`.
    static func pruneStagedEdits(
        _ edits: [String: TaskEditPatch], poolTaskIds: [String], resolvableIds: Set<String>
    ) -> [String: TaskEditPatch] {
        let members = Set(poolTaskIds)
        return edits.filter { members.contains($0.key) && resolvableIds.contains($0.key) }
    }

    // MARK: - Inline row editor (wizard `openEditor`/`saveEdit`/`discardEdit` twin)

    /// Open a row. Reopening reuses the staged patch verbatim (the overlay
    /// carries scalar edits but not compound child edits); the first open
    /// seeds via `seededForEditor` + `ChildPatch(from:)`.
    func openEditor(_ taskId: String) {
        let byId = effectiveTaskById
        guard let task = byId[taskId] else { return }
        let draft: TaskEditPatch
        if let staged = stagedEdits[taskId] {
            draft = staged
        } else {
            var d = TaskEditPatch.seededForEditor(from: task)
            if task.type == .compound {
                let links = (effectiveChildrenByCompound[taskId] ?? []).sorted { $0.childIndex < $1.childIndex }
                d.children = links.compactMap { link in byId[link.childTaskId].map { ChildPatch(from: $0) } }
            }
            draft = d
        }
        editDraft = draft
        editBaseline = draft
        editingTaskId = taskId
    }

    /// Stage the open draft (no DB write) and close the editor.
    func saveEdit() {
        guard let id = editingTaskId else { return }
        stagedEdits[id] = editDraft
        editingTaskId = nil
    }

    /// Whether the open draft differs from how it opened.
    var editHasChanges: Bool { editDraft != editBaseline }

    /// Close the editor without staging. Returns whether anything was dropped.
    @discardableResult
    func discardEdit() -> Bool {
        let changed = editHasChanges
        editingTaskId = nil
        return changed
    }

    /// Loads the compound editor's picker inputs.
    func loadPickerInputs() {
        do {
            let inputs = try database.fetchCompoundPickerInputs(userId: userId)
            pickerLibraryBase = inputs.libraryTasks
            allLinks = inputs.allLinks
        } catch {
            dlog("PoolEditorViewModel.loadPickerInputs failed: \(error)")
        }
    }

    // MARK: - Persistence

    /// One GRDB write: staged edits + membership. Sets `busy` / `errorMessage`.
    @discardableResult
    func save() async -> SaveOutcome {
        guard canSave else { return .failed }
        if let lengthError = Self.nameLengthError(for: trimmedName) {
            errorMessage = lengthError
            return .failed
        }
        busy = true
        errorMessage = nil
        let db = database
        let existingId = pool?.id
        let uid = userId
        let trimmed = trimmedName
        let ids = poolTaskIds
        pruneStaleStagedEdits()
        let edits = stagedEdits
        do {
            let saved = try await _Concurrency.Task.detached(priority: .userInitiated) {
                try db.savePoolWithStagedEdits(
                    existingId: existingId, userId: uid, name: trimmed, taskIds: ids,
                    stagedEdits: edits, now: AppDatabase.currentTimestamp()
                )
            }.value
            busy = false
            return .saved(created: existingId == nil ? saved : nil)
        } catch {
            busy = false
            errorMessage = "Could not save pool: \(error.localizedDescription)"
            return .failed
        }
    }

    /// Soft-delete the pool (edit mode). Returns success.
    func delete() async -> Bool {
        guard let existing = pool, !busy else { return false }
        busy = true
        errorMessage = nil
        let db = database
        do {
            try await _Concurrency.Task.detached(priority: .userInitiated) {
                try db.softDeletePoolAndEnqueue(id: existing.id, now: AppDatabase.currentTimestamp())
            }.value
            busy = false
            return true
        } catch {
            busy = false
            errorMessage = "Could not delete pool: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Testable pure helpers (moved from the retired `PoolEditSheetView`)

    /// `PoolSchema.name` bound (`packages/shared/src/validation/schemas.ts`).
    static let nameMaxLength = 120

    /// `nil` when within bounds, else the exact error string (UTF-16 units,
    /// like Zod's `max(120)` / web's `name.length`).
    static func nameLengthError(for trimmedName: String) -> String? {
        guard trimmedName.utf16.count > nameMaxLength else { return nil }
        return "Could not save pool: Pool name must be \(nameMaxLength) characters or fewer."
    }

    /// Library-reuse picker candidates: browsable minus selected, filtered by
    /// a trimmed, case-insensitive title query.
    static func filterLibraryResults(
        browsableTasks: [Task],
        selectedIds: Set<String>,
        query: String
    ) -> [Task] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return browsableTasks
            .filter { !selectedIds.contains($0.id) }
            .filter { q.isEmpty || $0.title.lowercased().contains(q) }
    }

    /// Resolves `taskIds` to the RESOLVABLE subset in `taskIds` order against
    /// the FULL library set; unresolvable ids drop from DISPLAY only.
    static func resolveChips(taskIds: [String], libraryTasks: [Task]) -> [Task] {
        let byId = Dictionary(libraryTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return taskIds.compactMap { byId[$0] }
    }
}
