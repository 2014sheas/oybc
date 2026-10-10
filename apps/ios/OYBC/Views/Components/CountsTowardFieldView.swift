import SwiftUI

/// What a task editor / create form has chosen for "Counts toward": the
/// counter (`nil` = None) and the per-completion amount.
struct CountsTowardSelection: Equatable {
    var counterId: String?
    var amount: Int = 1
}

/// The "Counts toward" row (docs/SHARED_COUNTER_SETTINGS.md §3, PR 4): a value
/// button naming the counter (or "None") that toggles an inline counter picker,
/// plus — once a counter is chosen — the per-completion amount stepper.
/// Shared by the global task editor, the Board Edit square sheet and the create
/// sheet. Web twin: `components/countsToward/CountsTowardField.tsx`.
struct CountsTowardFieldView: View {
    /// Every live task of the user (candidates and counter names resolve from it).
    let tasks: [Task]
    /// The task being edited / created (excluded from the candidates); nil while creating.
    var editedTaskId: String?
    /// The counter the STORED row counts toward — picking a different one asks first.
    var storedCounterId: String?
    @Binding var selection: CountsTowardSelection
    /// Snapshot seams: opens the picker (optionally pre-typed).
    var initiallyOpen: Bool = false
    var initialQuery: String = ""

    @State private var isOpen = false
    @State private var query = ""
    @State private var pendingSwitch: Task?
    @State private var seeded = false

    // MARK: - Pure rules

    /// The counters a task may count toward: Discrete shared counter roots,
    /// other than the edited task itself, ordered by display name.
    static func candidates(tasks: [Task], editedTaskId: String?) -> [Task] {
        tasks
            .filter { CountsToward.isTarget($0) && CountsToward.isSharedCounterRoot($0, tasks: tasks) && $0.id != editedTaskId }
            .sorted { CounterSettings.counterDisplayName($0).localizedCaseInsensitiveCompare(CounterSettings.counterDisplayName($1)) == .orderedAscending }
    }

    /// Whether the row shows for `task`: absent for an Achievement (stored or
    /// being switched to), a linked copy, and a shared counter itself.
    static func isVisible(task: Task, selectedType: TaskType, tasks: [Task]) -> Bool {
        task.type != .achievement && selectedType != .achievement && task.sharedCounterId == nil
            && !CountsToward.isSharedCounterRoot(task, tasks: tasks)
    }

    /// Whether a CREATE form shows the row: a host that supplied the user's
    /// tasks, an immediate (never deferred / pending) create, and at least one
    /// counter to pick.
    static func showsOnCreate(tasks: [Task]?, deferred: Bool) -> Bool {
        guard let tasks, !deferred else { return false }
        return !candidates(tasks: tasks, editedTaskId: nil).isEmpty
    }

    /// The patch a sheet submits for `selection`: nil unless it differs from
    /// the stored row (`stored*` = what the row counts toward now).
    static func patch(selection: CountsTowardSelection, storedCounterId: String?, storedAmount: Int?) -> CountsTowardPatch? {
        let amount = selection.counterId == nil ? nil : selection.amount
        let storedNormalized = storedCounterId == nil ? nil : (storedAmount ?? 1)
        if selection.counterId == storedCounterId && amount == storedNormalized { return nil }
        return CountsTowardPatch(counterId: selection.counterId, amount: amount)
    }

    /// The selection a row opens with.
    static func selection(counterId: String?, amount: Int?) -> CountsTowardSelection {
        CountsTowardSelection(counterId: counterId, amount: max(1, amount ?? 1))
    }

    private var candidates: [Task] { Self.candidates(tasks: tasks, editedTaskId: editedTaskId) }

    private var matches: [Task] {
        candidates.filter { CounterPlacement.taskSearchMatches(query, task: $0) }
    }

    private var selectedName: String? {
        selection.counterId.flatMap { id in tasks.first { $0.id == id } }.map(CounterSettings.counterDisplayName)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Counts toward").risoSectionLabel()
            HStack(spacing: 8) {
                valueButton
                if selection.counterId != nil { amountStepper }
            }
            if isOpen { picker }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            isOpen = initiallyOpen
            query = initialQuery
        }
        .alert(
            "Switch to \(pendingSwitch.map(CounterSettings.counterDisplayName) ?? "")?",
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } })
        ) {
            Button("Switch") {
                if let next = pendingSwitch { apply(next.id) }
                pendingSwitch = nil
            }
            Button("Cancel", role: .cancel) { pendingSwitch = nil }
        } message: {
            Text("Earlier credits on \(storedName) are withdrawn.")
        }
    }

    private var storedName: String {
        storedCounterId.flatMap { id in tasks.first { $0.id == id } }.map(CounterSettings.counterDisplayName) ?? ""
    }

    private var valueButton: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 8) {
                if let name = selectedName {
                    twoDots
                    Text(name)
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)
                } else {
                    Text("None")
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Counts toward, \(selectedName ?? "None")")
    }

    private var twoDots: some View {
        VStack(spacing: 2) {
            Circle().fill(Color.risoBlue).frame(width: 4, height: 4)
            Circle().fill(Color.risoBlue).frame(width: 4, height: 4)
        }
        .accessibilityHidden(true)
    }

    private var amountStepper: some View {
        HStack(spacing: 0) {
            stepButton("\u{2212}", label: "Decrease amount") { selection.amount = max(1, selection.amount - 1) }
            Text("\(selection.amount)")
                .font(.risoHead(14, .extraBold))
                .foregroundStyle(Color.risoInk)
                .frame(minWidth: 24)
                .multilineTextAlignment(.center)
            stepButton("+", label: "Increase amount") { selection.amount += 1 }
        }
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
        )
        .accessibilityElement(children: .contain)
    }

    private func stepButton(_ glyph: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.risoHead(16, .extraBold))
                .foregroundStyle(Color.risoMuted)
                .frame(width: 34, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Picker

    private var picker: some View {
        VStack(spacing: 0) {
            TextField("Search counters", text: $query)
                .font(.risoHead(14, .bold))
                .foregroundStyle(Color.risoInk)
                .tint(Color.risoBlue)
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .background(Color.risoPaper2)
            pickerRow(isNone: true, task: nil)
            ForEach(matches) { task in pickerRow(isNone: false, task: task) }
        }
        .background(Color.risoPaper)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
    }

    private func pickerRow(isNone: Bool, task: Task?) -> some View {
        let selected = isNone ? selection.counterId == nil : selection.counterId == task?.id
        return Button {
            if let task { choose(task) } else { selection = CountsTowardSelection(counterId: nil, amount: 1); isOpen = false }
        } label: {
            HStack(spacing: 10) {
                if let task {
                    let kind = resolveCountKind(task.countKind)
                    RisoTypeBadge(kind: .counting, style: .letterSquare)
                    Text(CounterSettings.counterDisplayName(task))
                        .font(.risoBody(13.5, .semibold))
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)
                    KindTagView(kind: kind, dense: true)
                    Spacer(minLength: 0)
                    Text("\(formatCount(task.currentCount ?? 0, kind: kind)) all-time")
                        .font(.risoBody(12, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                } else {
                    Text("None")
                        .font(.risoBody(13.5, .semibold))
                        .foregroundStyle(Color.risoMuted)
                    Spacer(minLength: 0)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.risoBlue)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(Color.risoInk.opacity(0.12)).frame(height: 1) }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func choose(_ counter: Task) {
        if let stored = storedCounterId, stored != counter.id {
            pendingSwitch = counter
        } else {
            apply(counter.id)
        }
    }

    private func apply(_ counterId: String) {
        selection.counterId = counterId
        isOpen = false
    }
}
