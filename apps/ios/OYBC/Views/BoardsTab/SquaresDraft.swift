import Foundation

// MARK: - SquaresDraftCell

/// Per-cell staged state for Phase 2 board-edit mode.
///
/// Seeded from the board's live `BoardTask` rows when the user enters edit
/// mode. The cell's `stagedTaskId` may be changed by a "Replace task" action
/// (still no DB write — committed on "Save changes"). Task-field edits are
/// stored globally in `editTaskOverrides` (keyed by taskId) on
/// `BoardPlayView`, since a `Task` is global and editing it affects every
/// square it appears on.
///
/// The `originalTaskId` is preserved so `BoardPlayView` can compute the
/// replacement edit count (cells where `stagedTaskId != originalTaskId`).
struct SquaresDraftCell {
    /// `BoardTask.id` for the placement row — used to call
    /// `updateBoardTaskAndCascade(boardTaskId:newTaskId:)` at commit.
    let boardTaskId: String
    let row: Int
    let col: Int
    let isCenter: Bool

    /// The taskId held by this placement at draft-seed time.
    let originalTaskId: String

    /// Currently staged taskId. Equals `originalTaskId` until the user
    /// completes a "Replace task" action on this cell.
    var stagedTaskId: String
}

// MARK: - StagedTaskOverride

/// In-memory overrides for a `Task`'s editable fields (Phase 2 "Edit task").
///
/// Keyed by `taskId` in `BoardPlayView.editTaskOverrides`. Applied to the
/// live `taskMap` when rendering the edit-mode draft grid and at "Save changes"
/// commit time via `saveTaskAndCascade`.
///
/// Only fields visible in `SquareEditTaskSheet` are staged here. The full
/// `EditTaskSheet` (Tasks tab) is a separate, richer flow with description,
/// timeboxed dates, achievement config — none of those are exposed from the
/// board-edit context.
struct StagedTaskOverride {
    var title: String
    var type: TaskType
    // Counting-specific — nil means "not set by the user in this session".
    var action: String?
    var unit: String?
    var maxCount: Int?
}

// MARK: - EditModeSwapTarget

/// Drives the `CellSwapSheet` presented from the "Replace task" tap-menu
/// action in board-edit mode.
///
/// `id` is the cell key (`"\(row)-\(col)"`) so the `.sheet(item:)` modifier
/// treats each cell tap as a distinct identity.
struct EditModeSwapTarget: Identifiable {
    /// Cell key e.g. `"1-2"`.
    let id: String
    /// The taskId currently staged on this cell (used to exclude it from the
    /// library picker so the user can't re-select the same task).
    let currentTaskId: String
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
