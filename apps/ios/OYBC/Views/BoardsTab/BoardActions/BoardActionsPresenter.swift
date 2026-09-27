import SwiftUI

/// The Edit screen's BOARD-section targets (Board Edit redesign slice 2, D3,
/// now routed from `BoardOptionsSectionView` rows instead of a "…" popover —
/// docs/BOARD_EDIT_REDESIGN.md). `.repeatBoard` (not `.repeat`, a Swift
/// keyword) mirrors `BoardMenuItem.repeatBoard`'s naming.
enum BoardAction: Equatable {
    case details
    case repeatBoard
    case coreDefaults
    case confirmArchive
    case confirmDelete
    /// Board Edit redesign slice 4 (D3, OQ7): Close has no confirm — Reopen
    /// reverses it.
    case close
    /// Board Edit redesign slice 4 (D6): Reopen confirms via `.alert`
    /// (verbatim copy in the presenter body below).
    case confirmReopen
    /// Board Edit consolidation (D8, `discardFirst`) — only reachable via
    /// the D3 race (squares were editable at Edit entry, then the board
    /// ended/sealed mid-session): a dirty-draft "Discard changes?" confirm
    /// that, on Discard, re-routes to `then` (`.close`'s own no-confirm path
    /// or `.confirmReopen`'s own confirm).
    case confirmDiscard(then: BoardMenuItem)
}

/// Attaches the three BOARD-section sheets (Board details / Repeat this
/// board / Core defaults) and the confirm alerts (Archive / Delete / Reopen /
/// discard-first) to `BoardPlayView`, keyed off one `activeAction` binding —
/// so `BoardPlayView` itself only needs `@State var boardAction:
/// BoardAction?` plus `.modifier(BoardActionsPresenter(...))` (Board Edit
/// redesign slice 2, T2). All presentations are mutually exclusive because
/// only one enum value can be active at a time.
///
/// A board sealed/deleted mid-flight (D11) surfaces through the SAME
/// "Board closed" alert for both save-shaped actions (Board details,
/// Repeat) — the sheet's own `onSave` closure re-throws
/// `BoardEditError.boardNotEditable` after flagging `pendingBoardClosed`,
/// so the sheet still runs its own dismiss-on-error path. The alert is
/// raised from the sheet's `onDismiss`, never while the sheet is still up:
/// SwiftUI can't present an alert from a view that is already presenting a
/// sheet, so setting it mid-sheet could silently drop it.
struct BoardActionsPresenter: ViewModifier {
    @Binding var activeAction: BoardAction?
    /// The board the menu belongs to. Presentation content is a no-op
    /// while nil (mirrors the `if editMode, let b = board` gating the
    /// squares editor overlay uses) — the caller only shows the Edit screen's
    /// BOARD section once a board is loaded, so `activeAction` can't legitimately
    /// go non-nil first.
    let board: Board?
    /// The board's resolved source repeating record — see
    /// `BoardPlayViewModel.editSourceTemplate`.
    let sourceTemplate: RecurringBoardTemplate?
    let weekStartDay: String
    let userId: String
    @ObservedObject var viewModel: BoardPlayViewModel
    /// Board Edit consolidation (D8) — whether the squares draft is dirty,
    /// pinned by the caller from `viewModel.editSquaresEditCount > 0`.
    /// Appended to the Archive/Delete confirm body (`discardInConfirm`) and
    /// gates the `discardFirst` confirm for Close/Reopen.
    let squaresDirty: Bool
    /// Board Edit redesign slice 4: Close/Reopen reconcile local notifications
    /// afterward (a closed board's expiry reminder should stop firing; a
    /// reopened one shouldn't re-add one either, since it's past `endDate`).
    @EnvironmentObject var notificationService: NotificationService
    /// Fired after a successful Board details or Repeat save (drives the
    /// "Board saved" toast — the same one the squares editor's Save uses;
    /// web's `BoardTitleActions` fires its toast for both too).
    let onDetailsSaved: () -> Void
    /// Board Edit consolidation (D9) — fired after a successful Close or
    /// Reopen (returns the caller to the play surface, whose CLOSED/ENDED
    /// pill flip IS the feedback) and before `onRemoved` on a successful
    /// Archive or Delete (both leave the screen).
    let onExitEdit: () -> Void
    /// Fired after a successful Archive or Delete. The caller decides what
    /// "removed" means (`board.isCore ? reload the pager : dismiss()`).
    let onRemoved: () -> Void

    @State private var boardClosedMessage: String?
    /// Set by a save-shaped sheet that hit a closed board; promoted to
    /// `boardClosedMessage` once that sheet has finished dismissing.
    @State private var pendingBoardClosed = false
    /// Board Edit consolidation — Close/Reopen/Archive/Delete failure alert
    /// (replaces the old `viewModel.bingoMessage` writes, which rendered
    /// nowhere for these strings). Web parity: `BoardTitleActions`'s
    /// per-action `notice`.
    @State private var actionFailure: (title: String, message: String)?

    /// Sheet `onDismiss`: raise the deferred "Board closed" alert, if any.
    private func presentPendingBoardClosed() {
        guard pendingBoardClosed else { return }
        pendingBoardClosed = false
        boardClosedMessage = BoardEditError.boardClosedMessage
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: detailsBinding, onDismiss: presentPendingBoardClosed) {
                if let board {
                    BoardDetailsSheetView(
                        board: board,
                        weekStartDay: weekStartDay,
                        onSave: { patch in
                            do {
                                try await viewModel.saveBoardDetails(patch)
                                onDetailsSaved()
                            } catch let error as BoardEditError where error == .boardNotEditable {
                                pendingBoardClosed = true
                                throw error
                            }
                        },
                        onDismiss: { activeAction = nil }
                    )
                }
            }
            .sheet(isPresented: repeatBinding, onDismiss: presentPendingBoardClosed) {
                if let board {
                    BoardRepeatSheetView(
                        board: board,
                        sourceTemplate: sourceTemplate,
                        spawnNoteProvider: { await viewModel.loadSpawnNote() },
                        onSave: { intent in
                            do {
                                try await viewModel.saveRepeat(intent, weekStartDay: weekStartDay)
                                onDetailsSaved()
                            } catch let error as BoardEditError where error == .boardNotEditable {
                                pendingBoardClosed = true
                                throw error
                            }
                        },
                        onDismiss: { activeAction = nil }
                    )
                }
            }
            .sheet(isPresented: coreDefaultsBinding) {
                CoreDefaultsSheetHost(
                    timeframe: board?.timeframe ?? .monthly,
                    userId: userId,
                    onSaved: { activeAction = nil }
                )
            }
            .alert("Archive this board?", isPresented: archiveBinding) {
                Button("Cancel", role: .cancel) { activeAction = nil }
                Button("Archive", role: .destructive) { runArchive() }
            } message: {
                Text(archiveMessage)
            }
            .alert("Delete board?", isPresented: deleteBinding) {
                Button("Cancel", role: .cancel) { activeAction = nil }
                Button("Delete", role: .destructive) { runDelete() }
            } message: {
                Text(deleteMessage)
            }
            .alert(
                "Board closed",
                isPresented: Binding(
                    get: { boardClosedMessage != nil },
                    set: { if !$0 { boardClosedMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { boardClosedMessage = nil }
            } message: {
                Text(boardClosedMessage ?? "")
            }
            // Board Edit redesign slice 4, D3/OQ7: Close has no confirm
            // (Reopen reverses it) — fire the moment the menu routes here.
            .onChange(of: activeAction) { _, action in
                if action == .close { runClose() }
            }
            .alert("Reopen this board?", isPresented: reopenBinding) {
                Button("Cancel", role: .cancel) { activeAction = nil }
                Button("Reopen") { runReopen() }
            } message: {
                Text("It accepts logs again until you close it. Streaks and achievements that watch it will recompute.")
            }
            // Board Edit consolidation (D8, discardFirst) — only reachable
            // via the D3 race: squares were editable at Edit entry, the
            // board ended/sealed mid-session, and the user then tapped the
            // now-offered Close/Reopen row with a dirty draft.
            .alert("Discard changes?", isPresented: discardBinding) {
                Button("Keep editing", role: .cancel) { activeAction = nil }
                Button("Discard", role: .destructive) { runDiscardThenRoute() }
            } message: {
                Text("Your unsaved changes will be lost.")
            }
            // Board Edit consolidation — Close/Reopen/Archive/Delete failure
            // (web parity: BoardTitleActions's per-action notice).
            .alert(
                actionFailure?.title ?? "",
                isPresented: Binding(
                    get: { actionFailure != nil },
                    set: { if !$0 { actionFailure = nil } }
                )
            ) {
                Button("OK", role: .cancel) { actionFailure = nil }
            } message: {
                Text(actionFailure?.message ?? "")
            }
    }

    // MARK: - Archive / Delete confirm copy (D8, discardInConfirm)

    private var archiveMessage: String {
        let base = "The board will be archived. Completed tasks and your record stay intact."
        return squaresDirty ? base + BoardMenuItems.discardSquaresSuffix : base
    }

    private var deleteMessage: String {
        let base = "\"\(board?.name ?? "This board")\" will be removed. This can't be undone from the app."
        return squaresDirty ? base + BoardMenuItems.discardSquaresSuffix : base
    }

    // MARK: - Per-case bindings

    private var detailsBinding: Binding<Bool> {
        Binding(get: { activeAction == .details }, set: { if !$0 { activeAction = nil } })
    }
    private var repeatBinding: Binding<Bool> {
        Binding(get: { activeAction == .repeatBoard }, set: { if !$0 { activeAction = nil } })
    }
    private var coreDefaultsBinding: Binding<Bool> {
        Binding(get: { activeAction == .coreDefaults }, set: { if !$0 { activeAction = nil } })
    }
    private var archiveBinding: Binding<Bool> {
        Binding(get: { activeAction == .confirmArchive }, set: { if !$0 { activeAction = nil } })
    }
    private var deleteBinding: Binding<Bool> {
        Binding(get: { activeAction == .confirmDelete }, set: { if !$0 { activeAction = nil } })
    }
    private var reopenBinding: Binding<Bool> {
        Binding(get: { activeAction == .confirmReopen }, set: { if !$0 { activeAction = nil } })
    }
    private var discardBinding: Binding<Bool> {
        Binding(
            get: { if case .confirmDiscard = activeAction { return true } else { return false } },
            set: { if !$0 { activeAction = nil } }
        )
    }

    /// D8, discardFirst — Discard proceeds to `then`'s own path: `.close`
    /// fires immediately (no confirm, via the `.onChange` above), `.reopen`
    /// re-enters its own "Reopen this board?" confirm.
    private func runDiscardThenRoute() {
        guard case .confirmDiscard(let then) = activeAction else { return }
        activeAction = (then == .close) ? .close : .confirmReopen
    }

    // MARK: - Archive / Delete

    private func runArchive() {
        _Concurrency.Task { @MainActor in
            do {
                try await viewModel.archiveBoard()
                activeAction = nil
                onExitEdit()
                onRemoved()
            } catch {
                activeAction = nil
                actionFailure = ("Archive failed", "Archive failed — please try again.")
            }
        }
    }

    private func runDelete() {
        _Concurrency.Task { @MainActor in
            do {
                try await viewModel.deleteBoard()
                activeAction = nil
                onExitEdit()
                onRemoved()
            } catch {
                activeAction = nil
                actionFailure = ("Delete failed", "Delete failed — please try again.")
            }
        }
    }

    // MARK: - Close / Reopen (Board Edit redesign slice 4)

    private func runClose() {
        _Concurrency.Task { @MainActor in
            do {
                try await viewModel.closeBoard()
                await reconcileNotifications()
                onExitEdit()
            } catch {
                actionFailure = ("Close failed", "Close failed — please try again.")
            }
            activeAction = nil
        }
    }

    private func runReopen() {
        _Concurrency.Task { @MainActor in
            do {
                try await viewModel.reopenBoard()
                await reconcileNotifications()
                onExitEdit()
            } catch {
                actionFailure = ("Reopen failed", "Reopen failed — please try again.")
            }
            activeAction = nil
        }
    }

    /// Both Close and Reopen change a board's `endDate`/`sealedAt`-derived
    /// notification eligibility (an expiry reminder should stop once closed;
    /// a reopened board is already past its `endDate` so the planner emits
    /// none either way) — reconcile so the OS-scheduled set stays honest.
    private func reconcileNotifications() async {
        guard let uid = userId.isEmpty ? nil : userId else { return }
        await notificationService.reconcile(userId: uid)
    }
}
