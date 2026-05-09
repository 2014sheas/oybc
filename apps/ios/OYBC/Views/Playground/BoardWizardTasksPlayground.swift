import SwiftUI

private struct RequiredPreset: Identifiable, Hashable {
    let id: Int
    let label: String
    var value: Int { id }
}

private let requiredPresets: [RequiredPreset] = [
    RequiredPreset(id: 8,  label: "3×3 (8)"),
    RequiredPreset(id: 9,  label: "3×3 chosen (9)"),
    RequiredPreset(id: 16, label: "4×4 (16)"),
    RequiredPreset(id: 24, label: "5×5 (24)"),
    RequiredPreset(id: 25, label: "5×5 chosen (25)"),
]

/// BoardWizardTasksPlayground — iOS spike harness for build-sequence
/// step 1 of the board-creation UX redesign. Mirrors the web playground
/// of the same name.
///
/// Mounts the production `BoardWizardTasksStepView` with simulated
/// wizard state. Exposes harness controls so the user can flex the
/// surface across configurations (different `tasksRequired` counts
/// and the conditional center-task radio) without spinning up the
/// full wizard plumbing.
///
/// Persists no wizard state to GRDB — selection lives in local
/// `@State`. Tasks created via the inline "+ New task" sheet ARE
/// persisted to the playground user's library so they survive a
/// reload.
struct BoardWizardTasksPlayground: View {

    // MARK: - Library

    @State private var library = TaskLibraryViewModel()

    // MARK: - Simulated wizard state

    @State private var selectedTaskIds: Set<String> = []
    @State private var centerTaskId: String? = nil

    // MARK: - Harness controls

    @State private var tasksRequired: Int = 16
    @State private var centerTaskMode: Bool = false
    @State private var navMessage: String? = nil
    @State private var seedStatus: String? = nil
    @State private var isSeeding: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            harnessControls

            if let nav = navMessage {
                Text(nav)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
            if let seed = seedStatus {
                Text(seed)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }

            BoardWizardTasksStepView(
                library: library,
                selectedTaskIds: $selectedTaskIds,
                tasksRequired: tasksRequired,
                // Playground simulates the default one-off behavior; the new
                // recurring/strict-exact flags are wizard-state-driven and
                // there's no harness state for them here.
                poolStrictExact: false,
                isRecurring: false,
                centerTaskMode: centerTaskMode,
                centerTaskId: $centerTaskId,
                userId: playgroundUserId,
                // Playground-only seed: .custom hides the new "From parent
                // boards" filter chip (it has no parent timeframes), keeping
                // the playground's existing behavior unchanged.
                currentTimeframe: .custom,
                onTaskCreated: { taskId, _, _ in
                    selectedTaskIds.insert(taskId)
                },
                onCompositeCreated: { _ in
                    // Composites can't be auto-selected (not boardable as a unit).
                },
                onLibraryReloadRequested: {
                    library.loadLibrary(userId: playgroundUserId)
                },
                onBack: {
                    navMessage = "« Back tapped (would return to Step 1: Setup)"
                },
                onNext: {
                    navMessage = "» Next tapped (would advance to Step 3: Preview & Activate)"
                }
            )
        }
        .onAppear {
            ensurePlaygroundUser()
            library.loadLibrary(userId: playgroundUserId)
        }
    }

    // MARK: - Harness controls

    private var harnessControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Picker("Tasks required", selection: $tasksRequired) {
                    ForEach(requiredPresets) { p in
                        Text(p.label).tag(p.value)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Tasks required preset")

                Toggle("Center mode", isOn: $centerTaskMode)
                    .toggleStyle(.switch)
                    .onChange(of: centerTaskMode) { _, newValue in
                        if !newValue { centerTaskId = nil }
                    }
            }

            HStack(spacing: 8) {
                Button("Reset selection") {
                    selectedTaskIds = []
                    centerTaskId = nil
                    navMessage = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    seedSampleTasks()
                } label: {
                    if isSeeding {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Seed sample library")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSeeding)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.systemGray3), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }

    // MARK: - Seeding

    private func seedSampleTasks() {
        isSeeding = true
        seedStatus = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let now = AppDatabase.currentTimestamp()
                let normalTitles = [
                    "Run 5km",
                    "Read 30 minutes",
                    "Meditate",
                    "Cook a homemade meal",
                    "Call a friend",
                    "Write in journal",
                    "Try a new recipe",
                ]
                let countingDefs: [(String, String, Int)] = [
                    ("Read", "pages", 50),
                    ("Walk", "km", 10),
                    ("Drink", "glasses of water", 8),
                ]
                let progressDefs: [(String, [(String, TaskType)])] = [
                    ("Weekly workout", [
                        ("Monday run", .normal),
                        ("Wednesday weights", .normal),
                        ("Friday yoga", .normal),
                    ]),
                    ("Clean house", [
                        ("Vacuum", .normal),
                        ("Dust", .normal),
                        ("Mop floors", .normal),
                    ]),
                ]

                try AppDatabase.shared.write { db in
                    for title in normalTitles {
                        let task = Task(
                            id: AppDatabase.generateUUID(),
                            userId: playgroundUserId,
                            title: title,
                            type: .normal,
                            totalCompletions: 0,
                            totalInstances: 0,
                            createdAt: now,
                            updatedAt: now,
                            version: 1,
                            isDeleted: false
                        )
                        try task.save(db)
                    }

                    for (action, unit, max) in countingDefs {
                        let title = "\(action) \(max) \(unit)"
                        let task = Task(
                            id: AppDatabase.generateUUID(),
                            userId: playgroundUserId,
                            title: title,
                            type: .counting,
                            action: action,
                            unit: unit,
                            maxCount: max,
                            totalCompletions: 0,
                            totalInstances: 0,
                            createdAt: now,
                            updatedAt: now,
                            version: 1,
                            isDeleted: false
                        )
                        try task.save(db)
                    }

                    for (parentTitle, steps) in progressDefs {
                        let parentId = AppDatabase.generateUUID()
                        let parentTask = Task(
                            id: parentId,
                            userId: playgroundUserId,
                            title: parentTitle,
                            type: .compound,
                            operatorType: .and,
                            isOrdered: true,
                            totalCompletions: 0,
                            totalInstances: 0,
                            createdAt: now,
                            updatedAt: now,
                            version: 1,
                            isDeleted: false
                        )
                        try parentTask.save(db)

                        for (i, (stepTitle, stepType)) in steps.enumerated() {
                            // Under the unified compound model, each step
                            // becomes a primitive child Task plus a
                            // CompoundChild link row (replaces the legacy
                            // task_steps + linkedTaskId pattern).
                            let stepTaskId = AppDatabase.generateUUID()
                            let stepTask = Task(
                                id: stepTaskId,
                                userId: playgroundUserId,
                                title: stepTitle,
                                type: stepType,
                                totalCompletions: 0,
                                totalInstances: 0,
                                createdAt: now,
                                updatedAt: now,
                                version: 1,
                                isDeleted: false
                            )
                            try stepTask.save(db)

                            let link = CompoundChild(
                                id: AppDatabase.generateUUID(),
                                compoundTaskId: parentId,
                                childTaskId: stepTaskId,
                                childIndex: i,
                                createdAt: now,
                                updatedAt: now,
                                lastSyncedAt: nil,
                                version: 1,
                                isDeleted: false,
                                deletedAt: nil
                            )
                            try link.save(db)
                        }
                    }
                }

                let totalCount = normalTitles.count + countingDefs.count + progressDefs.count
                DispatchQueue.main.async {
                    isSeeding = false
                    seedStatus = "Seeded \(totalCount) sample tasks."
                    library.loadLibrary(userId: playgroundUserId)
                }
            } catch {
                DispatchQueue.main.async {
                    isSeeding = false
                    seedStatus = "Seed failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
