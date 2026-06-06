import SwiftUI

// MARK: - Fixture types

/// In-memory fixture for the source (shared-accumulator) counting task.
private struct SourceFixture {
    var action: String
    var unit: String
    var maxCount: Int
    var currentCount: Int
}

// MARK: - Playground view

/// SharedCounterPlayground — Phase 1 spike (math only).
///
/// Validates `deriveDisplayedCount()` + the no-overshoot-clamp invariant
/// end-to-end in an in-memory harness. No DB writes, no real Task rows, no sync.
/// Synthetic fixtures only.
///
/// Swift math: `apps/ios/OYBC/Helpers/SharedCounter.swift`
/// TS source-of-truth: `packages/shared/src/algorithms/sharedCounter.ts`
/// Design: ARCHITECTURE.md § "Shared counters (Issue #84 — Phase 0 design)"
///
/// Mirrors `SharedCounterPlayground.tsx` on web.
struct SharedCounterPlayground: View {

    // MARK: - Source state

    @State private var source = SourceFixture(
        action: "Read",
        unit: "pages",
        maxCount: 500,
        currentCount: 0
    )

    // MARK: - Derived tasks state

    @State private var derivedTasks: [DerivedCounterRowData] = []

    // MARK: - Add-derived form state

    @State private var addMode: DerivedCounterBaselineMode = .inherit
    @State private var addMaxCountText: String = ""
    @State private var addMaxCountError: String? = nil

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                phaseNote
                sourceSection
                addDerivedSection
                derivedSection
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Phase note

    private var phaseNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
                .font(.system(size: 13))
            Text("Phase 1 spike — math only. No DB writes. See ARCHITECTURE.md § Shared counters.")
                .font(.system(size: 13))
                .foregroundStyle(.blue)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Source section

    private var sourceSection: some View {
        sectionCard(title: "Source task (shared accumulator)") {
            VStack(alignment: .leading, spacing: 10) {
                // Metadata row
                HStack(spacing: 20) {
                    metaField(label: "Action", value: source.action)
                    metaField(label: "Unit", value: source.unit)
                    metaField(label: "Target", value: "\(source.maxCount)")
                }

                Divider()

                // currentCount control
                HStack(spacing: 12) {
                    Text("currentCount")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Button {
                        if source.currentCount > 0 { source.currentCount -= 1 }
                    } label: {
                        Text("−1")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 44, height: 32)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(source.currentCount <= 0)

                    Text("\(source.currentCount)")
                        .font(.system(size: 28, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.blue)
                        .frame(minWidth: 44)
                        .accessibilityLabel("Source current count: \(source.currentCount)")

                    Button {
                        source.currentCount += 1
                    } label: {
                        Text("+1")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 44, height: 32)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }

                Text("\(source.currentCount) / \(source.maxCount) (source threshold — informational only)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if source.currentCount > source.maxCount {
                    overshootNote
                }
            }
        }
    }

    private var overshootNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.orange)
                .font(.system(size: 12))
            Text("Source is past its own threshold (\(source.currentCount) > \(source.maxCount)). Derived tasks show the full overshoot — no high-end clamp.")
                .font(.system(size: 12))
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Add derived section

    private var addDerivedSection: some View {
        sectionCard(title: "Add derived task") {
            VStack(alignment: .leading, spacing: 12) {
                // Baseline mode picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Baseline mode")
                        .font(.system(size: 13, weight: .semibold))

                    Picker("Baseline mode", selection: $addMode) {
                        Text("Inherit").tag(DerivedCounterBaselineMode.inherit)
                        Text("Start from zero").tag(DerivedCounterBaselineMode.startFromZero)
                    }
                    .pickerStyle(.segmented)

                    Text(addMode == .inherit
                         ? "Counts from 0 — source progress credited from the start (baseline = 0)."
                         : "Counts from current source value (baseline = \(source.currentCount) at add time).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // maxCount field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Target count for derived task")
                        .font(.system(size: 13, weight: .semibold))

                    HStack(spacing: 10) {
                        TextField("e.g. 100", text: $addMaxCountText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(addMaxCountError != nil ? Color.red : Color.clear, lineWidth: 1)
                            )
                            .onChange(of: addMaxCountText) { _ in
                                if addMaxCountError != nil { addMaxCountError = nil }
                            }

                        // Live title preview
                        if let maxCount = parsedMaxCount {
                            Text("Title: \"\(generateCounterTaskTitle(source.action, maxCount, source.unit))\"")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let error = addMaxCountError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }

                // Add button
                Button("Add derived task") {
                    handleAddDerived()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var parsedMaxCount: Int? {
        guard let v = Int(addMaxCountText), v >= 1 else { return nil }
        return v
    }

    private func handleAddDerived() {
        guard let maxCount = parsedMaxCount else {
            addMaxCountError = "Enter a positive integer target count."
            return
        }
        addMaxCountError = nil

        // Decision 6: Inherit → baseline 0; Start from zero → baseline = currentCount at add-time.
        let baseline = addMode == .startFromZero ? source.currentCount : 0

        // Decision 2 (title): autofill from generateCounterTaskTitle().
        let title = generateCounterTaskTitle(source.action, maxCount, source.unit)

        let newTask = DerivedCounterRowData(
            id: "derived-\(UUID().uuidString)",
            title: title,
            maxCount: maxCount,
            baseline: baseline,
            baselineMode: addMode
        )

        derivedTasks.append(newTask)
        addMaxCountText = ""
    }

    // MARK: - Derived tasks section

    private var derivedSection: some View {
        sectionCard(title: "Derived tasks (\(derivedTasks.count))") {
            if derivedTasks.isEmpty {
                Text("No derived tasks yet. Use the form above to add one.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                VStack(spacing: 6) {
                    ForEach(derivedTasks) { task in
                        let result = deriveDisplayedCount(
                            derivedBaseline: task.baseline,
                            derivedMaxCount: task.maxCount,
                            sourceCurrentCount: source.currentCount
                        )

                        DerivedCounterRowView(
                            data: task,
                            displayed: result.displayed,
                            isCompleted: result.isCompleted,
                            onRemove: { id in
                                derivedTasks.removeAll { $0.id == id }
                            }
                        )
                    }

                    if derivedTasks.contains(where: { task in
                        let r = deriveDisplayedCount(
                            derivedBaseline: task.baseline,
                            derivedMaxCount: task.maxCount,
                            sourceCurrentCount: source.currentCount
                        )
                        return r.isCompleted && r.displayed > task.maxCount
                    }) {
                        invariantNote
                    }
                }
            }
        }
    }

    private var invariantNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
                .font(.system(size: 12))
            Text("No-clamp invariant in effect: displayed counts exceed maxCount above. This is intentional — the source keeps accumulating.")
                .font(.system(size: 12))
                .foregroundStyle(.blue)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helpers

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))

            Divider()

            content()
                .padding(12)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separator), lineWidth: 1)
        )
    }

    private func metaField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Swift port of generateCounterTaskTitle()
    //
    // Mirrors `generateCounterTaskTitle()` from `packages/shared/src/algorithms/taskTitle.ts`.
    // No actual Task creation — used only for the playground title autofill.
    private func generateCounterTaskTitle(_ action: String, _ maxCount: Int, _ unit: String) -> String {
        return "\(action.trimmingCharacters(in: .whitespaces)) \(maxCount) \(unit.trimmingCharacters(in: .whitespaces))"
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ScrollView {
            SharedCounterPlayground()
                .padding()
        }
        .navigationTitle("Shared Counter Spike")
    }
}
