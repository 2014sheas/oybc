import SwiftUI

/// Where the Tasks tab's pool editor is pushed. `.edit` carries the pool id
/// (a `Hashable` route can't carry the `Pool` row); the destination loads it.
enum PoolEditorRoute: Hashable {
    case new
    case edit(poolId: String)
}

/// PoolEditorView — the full-screen pool editor (container). Mirrors the
/// board wizard's chrome (kicker + H2 title + X close, content, bottom
/// action bar) instead of the old modal sheet; the body is
/// `PoolEditorBodyView`. See docs/POOLS_RECURRING.md §Surfaces item 2.
///
/// Hosts: pushed on the Tasks tab `NavigationStack` (`PoolEditorRoute`), or in
/// a `fullScreenCover` + own `NavigationStack` from the pool picker's
/// "+ Build a new pool…".
///
/// **No board-related actions render here** (locked decision).
struct PoolEditorView: View {

    @State private var vm: PoolEditorViewModel
    /// Fired after a successful save (create or edit).
    let onSaved: () -> Void
    /// Fired after a successful delete.
    let onDeleted: () -> Void
    /// Fired when closed without saving (X).
    let onCancel: () -> Void
    /// Fired ONLY on a successful CREATE with the new `Pool` (the pool
    /// picker's auto-select round trip).
    var onCreated: ((Pool) -> Void)? = nil

    @State private var confirmingDelete = false

    init(
        pool: Pool?,
        templates: [RecurringBoardTemplate],
        library: TaskLibraryViewModel,
        userId: String,
        initialTaskIds: [String] = [],
        database: AppDatabase = .shared,
        onSaved: @escaping () -> Void,
        onDeleted: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onCreated: ((Pool) -> Void)? = nil
    ) {
        _vm = State(initialValue: PoolEditorViewModel(
            pool: pool, userId: userId, library: library, templates: templates,
            initialTaskIds: initialTaskIds, database: database
        ))
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        self.onCancel = onCancel
        self.onCreated = onCreated
    }

    var body: some View {
        ZStack(alignment: .top) {
            RisoPaperBackground()
            VStack(spacing: 0) {
                header
                ScrollView(showsIndicators: false) {
                    PoolEditorBodyView(vm: vm)
                        .padding(.horizontal, Riso.gutter).padding(.top, 14).padding(.bottom, 18)
                }
                footer
            }
        }
        .navigationBarHidden(true)
        .interactiveDismissDisabled(vm.busy)
        .onAppear {
            vm.library.loadLibrary(userId: vm.userId)
            vm.loadPickerInputs()
        }
    }

    // MARK: - Header (wizard chrome)

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.isEditMode ? "EDIT POOL" : "NEW POOL").risoKicker(.risoBlue)
                // "Pool" — the wizard's step-2 title for a repeating board; the
                // kicker above carries NEW / EDIT, so the title never repeats it.
                Text("Pool").risoH2()
            }
            Spacer()
            Button { onCancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 46, height: 46)
                    .risoCard(fill: .risoPaper2)
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small))
            .disabled(vm.busy)
            .accessibilityLabel("Close pool editor")
        }
        .padding(.horizontal, Riso.gutter).padding(.top, 16).padding(.bottom, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            RisoButton(title: vm.isEditMode ? "Save" : "Create pool", kind: .primary, fullWidth: true) {
                handleSave()
            }
            .opacity(vm.canSave ? 1 : 0.45)
            .disabled(!vm.canSave)

            if vm.isEditMode {
                if confirmingDelete {
                    deleteConfirmBlock
                } else {
                    Button { confirmingDelete = true } label: {
                        Text("Delete pool")
                            .font(.risoBody(14, .semibold)).foregroundStyle(Color.risoRed)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.busy)
                }
            }
        }
        .padding(.horizontal, Riso.gutter).padding(.top, 14).padding(.bottom, 20)
        .background(Color.risoPaper)
        .overlay(Rectangle().fill(Color.risoInk).frame(height: Riso.Keyline.dense), alignment: .top)
    }

    private var deleteConfirmBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete \"\(vm.pool?.name ?? "")\"? It detaches from any repeating boards and core defaults that draw from it — tasks are never deleted.")
                .font(.risoBody(13, .semibold)).foregroundStyle(Color.risoInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                RisoButton(title: "Cancel", kind: .neutral, small: true) { confirmingDelete = false }
                    .disabled(vm.busy)
                RisoButton(title: "Delete", kind: .primary, small: true) { handleDelete() }
                    .disabled(vm.busy)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper))
        .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoRed, lineWidth: Riso.Keyline.container))
    }

    // MARK: - Actions

    private func handleSave() {
        _Concurrency.Task {
            if case .saved(let created) = await vm.save() {
                if let created { onCreated?(created) }
                onSaved()
            }
        }
    }

    private func handleDelete() {
        _Concurrency.Task {
            if await vm.delete() { onDeleted() }
        }
    }
}
