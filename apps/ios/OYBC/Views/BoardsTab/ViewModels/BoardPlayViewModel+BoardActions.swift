import Foundation
import GRDB

// MARK: - BoardPlayViewModel + Board actions (Board Edit redesign slice 2)

/// The Edit screen's BOARD-section write paths — Board details / Repeat / Archive /
/// Delete — plus the small async read the Repeat sheet needs
/// (`loadSpawnNote`). Split out of
/// `BoardPlayViewModel.swift` (which is at its frozen size cap) alongside
/// `+EditCommit.swift`'s squares-editor commit, docs/BOARD_EDIT_REDESIGN.md.
///
/// Unlike `+EditCommit.swift`'s `handleEditSave` (a fire-and-forget dispatch
/// that reports back through the one-shot `editEvent`), these are plain
/// `async throws` functions — `BoardActionsPresenter` awaits them directly
/// from a `_Concurrency.Task`, which is a cleaner fit now that there's no
/// staged multi-field draft to snapshot before detaching.
extension BoardPlayViewModel {

    /// Commits the "Board details" sheet's patch in one transaction
    /// (`AppDatabase.saveBoardDetails`), then reloads.
    ///
    /// - Throws: `BoardEditError.boardNotEditable` for a board sealed or
    ///   deleted since the sheet opened (nothing written); any GRDB error.
    func saveBoardDetails(_ patch: AppDatabase.UpdateActiveBoardPatch) async throws {
        let bid = boardId
        let db = database
        try await _Concurrency.Task.detached(priority: .userInitiated) {
            try db.saveBoardDetails(boardId: bid, patch: patch)
        }.value
        reload()
    }

    /// Commits the "Repeat this board" sheet's staged intent — mints a
    /// repeating record (one-off → repeating) or flips the resolved
    /// record's Active toggle. Lifted verbatim from `+EditCommit.swift`'s
    /// former Save phase 2.
    ///
    /// - Throws: `BoardEditError.boardNotEditable` if `.startRepeating`
    ///   targets a board sealed or deleted since the sheet opened; any
    ///   GRDB error.
    func saveRepeat(_ intent: EditRepeatIntent, weekStartDay: String) async throws {
        let bid = boardId
        let db = database
        let repeatUserId = userId
        try await _Concurrency.Task.detached(priority: .userInitiated) {
            let now = AppDatabase.currentTimestamp()
            switch intent {
            case .startRepeating(let cadence):
                guard let repeatUserId, let freshBoard = try db.fetchBoard(id: bid) else { return }
                _ = try db.repeatBoardAsTemplate(
                    board: freshBoard,
                    cadence: cadence,
                    userId: repeatUserId,
                    weekStartDay: weekStartDay,
                    now: now
                )
            case .setActive(let template, let isActive):
                _ = try db.setTemplateActive(id: template.id, isActive: isActive, now: now)
            }
        }.value
        reload()
    }

    /// Closes the current board (Board Edit redesign slice 4, D3 — the
    /// "Close board" menu row / closing-out banner's "Close out"). Reloads
    /// on success; a board that raced to already-closed (`false` return) is
    /// treated the same as success (idempotent no-op).
    ///
    /// - Throws: `BoardLifecycleError.notClosable` if the board is no longer
    ///   eligible (deleted / draft / indefinite / not yet ended).
    func closeBoard() async throws {
        let bid = boardId
        let db = database
        try await _Concurrency.Task.detached(priority: .userInitiated) {
            _ = try db.closeBoard(boardId: bid)
        }.value
        reload()
    }

    /// Reopens the current CLOSED board (Board Edit redesign slice 4, D6).
    ///
    /// - Throws: `BoardLifecycleError.notReopenable` if the board is
    ///   missing, deleted, or not currently sealed.
    func reopenBoard() async throws {
        let bid = boardId
        let db = database
        try await _Concurrency.Task.detached(priority: .userInitiated) {
            _ = try db.reopenBoard(boardId: bid)
        }.value
        reload()
    }

    /// Archives the current board (`status = .archived`).
    func archiveBoard() async throws {
        let bid = boardId
        let db = database
        try await _Concurrency.Task.detached(priority: .userInitiated) {
            try db.archiveBoard(id: bid)
        }.value
        reload()
    }

    /// Soft-deletes the current board. No reload — the caller (menu
    /// presenter) dismisses / navigates away rather than re-rendering a
    /// just-deleted board.
    func deleteBoard() async throws {
        let bid = boardId
        let db = database
        try await _Concurrency.Task.detached(priority: .userInitiated) {
            try db.deleteBoard(id: bid)
        }.value
    }

    /// Read-only spawn-provenance note for the Repeat sheet's
    /// repeating-board variant, resolved off-main only while that sheet is
    /// open (moved out of `seedEditDraft`, which no longer seeds a
    /// metadata/repeat draft — the squares editor doesn't show this note).
    /// Nil for a one-off board, an unresolved source record, or a board
    /// that is no longer freshly dealt.
    func loadSpawnNote() async -> String? {
        guard let b = board, let template = editSourceTemplate,
              isFreshlyDealtBoard(
                  completedTasks: b.completedTasks,
                  boardSize: b.boardSize,
                  centerSquareType: b.centerSquareType
              )
        else { return nil }
        let poolsById = Dictionary(uniqueKeysWithValues: allPoolsInWorkspace.map { ($0.id, $0) })
        let tasksById = taskMap
        let dealt = boardTasks.map { $0.taskId }
        let db = database
        return await _Concurrency.Task.detached(priority: .utility) {
            db.spawnProvenanceNote(
                template: template,
                poolsById: poolsById,
                tasksById: tasksById,
                dealtTaskIds: dealt
            )
        }.value
    }
}
