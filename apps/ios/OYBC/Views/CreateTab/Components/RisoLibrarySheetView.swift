import SwiftUI

/// Library bottom sheet for the Riso wizard Tasks step.
///
/// Dashed entry button → `.sheet` at `.fraction(0.76)` with grab handle,
/// gold "Done · N" pill, Riso search, `RisoChip` filter row, and rich
/// library rows (type letter badge, title, subtitle, usage, ＋/✓).
///
/// Wraps all existing wizard logic:
/// - Tap row = toggle add/remove (`toggleSelection`).
/// - Green left bar on added rows.
/// - Counting rows: "⇲ Derive smaller" → existing derive sheet.
/// - Compound rows: expand to add children.
/// - "From a board…" chip → existing `FromBoardPickerView` / `FromBoardGridView`.
/// - "From parent boards" chip (gated to timeframes that have parents).
struct RisoLibrarySheetView: View {

    // MARK: - Injected state from the Tasks step

    let library: TaskLibraryViewModel
    let selectedTaskIds: Set<String>
    let taskBoardCounts: [String: Int]
    let effectiveAllTasks: [Task]
    let effectiveChildrenByCompound: [String: [CompoundChild]]
    let effectiveTaskById: [String: OYBC.Task]
    let hasParentBoards: Bool
    let currentTimeframe: Timeframe

    let userId: String
    let defaultStartDate: String?
    let defaultEndDate: String?
    let onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)?
    let onLibraryReloadRequested: () -> Void

    let onToggle: (_ taskId: String) -> Void
    let onTaskCreated: (_ taskId: String, _ title: String, _ type: String) -> Void

    // From-a-board pass-through
    let sourceBoardsVM: SourceBoardsViewModel
    var pickedSourceBoardId: Binding<String?>
    var copiedTaskIds: Set<String>
    let onCopyTask: (OYBC.Task) -> Void
    let onOpenInLibrary: (String) -> Void

    // MARK: - Internal state

    @State private var isSheetOpen: Bool = false
    @State private var searchQuery: String = ""
    @State private var activeFilter: LibraryFilter = .all
    @State private var expandedCompoundId: String? = nil

    // Derive-smaller sheet state
    @State private var derivingFromTask: OYBC.Task? = nil
    @State private var deriveMaxCountInput: String = ""

    // Parent-board tasks
    @State private var parentTasksVM = ParentBoardTasksViewModel()
    @State private var parentTasksLoaded = false

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(_ title: String) -> Bool {
        trimmedQuery.isEmpty || title.lowercased().contains(trimmedQuery)
    }

    // MARK: - Entry button

    var body: some View {
        VStack(spacing: 0) {
            entryButton
        }
        .sheet(isPresented: $isSheetOpen) {
            librarySheet
        }
        // Derive sheet — presented from here so it layers above the library sheet
        .sheet(item: derivePickerItemBinding) { _ in
            deriveCounterSheet
        }
    }

    private var entryButton: some View {
        Button {
            if hasParentBoards && !parentTasksLoaded {
                parentTasksVM.reloadAsync(userId: userId, childTimeframe: currentTimeframe)
                parentTasksLoaded = true
            }
            isSheetOpen = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
                Text("Add from your library")
                    .font(.risoHead(13, .bold))
                    .foregroundStyle(Color.risoInk)
                Spacer(minLength: 4)
                // Library count badge
                Text("\(effectiveAllTasks.count)")
                    .font(.risoHead(10, .extraBold))
                    .foregroundStyle(Color.risoPaper)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.risoInk))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [5, 4]))
                    .foregroundStyle(Color.risoInk)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sheet content

    private var librarySheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.risoMuted)
                    TextField("Search your library…", text: $searchQuery)
                        .font(.risoHead(15, .bold))
                        .foregroundStyle(Color.risoInk)
                        .tint(Color.risoBlue)
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.risoMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.risoPaper2)
                .overlay(
                    Rectangle()
                        .fill(Color.risoInk)
                        .frame(height: Riso.Keyline.container),
                    alignment: .bottom
                )

                // Filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(visibleFilters, id: \.self) { filter in
                            RisoChip(title: filter.rawValue, isOn: activeFilter == filter) {
                                activeFilter = filter
                                if filter != .fromBoard {
                                    pickedSourceBoardId.wrappedValue = nil
                                }
                                expandedCompoundId = nil
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(Color.risoPaper)
                .overlay(
                    Rectangle()
                        .fill(Color.risoInk.opacity(0.12))
                        .frame(height: 1),
                    alignment: .bottom
                )

                // Library list
                ScrollView {
                    LazyVStack(spacing: 7) {
                        if activeFilter == .fromBoard {
                            fromBoardSection
                        } else {
                            let rows = filteredRows
                            if rows.isEmpty {
                                emptyState
                            } else {
                                ForEach(rows, id: \.id) { task in
                                    libraryRow(task)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .background(Color.risoPaper)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Your library")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Gold "Done · N" pill
                    let addedCount = selectedTaskIds.count
                    RisoToolbarPill(title: addedCount > 0 ? "Done · \(addedCount)" : "Done") {
                        isSheetOpen = false
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.76)])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Filter list

    private var visibleFilters: [LibraryFilter] {
        var filters: [LibraryFilter] = [.all, .normal, .counting, .compound]
        if hasParentBoards { filters.append(.fromParents) }
        filters.append(.fromBoard)
        return filters
    }

    private var filteredRows: [Task] {
        let source: [Task]
        switch activeFilter {
        case .all:
            source = effectiveAllTasks.filter { !library.childTaskIds.contains($0.id) || $0.type == .compound }
        case .normal:
            source = effectiveAllTasks.filter { $0.type == .normal && !library.childTaskIds.contains($0.id) }
        case .counting:
            source = effectiveAllTasks.filter { $0.type == .counting && !library.childTaskIds.contains($0.id) }
        case .compound:
            source = effectiveAllTasks.filter { $0.type == .compound }
        case .fromParents:
            source = parentTasksVM.tasks
        case .fromBoard:
            return []
        }
        // Exclude expired tasks — one whose timebox window has already passed
        // can't meaningfully be added to a new board's pool (mirrors the
        // Tasks-tab default of hiding expired). Non-timeboxed tasks are never
        // expired (isTaskExpired returns false when endDate is nil).
        return source.filter { matches($0.title) && !TasksTabViewModel.isTaskExpired($0) }
    }

    // MARK: - Library row

    @ViewBuilder
    private func libraryRow(_ task: Task) -> some View {
        let isAdded = selectedTaskIds.contains(task.id)
        let isExpanded = expandedCompoundId == task.id
        let isCompound = task.type == .compound
        let subtitle = buildSubtitle(task)
        let boardCount = taskBoardCounts[task.id] ?? 0
        let usageText = boardCount == 0 ? "0 bds" : "\(boardCount) bd\(boardCount == 1 ? "" : "s")"

        VStack(spacing: 0) {
            // Main row tap area
            Button {
                if !isCompound {
                    onToggle(task.id)
                } else {
                    expandedCompoundId = isExpanded ? nil : task.id
                }
            } label: {
                HStack(spacing: 9) {
                    // Green left bar when added
                    Rectangle()
                        .fill(isAdded ? Color.risoGreen : Color.clear)
                        .frame(width: 4)

                    // Type badge
                    RisoTypeBadge(kind: risoKind(for: task.type), style: .letterSquare)

                    // Title + subtitle
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.risoHead(13.5, .bold))
                            .foregroundStyle(Color.risoInk)
                            .lineLimit(1)
                        if let sub = subtitle {
                            Text(sub)
                                .font(.risoBody(10.5, .semibold))
                                .foregroundStyle(Color.risoMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)

                    // Usage count
                    Text(usageText)
                        .font(.risoHead(10, .extraBold))
                        .foregroundStyle(Color.risoMuted)

                    // State indicator
                    if isCompound {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.risoMuted)
                            .frame(width: 18)
                    } else {
                        Text(isAdded ? "✓" : "＋")
                            .font(.risoHead(14, .extraBold))
                            .foregroundStyle(isAdded ? Color.risoGreen : Color.risoBlue)
                            .frame(width: 18)
                    }
                }
                .padding(.vertical, 9)
                .padding(.trailing, 11)
                .background(isAdded ? Color.risoPaper : Color.risoPaper2)
            }
            .buttonStyle(.plain)

            // Compound children (expanded)
            if isCompound && isExpanded {
                compoundChildrenSection(task)
            }

            // Counting row actions (derive smaller)
            if task.type == .counting, task.action != nil, task.unit != nil, task.maxCount != nil {
                HStack {
                    Button("⇲ Derive smaller") {
                        derivingFromTask = task
                        deriveMaxCountInput = ""
                    }
                    .font(.risoHead(11, .bold))
                    .foregroundStyle(Color.risoBlue)
                    .padding(.leading, 13)
                    .padding(.bottom, 8)
                    Spacer()
                }
            }
        }
        .background(isAdded ? Color.risoPaper : Color.risoPaper2)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
        )
    }

    @ViewBuilder
    private func compoundChildrenSection(_ compound: Task) -> some View {
        let children = effectiveChildrenByCompound[compound.id] ?? []
        let taskById = effectiveTaskById
        VStack(spacing: 6) {
            if children.isEmpty {
                Text("No sub-tasks.")
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Scrollable chip row of children
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(children, id: \.id) { child in
                            if let childTask = taskById[child.childTaskId] {
                                let childAdded = selectedTaskIds.contains(childTask.id)
                                Button {
                                    if !childAdded { onToggle(childTask.id) }
                                } label: {
                                    HStack(spacing: 5) {
                                        Text(childTask.title)
                                            .font(.risoHead(11, .bold))
                                            .foregroundStyle(childAdded ? Color.risoGreen : Color.risoInk)
                                        Text(childAdded ? "✓" : "＋")
                                            .font(.risoHead(11, .extraBold))
                                            .foregroundStyle(childAdded ? Color.risoGreen : Color.risoBlue)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.risoPaper))
                                    .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                                    .opacity(childAdded ? 0.5 : 1)
                                }
                                .buttonStyle(.plain)
                                .disabled(childAdded)
                            }
                        }
                    }
                    .padding(.horizontal, 13)
                }

                Text("Sub-tasks are real tasks — add one on its own.")
                    .font(.risoBody(9.5, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 8)
            }
        }
        .padding(.top, 6)
        .overlay(
            Rectangle()
                .fill(Color.risoInk)
                .frame(height: Riso.Keyline.dense),
            alignment: .top
        )
    }

    // MARK: - From a board section

    @ViewBuilder
    private var fromBoardSection: some View {
        if let boardId = pickedSourceBoardId.wrappedValue,
           let sourceBoard = sourceBoardsVM.eligibleBoards.first(where: { $0.id == boardId }) {
            // Grid view (from existing component)
            FromBoardGridView(
                vm: sourceBoardsVM,
                sourceBoard: sourceBoard,
                userId: userId,
                selectedTaskIds: selectedTaskIds,
                copiedTaskIds: copiedTaskIds,
                onToggleSelection: { taskId in onToggle(taskId) },
                onCopyTask: { task in onCopyTask(task) },
                onAddAllSubtasks: { _, leafIds in
                    for id in leafIds where !selectedTaskIds.contains(id) { onToggle(id) }
                },
                onOpenInLibrary: { id in onOpenInLibrary(id) },
                onChangeSource: { pickedSourceBoardId.wrappedValue = nil },
                onTaskCreated: { task in
                    if !selectedTaskIds.contains(task.id) { onToggle(task.id) }
                }
            )
        } else {
            FromBoardPickerView(
                vm: sourceBoardsVM,
                userId: userId,
                onPickBoard: { boardId in pickedSourceBoardId.wrappedValue = boardId }
            )
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            if !trimmedQuery.isEmpty {
                Text("No tasks match \"\(searchQuery)\".")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
            } else if activeFilter == .fromParents {
                Text("No parent boards found.")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
            } else {
                Text("Your library is empty.")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
                Text("Create tasks from the special-type panel above to build your library.")
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Derive smaller sheet

    private var derivePickerItemBinding: Binding<DeriveCounterPayload?> {
        Binding(
            get: { derivingFromTask.map { DeriveCounterPayload(task: $0) } },
            set: { if $0 == nil { derivingFromTask = nil } }
        )
    }

    private struct DeriveCounterPayload: Identifiable {
        let task: OYBC.Task
        var id: String { task.id }
    }

    @ViewBuilder
    private var deriveCounterSheet: some View {
        if let source = derivingFromTask {
            NavigationStack {
                Form {
                    Section("Derived from") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.title)
                                .font(.headline)
                            if let action = source.action, let unit = source.unit, let max = source.maxCount {
                                Text("\(action) \(max) \(unit)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Section("New target") {
                        TextField("Goal", text: $deriveMaxCountInput)
                            .keyboardType(.numberPad)
                        if let action = source.action, let unit = source.unit,
                           let parsed = Int(deriveMaxCountInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                           parsed > 0 {
                            Text("Title: \(action) \(parsed) \(unit)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle("Derive smaller version")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { derivingFromTask = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveDerivedCounter(source: source) }
                            .disabled(!isDeriveInputValid(source: source))
                    }
                }
            }
        }
    }

    private func isDeriveInputValid(source: OYBC.Task) -> Bool {
        guard source.action != nil, source.unit != nil, source.maxCount != nil else { return false }
        guard let parsed = Int(deriveMaxCountInput.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return parsed > 0
    }

    // TODO(riso 3b-follow-up): Shared-counter-linked derive — currently creates a
    // standalone derived counter. The full linked path (↔ source, shared counters
    // Phase 4) is deferred. Keep current standalone behavior.
    private func saveDerivedCounter(source: OYBC.Task) {
        guard let action = source.action,
              let unit = source.unit,
              let parsed = Int(deriveMaxCountInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0
        else { return }

        let now = AppDatabase.currentTimestamp()
        let newId = AppDatabase.generateUUID()
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = "\(trimmedAction) \(parsed) \(trimmedUnit)"

        let newTask = OYBC.Task(
            id: newId,
            userId: userId,
            title: title,
            description: nil,
            type: .counting,
            action: trimmedAction,
            unit: trimmedUnit,
            maxCount: parsed,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false
        )

        derivingFromTask = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.write { db in
                    try newTask.save(db)
                    try SyncQueueBuilder.makeItem(
                        entityType: "tasks",
                        entityId: newId,
                        operationType: .create,
                        payload: newTask,
                        now: now
                    ).save(db)
                }
                DispatchQueue.main.async {
                    onTaskCreated(newId, title, "counting")
                    onLibraryReloadRequested()
                }
            } catch {
                // Swallow on background; user can retry.
            }
        }
    }

    // MARK: - Helpers

    private func risoKind(for type: TaskType) -> RisoTaskKind {
        switch type {
        case .normal: return .normal
        case .counting: return .counting
        case .compound: return .compound
        case .achievement: return .achievement
        }
    }

    private func buildSubtitle(_ task: Task) -> String? {
        switch task.type {
        case .counting:
            guard let a = task.action, let u = task.unit, let m = task.maxCount,
                  !a.isEmpty, !u.isEmpty else { return nil }
            return "\(a) · goal \(m) \(u)"
        case .compound:
            let n = effectiveChildrenByCompound[task.id]?.count ?? 0
            guard n > 0 else { return nil }
            if task.isOrdered == true {
                return "\(n) step\(n == 1 ? "" : "s") · in order"
            }
            let op = task.operatorType
            switch op {
            case .or: return "Any of \(n)"
            case .mOfN:
                let t = task.threshold ?? n
                return "≥\(t) of \(n)"
            default: return "All of \(n)"
            }
        default:
            return nil
        }
    }
}
