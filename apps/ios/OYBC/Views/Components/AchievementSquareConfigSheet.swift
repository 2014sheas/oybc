import SwiftUI

/// Phase 6.3 — Achievement-Square Config Sheet (iOS)
///
/// SwiftUI twin of `apps/web/src/components/achievementSquare/AchievementSquareConfigModal.tsx`.
/// Lets the user convert a regular task cell into an achievement square
/// (or revert it back). When the achievement-square toggle is ON, the
/// user picks one of three modes:
///
/// - **Count across timeframe** (aggregate; pre-6.3 behavior) — driven
///   by an external progress counter; the sheet lets the user set the
///   target count + timeframe + type (bingo vs full completion).
/// - **Watch a specific board** — `referencedBoardId` mode. Completes
///   when the referenced board greenlogs.
/// - **Watch a recurring template** — `referencedTemplateId` mode.
///   Completes when ALL in-window non-deleted spawns greenlog. Empty
///   window ⇒ incomplete (NOT vacuously true) — surfaced as a warning.
///
/// Mutual exclusion + cycle detection at Save. Cycle errors surface
/// inline with the `cyclePath` so the user knows which boards form the
/// loop. The actual write is delegated to `onSave(patch:)` so the
/// parent owns persistence (matches the web pattern).
struct AchievementSquareConfigSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case aggregate
        case specificBoard
        case recurringTemplate
        var id: String { rawValue }

        var title: String {
            switch self {
            case .aggregate: return "Count across timeframe"
            case .specificBoard: return "Watch a specific board"
            case .recurringTemplate: return "Watch a recurring template"
            }
        }

        var description: String {
            switch self {
            case .aggregate:
                return "Completes after N boards of the chosen timeframe meet the chosen condition."
            case .specificBoard:
                return "Completes when one named board greenlogs."
            case .recurringTemplate:
                return "Completes when every spawn of the template that falls inside this board's window greenlogs."
            }
        }
    }

    /// Patch shape mirroring TS `AchievementSquareConfigPatch`. The
    /// parent decides whether to persist via GRDB write.
    struct ConfigPatch: Equatable {
        var isAchievementSquare: Bool
        var achievementType: AchievementType?
        var achievementCount: Int?
        var achievementTimeframe: Timeframe?
        /// `nil` means "clear this field" (mirrors the TS `null`
        /// sentinel — both fields are always written explicitly on
        /// Save so a prior mode's value can't bleed through).
        var referencedBoardId: String?
        var referencedTemplateId: String?
    }

    // MARK: - Inputs

    let boardTask: BoardTask
    let parentBoard: Board
    let allBoards: [Board]
    let allBoardTasks: [BoardTask]
    let allTemplates: [RecurringBoardTemplate]
    let taskTitle: String
    /// Called when the user confirms a change. Caller persists via
    /// `BoardTaskWriter.updateAchievementSquareConfig` (or equivalent).
    /// The sheet awaits the closure before dismissing so the caller can
    /// surface errors.
    let onSave: (ConfigPatch) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - Local edit state

    @State private var isAchievement: Bool
    @State private var mode: Mode
    @State private var count: Int
    @State private var timeframe: Timeframe
    @State private var achievementType: AchievementType
    @State private var referencedBoardId: String?
    @State private var referencedTemplateId: String?
    @State private var boardSearch: String = ""
    @State private var templateSearch: String = ""
    @State private var cyclePath: [String]? = nil
    @State private var saveError: String? = nil
    @State private var isSaving: Bool = false

    init(
        boardTask: BoardTask,
        parentBoard: Board,
        allBoards: [Board],
        allBoardTasks: [BoardTask],
        allTemplates: [RecurringBoardTemplate],
        taskTitle: String,
        onSave: @escaping (ConfigPatch) async throws -> Void
    ) {
        self.boardTask = boardTask
        self.parentBoard = parentBoard
        self.allBoards = allBoards
        self.allBoardTasks = allBoardTasks
        self.allTemplates = allTemplates
        self.taskTitle = taskTitle
        self.onSave = onSave

        // Hydrate from the existing BoardTask row.
        _isAchievement = State(initialValue: boardTask.isAchievementSquare ?? false)
        let initialMode: Mode = {
            if boardTask.referencedBoardId != nil { return .specificBoard }
            if boardTask.referencedTemplateId != nil { return .recurringTemplate }
            return .aggregate
        }()
        _mode = State(initialValue: initialMode)
        _count = State(initialValue: boardTask.achievementCount ?? 1)
        _timeframe = State(initialValue: boardTask.achievementTimeframe ?? .weekly)
        _achievementType = State(initialValue: boardTask.achievementType ?? .fullCompletion)
        _referencedBoardId = State(initialValue: boardTask.referencedBoardId)
        _referencedTemplateId = State(initialValue: boardTask.referencedTemplateId)
    }

    // MARK: - Derived

    private var filteredBoards: [Board] {
        let query = boardSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allBoards
            .filter { $0.id != parentBoard.id && !$0.isDeleted }
            .filter { query.isEmpty ? true : $0.name.lowercased().contains(query) }
    }

    private var filteredTemplates: [RecurringBoardTemplate] {
        let query = templateSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allTemplates
            .filter { !$0.isDeleted }
            .filter { query.isEmpty ? true : $0.name.lowercased().contains(query) }
    }

    private var selectedTemplate: RecurringBoardTemplate? {
        guard let id = referencedTemplateId else { return nil }
        return allTemplates.first(where: { $0.id == id })
    }

    private var templateInWindowCount: Int {
        guard let template = selectedTemplate else { return 0 }
        return allBoards.filter { b in
            !b.isDeleted
                && b.spawnedFromTemplateId == template.id
                && b.startDate >= parentBoard.startDate
                && b.startDate <= parentBoard.endDate
        }.count
    }

    private var canSave: Bool {
        if !isAchievement { return true }
        switch mode {
        case .aggregate: return count > 0
        case .specificBoard: return referencedBoardId != nil
        case .recurringTemplate: return referencedTemplateId != nil
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // ── Header (cell info) ──
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cell")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(taskTitle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                }

                // ── Top-level toggle ──
                Section {
                    Toggle("Treat this cell as an achievement square", isOn: $isAchievement)
                } footer: {
                    Text("Achievement squares complete from cross-board signals (other boards greenlogging, recurring spawns completing) instead of the cell's underlying task.")
                }

                // ── Mode selector (only when achievement square is ON) ──
                if isAchievement {
                    Section("Completion source") {
                        ForEach(Mode.allCases) { m in
                            Button {
                                mode = m
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: mode == m ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(mode == m ? .accentColor : .secondary)
                                        .font(.system(size: 18))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.title)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                        Text(m.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // ── Mode-specific sub-controls ──
                if isAchievement && mode == .aggregate {
                    Section("Aggregate settings") {
                        Stepper(value: $count, in: 1...100) {
                            HStack {
                                Text("Boards needed")
                                Spacer()
                                Text("\(count)").foregroundColor(.secondary)
                            }
                        }
                        Picker("Timeframe", selection: $timeframe) {
                            Text("Daily").tag(Timeframe.daily)
                            Text("Weekly").tag(Timeframe.weekly)
                            Text("Monthly").tag(Timeframe.monthly)
                            Text("Yearly").tag(Timeframe.yearly)
                        }
                        Picker("Condition", selection: $achievementType) {
                            Text("Bingo line completed").tag(AchievementType.bingo)
                            Text("All squares completed").tag(AchievementType.fullCompletion)
                        }
                    }
                }

                if isAchievement && mode == .specificBoard {
                    Section("Pick a board") {
                        TextField("Search boards…", text: $boardSearch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if filteredBoards.isEmpty {
                            Text("No matching boards.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(filteredBoards, id: \.id) { b in
                                Button {
                                    referencedBoardId = b.id
                                } label: {
                                    HStack {
                                        Image(systemName: referencedBoardId == b.id ? "largecircle.fill.circle" : "circle")
                                            .foregroundColor(referencedBoardId == b.id ? .accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(b.name)
                                                .foregroundColor(.primary)
                                            Text("\(b.timeframe.rawValue) · \(b.status.rawValue)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if isAchievement && mode == .recurringTemplate {
                    Section("Pick a template") {
                        TextField("Search templates…", text: $templateSearch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if filteredTemplates.isEmpty {
                            Text("No matching templates. Create one in Profile → Recurring templates.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(filteredTemplates, id: \.id) { t in
                                Button {
                                    referencedTemplateId = t.id
                                } label: {
                                    HStack {
                                        Image(systemName: referencedTemplateId == t.id ? "largecircle.fill.circle" : "circle")
                                            .foregroundColor(referencedTemplateId == t.id ? .accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(t.name)
                                                .foregroundColor(.primary)
                                            Text("\(t.timeframe.rawValue)\(t.isActive ? "" : " · paused")")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Paused-template warning — surfaced inline so the user
                        // can see the implication before saving. Doesn't block.
                        if let t = selectedTemplate, !t.isActive {
                            warningRow(
                                "This template is paused; only existing spawns will count toward this square. Resume it from Profile → Recurring templates if you want new windows to spawn."
                            )
                        }

                        // Empty-window warning — the square would never
                        // complete with the current state of this board's
                        // window.
                        if let t = selectedTemplate, templateInWindowCount == 0 {
                            warningRow(
                                "No spawns of \"\(t.name)\" fall inside this board's window. The square will only complete after a future spawn lands inside [\(parentBoard.startDate.prefix(10)) → \(parentBoard.endDate.prefix(10))]."
                            )
                        }
                    }
                }

                // ── Cycle-detection error display ──
                if let path = cyclePath {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("This would create a cycle in the cross-board dependency graph.")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Text(
                                path
                                    .map { id -> String in
                                        allBoards.first(where: { $0.id == id })?.name ?? String(id.prefix(8))
                                    }
                                    .joined(separator: " → ")
                            )
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.orange.opacity(0.12))
                }

                // ── Save error display ──
                if let err = saveError {
                    Section {
                        Text(err)
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Configure cell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        _Concurrency.Task { await handleSave() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
        }
    }

    // MARK: - Save

    /// Composes the patch based on the current mode, runs cycle detection
    /// for specific-mode placements, surfaces any error inline, otherwise
    /// delegates to `onSave`. The sheet dismisses only on successful save —
    /// failures keep it open so the user can correct.
    private func handleSave() async {
        cyclePath = nil
        saveError = nil

        // Build the patch. When achievement square is OFF, clear both
        // reference fields. When ON + a specific mode, clear the other
        // reference field + aggregate fields so a prior mode's value
        // doesn't bleed through.
        let patch: ConfigPatch
        if !isAchievement {
            patch = ConfigPatch(
                isAchievementSquare: false,
                achievementType: nil,
                achievementCount: nil,
                achievementTimeframe: nil,
                referencedBoardId: nil,
                referencedTemplateId: nil
            )
        } else {
            switch mode {
            case .aggregate:
                patch = ConfigPatch(
                    isAchievementSquare: true,
                    achievementType: achievementType,
                    achievementCount: count,
                    achievementTimeframe: timeframe,
                    referencedBoardId: nil,
                    referencedTemplateId: nil
                )
            case .specificBoard:
                patch = ConfigPatch(
                    isAchievementSquare: true,
                    achievementType: nil,
                    achievementCount: nil,
                    achievementTimeframe: nil,
                    referencedBoardId: referencedBoardId,
                    referencedTemplateId: nil
                )
            case .recurringTemplate:
                patch = ConfigPatch(
                    isAchievementSquare: true,
                    achievementType: nil,
                    achievementCount: nil,
                    achievementTimeframe: nil,
                    referencedBoardId: nil,
                    referencedTemplateId: referencedTemplateId
                )
            }
        }

        // Cycle detection — only meaningful for the two specific modes.
        // The candidate carries whichever reference is non-nil; hasCycle's
        // adjacency walk handles both edge kinds (direct + template fan-
        // out).
        if isAchievement && (mode == .specificBoard || mode == .recurringTemplate) {
            let candidate = CycleCheckCandidate(
                boardId: parentBoard.id,
                referencedBoardId: patch.referencedBoardId,
                referencedTemplateId: patch.referencedTemplateId
            )
            let context = CycleCheckContext(
                allBoardTasks: allBoardTasks,
                allBoards: allBoards
            )
            if case .cycle(let path) = CycleDetection.hasCycle(candidate: candidate, context: context) {
                cyclePath = path
                return
            }
        }

        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(patch)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func warningRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.primary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(6)
    }
}
