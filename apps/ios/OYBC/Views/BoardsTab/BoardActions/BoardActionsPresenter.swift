import SwiftUI

/// The board title row's "…" menu targets (Board Edit redesign slice 2, D3 —
/// docs/BOARD_EDIT_REDESIGN.md). `.repeatBoard` (not `.repeat`, a Swift
/// keyword) mirrors `BoardMenuItem.repeatBoard`'s naming.
enum BoardAction: Equatable {
    case details
    case repeatBoard
    case coreDefaults
    case confirmArchive
    case confirmDelete
}

/// Attaches the three "…" menu sheets (Board details / Repeat this board /
/// Core defaults) and the two confirm alerts (Archive / Delete) to
/// `BoardPlayView`, keyed off one `activeAction` binding — so
/// `BoardPlayView` itself only needs `@State var boardAction:
/// BoardAction?` plus `.modifier(BoardActionsPresenter(...))` (Board Edit
/// redesign slice 2, T2). All 5 presentations are mutually exclusive
/// because only one enum value can be active at a time.
///
/// A board sealed/deleted mid-flight (D11) surfaces through the SAME
/// "Board closed" alert for both save-shaped actions (Board details,
/// Repeat) — the sheet's own `onSave` closure re-throws
/// `BoardEditError.boardNotEditable` after stashing the copy here so the
/// sheet still runs its own dismiss-on-error path.
struct BoardActionsPresenter: ViewModifier {
    @Binding var activeAction: BoardAction?
    /// The board the menu belongs to. Presentation content is a no-op
    /// while nil (mirrors the `if editMode, let b = board` gating the
    /// squares editor overlay uses) — the caller only shows the "…" menu
    /// itself once a board is loaded, so `activeAction` can't legitimately
    /// go non-nil first.
    let board: Board?
    /// The board's resolved source repeating record — see
    /// `BoardPlayViewModel.editSourceTemplate`.
    let sourceTemplate: RecurringBoardTemplate?
    let weekStartDay: String
    let userId: String
    @ObservedObject var viewModel: BoardPlayViewModel
    /// Fired after a successful Board details save (drives the "Board
    /// saved" toast — the same one the squares editor's Save uses).
    let onDetailsSaved: () -> Void
    /// Fired after a successful Archive or Delete. The caller decides what
    /// "removed" means (`board.isCore ? reload the pager : dismiss()`).
    let onRemoved: () -> Void

    @State private var boardClosedMessage: String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: detailsBinding) {
                if let board {
                    BoardDetailsSheetView(
                        board: board,
                        weekStartDay: weekStartDay,
                        hasCandidateTasksProvider: { await viewModel.hasCenterCandidate() },
                        onSave: { patch in
                            do {
                                try await viewModel.saveBoardDetails(patch)
                                onDetailsSaved()
                            } catch let error as BoardEditError where error == .boardNotEditable {
                                boardClosedMessage = BoardEditError.boardClosedMessage
                                throw error
                            }
                        },
                        onDismiss: { activeAction = nil }
                    )
                }
            }
            .sheet(isPresented: repeatBinding) {
                if let board {
                    BoardRepeatSheetView(
                        board: board,
                        sourceTemplate: sourceTemplate,
                        spawnNoteProvider: { await viewModel.loadSpawnNote() },
                        onSave: { intent in
                            do {
                                try await viewModel.saveRepeat(intent, weekStartDay: weekStartDay)
                            } catch let error as BoardEditError where error == .boardNotEditable {
                                boardClosedMessage = BoardEditError.boardClosedMessage
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
                Text("The board will be archived. Completed tasks and your record stay intact.")
            }
            .alert("Delete board?", isPresented: deleteBinding) {
                Button("Cancel", role: .cancel) { activeAction = nil }
                Button("Delete", role: .destructive) { runDelete() }
            } message: {
                Text("\"\(board?.name ?? "This board")\" will be removed. This can't be undone from the app.")
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

    // MARK: - Archive / Delete

    private func runArchive() {
        _Concurrency.Task { @MainActor in
            do {
                try await viewModel.archiveBoard()
                activeAction = nil
                onRemoved()
            } catch {
                activeAction = nil
                viewModel.bingoMessage = "Archive failed — please try again."
            }
        }
    }

    private func runDelete() {
        _Concurrency.Task { @MainActor in
            do {
                try await viewModel.deleteBoard()
                activeAction = nil
                onRemoved()
            } catch {
                activeAction = nil
                viewModel.bingoMessage = "Delete failed — please try again."
            }
        }
    }
}
