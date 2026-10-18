import Foundation
import GRDB

// MARK: - BoardPlayViewModel + shared-counter writes and optimistic counts

// The shared-counter increment / decrement writes, moved verbatim out of
// `BoardPlayViewModel.swift` (frozen at its file-size cap) when optimistic counts
// landed; the only additions are the `addPendingCount` registrations. A write's
// pending delta lives until `isProcessing` returns to false — that happens in the
// reload-completion (after the reload carrying the write has applied) or in the
// failure path, which rolls the delta back.
extension BoardPlayViewModel {

    /// Registers an optimistic delta on a counter family's displayed count (see
    /// `pendingCountDeltas`). Every board-play count read (cell, sheet, menu, Task Detail's
    /// hero through its anchor) adds it on top of the loaded count.
    ///
    /// - Parameters:
    ///   - delta: The signed change the in-flight write will make.
    ///   - familyKey: `countFamilyKey` of the written counter (its shared root, else itself).
    func addPendingCount(_ delta: CountValue, forFamily familyKey: String) {
        guard delta != 0 else { return }
        setPendingCount((pendingCountDeltas[familyKey] ?? 0) + delta, forFamily: familyKey)
    }

    /// Runs the shared-counter increment in a background task, then refreshes
    /// board + task data on the main thread and fires a credit toast when
    /// the ripple reached other boards.
    ///
    /// Mirrors the pattern in `runOrchestration` (uses `_Concurrency.Task.detached`
    /// to avoid shadowing by the GRDB `Task` model).
    ///
    /// - Parameters:
    ///   - sourceTaskId: The source (template) task id to increment.
    ///   - counterName: Display name used in the credit toast copy (R3:
    ///     pair-derived, resolved by the caller — never raw `task.title`).
    ///   - unit: The counter's unit noun, threaded into the credit toast
    ///     payload for the unified `CounterLogToastView`.
    ///   - amount: Amount to log (R3; default 1 preserves prior behavior).
    ///   - persistAsDefault: R3 — forwarded to `setCounterDefaultLogAmount`
    ///     after a successful log; only `true` for an explicit custom entry.
    func runSharedCounterIncrement(
        sourceTaskId: String,
        counterName: String = "",
        unit: String = "", kind: CountKind = .discrete,
        amount: CountValue = 1,
        persistAsDefault: Bool = false
    ) {
        guard !isProcessing else { return }
        setProcessing(true)
        addPendingCount(amount, forFamily: sourceTaskId)
        let currentBoardId = board?.id
        let database = self.database

        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                // Capture pre-increment board stats for flash-message comparison.
                let boardBefore: Board? = currentBoardId.flatMap { id in
                    try? database.read { db in try Board.fetchOne(db, key: id) }
                }

                let creditResult = try database.incrementSharedCounter(
                    sourceTaskId: sourceTaskId, by: amount, boardId: currentBoardId
                )

                // R3 — the amount just used becomes the new default ONLY for an
                // explicit custom "#" entry (Global Constraints: one-tap chips
                // never overwrite the counter's default). No-op if unchanged.
                if persistAsDefault {
                    do {
                        try database.setCounterDefaultLogAmount(sourceTaskId: sourceTaskId, amount: amount)
                    } catch {
                        dlog("BoardPlayVM: failed to persist counter default log amount: \(error)")
                    }
                }

                // Re-fetch the board after the write to detect bingo/greenlog changes.
                let boardAfter: Board? = currentBoardId.flatMap { id in
                    try? database.read { db in try Board.fetchOne(db, key: id) }
                }

                let flash = BoardFlashOutcome.resolve(before: boardBefore, after: boardAfter)

                // P2/R3: Build the credited toast for OTHER boards that changed.
                let otherBoards = creditResult.affectedBoards.filter { $0.boardId != currentBoardId }
                let creditPayload: SharedCounterCreditToastPayload? = otherBoards.isEmpty ? nil :
                    SharedCounterCreditToastPayload(
                        sourceTaskId: sourceTaskId,
                        amount: amount,
                        unit: unit,
                        isIncrement: true,
                        message: Self.sharedCreditToastText(
                            counterName: counterName, amount: amount, kind: kind, isIncrement: true
                        )
                    )

                await MainActor.run {
                    self.reload { self.setProcessing(false) }
                    self.emitFlash(flash, creditToast: creditPayload)
                }
            } catch {
                dlog("⚠️ BoardPlayView shared-counter increment error: \(error)")
                await MainActor.run {
                    self.setProcessing(false)
                }
            }
        }
    }

    /// Runs the shared-counter decrement in a background task, then refreshes
    /// board + task data on the main thread and fires a credit toast when the
    /// ripple reached other boards.
    ///
    /// - Parameters:
    ///   - sourceTaskId: The source (template) task id to decrement.
    ///   - counterName: Display name used in the credit toast copy (R3:
    ///     pair-derived, resolved by the caller — never raw `task.title`).
    ///   - unit: The counter's unit noun, threaded into the credit toast payload.
    ///   - amount: Amount to remove (R3; default 1 preserves prior behavior).
    ///     The engine clamps at 0 — the toast/Undo use the CLAMPED
    ///     `effectiveDelta`, not the requested `amount` (Global Constraints:
    ///     the toast's delta must match what Undo will reverse).
    ///   - persistAsDefault: R3 — forwarded to `setCounterDefaultLogAmount`
    ///     using the REQUESTED `amount` (the user's chosen preference, even
    ///     if the write itself got clamped) after a successful log; only
    ///     `true` for an explicit custom entry.
    func runSharedCounterDecrement(
        sourceTaskId: String,
        counterName: String = "",
        unit: String = "", kind: CountKind = .discrete,
        amount: CountValue = 1,
        persistAsDefault: Bool = false
    ) {
        guard !isProcessing else { return }
        setProcessing(true)
        // The engine clamps at 0, so the optimistic removal never goes below what the board shows.
        addPendingCount(-min(amount, windowedState(forTaskId: sourceTaskId).count), forFamily: sourceTaskId)
        let currentBoardId = board?.id
        let database = self.database

        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                // Capture pre-decrement board stats for the board-transition flash (F1).
                let boardBefore: Board? = currentBoardId.flatMap { id in
                    try? database.read { db in try Board.fetchOne(db, key: id) }
                }

                let decrementResult = try database.decrementSharedCounter(
                    sourceTaskId: sourceTaskId, by: amount, boardId: currentBoardId
                )
                guard decrementResult.effectiveDelta > 0 else {
                    // No-op — source was already at 0; nothing to show.
                    await MainActor.run { self.setProcessing(false) }
                    return
                }

                if persistAsDefault {
                    do {
                        try database.setCounterDefaultLogAmount(sourceTaskId: sourceTaskId, amount: amount)
                    } catch {
                        dlog("BoardPlayVM: failed to persist counter default log amount: \(error)")
                    }
                }

                // Board-transition flash (F1): windowed completion is derived
                // per-board from the event log, NOT the source task's lifetime
                // latch — so removing a log can drop a completed square below its
                // goal on this window and flip the board COMPLETED → ACTIVE,
                // dropping bingo lines. The increment path already flashes the
                // mirror ACTIVE → COMPLETED case; without this the decrement
                // silently reactivated the board with no feedback. Only the
                // reactivated / lost-bingo rungs can fire on a decrement (never
                // greenlog / new bingos).
                let boardAfter: Board? = currentBoardId.flatMap { id in
                    try? database.read { db in try Board.fetchOne(db, key: id) }
                }
                let flash = BoardFlashOutcome.resolve(before: boardBefore, after: boardAfter, allowGains: false)

                let otherBoards = decrementResult.affectedBoards.filter { $0.boardId != currentBoardId }
                let creditPayload: SharedCounterCreditToastPayload? = otherBoards.isEmpty ? nil :
                    SharedCounterCreditToastPayload(
                        sourceTaskId: sourceTaskId,
                        amount: decrementResult.effectiveDelta,
                        unit: unit,
                        isIncrement: false,
                        message: Self.sharedCreditToastText(
                            counterName: counterName,
                            amount: decrementResult.effectiveDelta, kind: kind,
                            isIncrement: false
                        )
                    )

                await MainActor.run {
                    self.reload { self.setProcessing(false) }
                    self.emitFlash(flash, creditToast: creditPayload)
                }
            } catch {
                dlog("⚠️ BoardPlayView shared-counter decrement error: \(error)")
                await MainActor.run {
                    self.setProcessing(false)
                }
            }
        }
    }
}
