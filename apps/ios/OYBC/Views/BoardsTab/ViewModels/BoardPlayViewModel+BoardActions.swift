import Foundation
import GRDB

// MARK: - BoardPlayViewModel + Board actions (Board Edit redesign slice 2)

/// The Edit screen's BOARD-section write paths — Board details / Repeat / Archive /
/// Delete. Split out of
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

    /// Reverses the SOURCE counter's last log entry (`undoLastCounterLog`) —
    /// wired to the credited toast's Undo pill (R3 board-play touchpoints).
    /// Mirrors `CounterDetailView.handleUndo`: runs the write off-main, then
    /// reloads on the main actor. Reverses the counter's LATEST live entry
    /// at tap time — if a second log landed elsewhere during the toast
    /// window, THAT entry is reversed (not a no-op, and not necessarily the
    /// displayed one); accepted single-user race, same semantics as R2's
    /// Hub/Detail Undo (docs/SHARED_COUNTERS.md §R3) — matches
    /// `undoLastCounterLog`'s own no-op contract.
    ///
    /// - Parameter sourceTaskId: The counter's source task id (the toast's
    ///   `CreditToastState.sourceTaskId` on the view side).
    func undoSharedCounterLog(sourceTaskId: String) {
        guard !isProcessing else { return }
        setProcessing(true)
        let database = self.database
        let currentBoardId = board?.id
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            // Capture pre-undo board stats for the board-transition flash (F1).
            let boardBefore: Board? = currentBoardId.flatMap { id in
                try? database.read { db in try Board.fetchOne(db, key: id) }
            }
            let result = try? database.undoLastCounterLog(sourceTaskId: sourceTaskId)

            // Board-transition flash (F1): reversing a log runs the same board
            // derivation cascade as a decrement, so it can drop a completed
            // square below its goal on this window and flip the board
            // COMPLETED → ACTIVE, dropping bingo lines. Mirror the decrement
            // path so the Undo pill surfaces the same feedback (only the
            // reactivated / lost-bingo rungs can fire). No-op when nothing was
            // reversed (`undoneAmount == 0`).
            var newBingoMsg: String? = nil
            if let result = result, result.undoneAmount > 0 {
                let boardAfter: Board? = currentBoardId.flatMap { id in
                    try? database.read { db in try Board.fetchOne(db, key: id) }
                }
                if let before = boardBefore, let after = boardAfter {
                    let prevBingos = Set(before.completedLineIds ?? [])
                    let nextBingos = Set(after.completedLineIds ?? [])
                    let lost = prevBingos.subtracting(nextBingos).sorted()
                    if before.status == .completed && after.status == .active {
                        newBingoMsg = "Board reactivated — no longer complete"
                    } else if !lost.isEmpty {
                        newBingoMsg = "Bingo lost: \(lost.joined(separator: ", "))"
                    }
                }
            }

            await MainActor.run {
                self.reload { self.setProcessing(false) }
                if let msg = newBingoMsg {
                    self.bingoMessage = msg
                    self.scheduleBingoMessageDismiss(msg)
                    self.emitFlash(risoNotification: msg, creditToast: nil)
                }
            }
        }
    }
}
