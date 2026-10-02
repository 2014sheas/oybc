import Foundation

// MARK: - SquaresDraftCell

/// One occupied square's staged state in the Board Edit redesign slice 3
/// squares editor.
///
/// Keyed EXTERNALLY by its CURRENT "row-col" slot in
/// `BoardPlayViewModel.editSquaresDraft` — position-keyed (D20): the ordered
/// grid array (`buildSquaresEditCells`) is rebuilt FRESH from this dictionary
/// on every read, never incrementally patched. This closes two slice-2 bugs:
/// a replace used to drop `isLocked` from the rearrange cell, and a remove
/// could mint a colliding `"empty-R-C"` id after a drop-to-empty swap.
///
/// A square with no entry at a given key is an EMPTY square (dashed, tappable
/// to add) — mirrors the pre-slice-3 convention.
struct SquaresDraftCell {
    /// Stable identity across a move or a Shuffle:
    ///   - An existing placement: the live `BoardTask.id`.
    ///   - A staged add (`isNew == true`): a synthetic `"new-<uuid>"` id —
    ///     nothing exists in the DB yet; the REAL `BoardTask.id` is minted by
    ///     `addBoardTaskToBoard` at Save (D15 step 7).
    let id: String
    /// True when this cell has no corresponding live `BoardTask` row.
    let isNew: Bool
    /// The task currently occupying the square. Always a real (possibly
    /// not-yet-persisted) task id — the quick-add / special-type panel
    /// mints the id client-side before `onPendingCreated` fires, exactly
    /// like the wizard's Bug #85 deferred-persist path.
    var taskId: String
    /// Non-nil ⇒ `taskId`'s `Task` does not exist in the DB yet (staged via
    /// the picker's quick-add or special-type panel — Normal / Counting /
    /// Achievement). Inserted at Save (D15 step 1) with `createdInWizard:
    /// false` — a deliberate library task, unlike the wizard's hidden
    /// drafts. A Compound picked from the special panel is deferred the same
    /// way on iOS: its child tasks + links ride in the payload and are
    /// inserted at Save (web persists a picker-born compound immediately).
    var pending: PendingTaskPayload?
    /// Draft lock state (`Lock in place` / `Unlock`). For a staged add this
    /// is written directly by `addBoardTaskToBoard(isLocked:)` at Save — it
    /// is never diffed against `originalIsLocked` for that case (see
    /// `SquaresEditCount`).
    var isLocked: Bool

    // Baseline (seed-time) values — nil / false for a staged add.
    let originalRow: Int?
    let originalCol: Int?
    let originalTaskId: String?
    let originalIsLocked: Bool
}

// MARK: - StagedTaskOverride
// (unchanged from slice 2 — Phase 2 "Edit task" staged field overrides,
// keyed by taskId in `BoardPlayViewModel.editTaskOverrides`.)

/// In-memory overrides for a `Task`'s editable fields (Phase 2 "Edit task").
///
/// Keyed by `taskId` in `BoardPlayViewModel.editTaskOverrides`. Applied to the
/// live `taskMap` when rendering the edit-mode draft grid and at "Save changes"
/// commit time.
///
/// Only fields visible in `SquareEditTaskSheet` are staged here. The full
/// `EditTaskSheet` (Tasks tab) is a separate, richer flow with description,
/// timeboxed dates, achievement config — none of those are exposed from the
/// board-edit context.
///
/// `type` only takes effect Simple ⇄ Counting and Simple/Counting → Compound
/// (`BoardPlayViewModel.applyingOverride`); a compound's or an achievement's
/// type is never changed through Board Edit.
struct StagedTaskOverride {
    var title: String
    var type: TaskType
    // Counting-specific — nil means "not set by the user in this session".
    var action: String?
    var unit: String?
    var maxCount: Int?
    /// Compound rule + sub-task edits (a conversion into Compound, or an
    /// edited existing compound) — applied at Save by `applyStagedOverrides`.
    var compound: TaskEditPatch?
}

// MARK: - EditModeTaskTarget

/// Drives the `SquareEditTaskSheet` presented from the "Edit task" tap-menu
/// action in board-edit mode.
///
/// `id` is the cell key so the `.sheet(item:)` modifier replaces sheets when
/// the user taps a different cell.
struct EditModeTaskTarget: Identifiable {
    /// Cell key e.g. `"2-0"`.
    let id: String
    /// The task to edit — already has any previously staged overrides applied
    /// by `BoardPlayView.editDraftTaskMap`.
    let task: Task
}

// MARK: - SquareEditCellData

/// One slot in the unified squares-edit grid (Board Edit redesign slice 3,
/// D7 — the "Edit tasks ⇄ Rearrange" sub-modes are retired in favor of ONE
/// grid). Row-major ordered — built FRESH on every read by
/// `buildSquaresEditCells`, never patched (D20).
struct SquareEditCellData: Identifiable {
    /// Stable unique identifier — `BoardTask.id`, a staged add's synthetic
    /// id, `"center"`, or `"empty-R-C"`.
    let id: String
    /// The cell's CURRENT (staged) `Task.id` — nil for the FREE center or an
    /// empty square.
    let taskId: String?
    /// Non-nil when `taskId`'s task hasn't been created yet — the grid reads
    /// title/type from `pending.task` instead of a `taskMap` lookup.
    let pending: PendingTaskPayload?
    let isCenter: Bool
    let isEmpty: Bool
    var isLocked: Bool = false
    /// Original DB `(row, col)` — used to compute position moves at Save
    /// time. For a staged add (no live row yet) this is its CURRENT slot,
    /// since it has no "original" position to differ from.
    let originalRow: Int
    let originalCol: Int
    /// Gold pencil chip (D12) — precomputed here (not a separate `Set` the
    /// caller has to intersect) since `buildSquaresEditCells` already has
    /// every input it needs.
    var isDirty: Bool = false

    /// Pinned = fixed in place for every rearrange gesture, Shuffle, and the
    /// cascade. The FREE center or any locked square.
    var isPinned: Bool { isCenter || isLocked }
}

extension SquareEditCellData: Equatable {
    /// Manual conformance: `pending` (`PendingTaskPayload`) isn't Equatable,
    /// and doesn't need to be — a cell's identity/task/lock/position/dirty
    /// state fully describes what `SquaresEditGrid.onChange(of:)` needs to
    /// detect.
    static func == (lhs: SquareEditCellData, rhs: SquareEditCellData) -> Bool {
        lhs.id == rhs.id
            && lhs.taskId == rhs.taskId
            && lhs.isCenter == rhs.isCenter
            && lhs.isEmpty == rhs.isEmpty
            && lhs.isLocked == rhs.isLocked
            && lhs.originalRow == rhs.originalRow
            && lhs.originalCol == rhs.originalCol
            && lhs.isDirty == rhs.isDirty
    }
}

// MARK: - SquaresEditCount (D11)

/// Pure, VM-free edit-counter kernel (Board Edit redesign slice 3, D11).
/// Unit-testable without a `BoardPlayViewModel` — see `SquaresEditDraftTests`.
enum SquaresEditCount {
    struct Input {
        var replacements: Int
        var adds: Int
        var removals: Int
        var taskOverrides: Int
        var lockChanges: Int
        var centerChanged: Bool
        /// Count of EXISTING placements whose current slot differs from
        /// their seeded slot (staged adds are never "moved" — their
        /// position is baked into the single add edit).
        var movedPlacements: Int
        /// True once the user has run Shuffle this session (never cleared
        /// except by re-seeding — see `BoardPlayViewModel.seedEditDraft`).
        var shuffled: Bool
    }

    /// `count = replacements + adds + removals + taskOverrides + lockChanges
    /// + centerChange + positionEdits`, where `positionEdits = 0` when
    /// nothing moved, else `1` if `shuffled`, else the literal moved count.
    static func count(_ input: Input) -> Int {
        let positionEdits = input.movedPlacements == 0
            ? 0
            : (input.shuffled ? 1 : input.movedPlacements)
        return input.replacements + input.adds + input.removals
            + input.taskOverrides + input.lockChanges
            + (input.centerChanged ? 1 : 0) + positionEdits
    }
}

// MARK: - SquaresEditDirty (D12)

/// Pure gold-pencil-chip predicate (Board Edit redesign slice 3, D12).
enum SquaresEditDirty {
    /// - Parameters:
    ///   - cell: The draft cell (never called for an empty square or the
    ///     FREE center — neither has a `SquaresDraftCell`).
    ///   - moved: Whether the cell's current slot differs from its seeded
    ///     slot (always `false` for a staged add).
    ///   - hasTaskOverride: Whether `cell.taskId` has a staged
    ///     `StagedTaskOverride` (title/type/counting-field edit).
    static func isDirty(cell: SquaresDraftCell, moved: Bool, hasTaskOverride: Bool) -> Bool {
        if cell.isNew { return true }
        if cell.taskId != cell.originalTaskId { return true }
        if hasTaskOverride { return true }
        if cell.isLocked != cell.originalIsLocked { return true }
        if moved { return true }
        return false
    }
}

// MARK: - Cell-key helpers

/// Parses a `"row-col"` draft key. Returns `nil` for a malformed key (should
/// never happen — every key is minted by `"\(row)-\(col)"`).
func parseSquareCellKey(_ key: String) -> (row: Int, col: Int)? {
    let parts = key.split(separator: "-")
    guard parts.count == 2, let r = Int(parts[0]), let c = Int(parts[1]) else { return nil }
    return (row: r, col: c)
}

// MARK: - buildSquaresEditCells (replaces buildRearrangeCells)

/// Builds the ordered `[SquareEditCellData]` array for `SquaresEditGrid` from
/// the current edit draft state. The array is row-major (row 0 col 0 … row N
/// col N) and rebuilt FRESH every call (D20) — the caller should treat it as
/// a computed property over the draft, not stored/patched state.
///
/// - Parameters:
///   - draft: Keyed by `"\(row)-\(col)"` — occupied squares only (no
///     center/empty entries; an empty square is simply absent).
///   - gridSize: Board edge length (3, 4, or 5).
///   - centerType: The EFFECTIVE center type (`CenterSquare.effectiveCenter`
///     already applied by the caller) — `.free` or `.none`, never `.chosen`.
///   - hasTaskOverride: Whether a cell's occupant task carries a staged
///     `StagedTaskOverride` (feeds the dirty chip).
/// - Returns: Row-major ordered array with every slot filled (task cell,
///   FREE center, or empty).
func buildSquaresEditCells(
    draft: [String: SquaresDraftCell],
    gridSize: Int,
    centerType: CenterSquareType,
    hasTaskOverride: (String) -> Bool = { _ in false }
) -> [SquareEditCellData] {
    guard gridSize > 0 else { return [] }
    let mid = gridSize / 2
    var result: [SquareEditCellData] = []
    result.reserveCapacity(gridSize * gridSize)

    for row in 0..<gridSize {
        for col in 0..<gridSize {
            let isPositionalCenter = gridSize % 2 == 1 && row == mid && col == mid
            if isPositionalCenter && centerType == .free {
                result.append(SquareEditCellData(
                    id: "center", taskId: nil, pending: nil,
                    isCenter: true, isEmpty: false, isLocked: false,
                    originalRow: row, originalCol: col, isDirty: false
                ))
                continue
            }
            let key = "\(row)-\(col)"
            if let cell = draft[key] {
                let moved = !cell.isNew
                    && (cell.originalRow != row || cell.originalCol != col)
                let dirty = SquaresEditDirty.isDirty(
                    cell: cell, moved: moved,
                    hasTaskOverride: hasTaskOverride(cell.taskId)
                )
                result.append(SquareEditCellData(
                    id: cell.id, taskId: cell.taskId, pending: cell.pending,
                    isCenter: false, isEmpty: false, isLocked: cell.isLocked,
                    originalRow: cell.originalRow ?? row,
                    originalCol: cell.originalCol ?? col,
                    isDirty: dirty
                ))
            } else {
                result.append(SquareEditCellData(
                    id: "empty-\(row)-\(col)", taskId: nil, pending: nil,
                    isCenter: false, isEmpty: true, isLocked: false,
                    originalRow: row, originalCol: col, isDirty: false
                ))
            }
        }
    }
    return result
}

// MARK: - Reorder algorithm (shared with the grid view)

/// Translates the dragged cell to `targetIndex` (row-major slot), cascading
/// other movable cells around it in row-major order. Returns the new array,
/// or `nil` if the order is unchanged. Fixed slots (pinned — center or
/// locked — and empty) remain in their positions; only movable task cells
/// move.
///
/// Lifted verbatim (rename aside) from the retired `RearrangeGrid` so the
/// static slot-rect hit-testing and cascade math are unchanged (D7).
func reorderSquaresToSlot(
    cells: [SquareEditCellData],
    draggingId: String,
    targetIndex: Int
) -> [SquareEditCellData]? {
    guard targetIndex < cells.count else { return nil }
    let target = cells[targetIndex]
    guard !target.isPinned else { return nil }

    if target.isEmpty {
        guard
            let fromIdx = cells.firstIndex(where: { $0.id == draggingId }),
            fromIdx != targetIndex
        else { return nil }
        var result = cells
        result.swapAt(fromIdx, targetIndex)
        return result
    }

    let movableIndices = cells.indices.filter {
        !cells[$0].isPinned && !cells[$0].isEmpty
    }
    guard let toK = movableIndices.firstIndex(of: targetIndex) else { return nil }

    let movable = movableIndices.map { cells[$0] }
    guard let dragged = movable.first(where: { $0.id == draggingId }) else { return nil }

    var without = movable.filter { $0.id != draggingId }
    without.insert(dragged, at: toK)

    var result = cells
    for (k, slotIdx) in movableIndices.enumerated() {
        result[slotIdx] = without[k]
    }

    let changed = !zip(result, cells).allSatisfy { $0.id == $1.id }
    return changed ? result : nil
}
