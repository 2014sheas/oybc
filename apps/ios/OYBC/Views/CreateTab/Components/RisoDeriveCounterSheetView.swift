import SwiftUI

// MARK: - RisoDeriveCounterSheetView

/// Shared Riso-styled "Derive smaller version…" sheet — extracted from the
/// retired wizard grid picker's private copy once the pool-edit sheet
/// became the third consumer (extract-at-three; the library sheet's inline
/// builder was the second). Creates a LINKED smaller counter, never a
/// standalone duplicate — see `resolveDeriveLinkTarget`.
struct RisoDeriveCounterSheetView: View {
    let source: OYBC.Task
    @Binding var input: String
    @Binding var error: String?
    let userId: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        let action = (source.action ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = (source.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let derivedTitle = parsed > 0 ? TaskTitle.generateCounterTaskTitle(action: action, maxCount: parsed, unit: unit) : nil

        NavigationStack {
            ZStack {
                RisoPaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // From section — "From {title} — same counter, lower goal."
                        VStack(alignment: .leading, spacing: 6) {
                            Text("DERIVED FROM")
                                .font(.risoBody(11, .bold))
                                .tracking(0.22 * 11)
                                .foregroundStyle(Color.risoMuted)
                            (Text("From ")
                                .font(.risoBody(13, .semibold))
                                .foregroundStyle(Color.risoMuted)
                            + Text(source.title)
                                .font(.risoHead(13, .bold))
                                .foregroundStyle(Color.risoInk)
                            + Text(" — same counter, lower goal.")
                                .font(.risoBody(13, .semibold))
                                .foregroundStyle(Color.risoMuted))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.risoPaper2)
                            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Riso.cardRadius)
                                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                            )
                        }

                        // New goal section
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NEW GOAL")
                                .font(.risoBody(11, .bold))
                                .tracking(0.22 * 11)
                                .foregroundStyle(Color.risoMuted)
                            RisoNumberField(placeholder: "e.g. 20", text: $input)
                        }

                        // Preview row — "New task: {derived title} — still counts {noun}."
                        if let derivedTitle {
                            (Text("New task: ")
                                .font(.risoBody(12, .regular))
                                .foregroundStyle(Color.risoMuted)
                            + Text(derivedTitle)
                                .font(.risoHead(13, .bold))
                                .foregroundStyle(Color.risoInk)
                            + Text(" — still counts \(unit).")
                                .font(.risoBody(12, .regular))
                                .foregroundStyle(Color.risoMuted))
                        }

                        // Error
                        if let error {
                            Text(error)
                                .font(.risoBody(11, .semibold))
                                .foregroundStyle(Color.risoRed)
                        }
                    }
                    .padding(Riso.gutter)
                }
            }
            .navigationTitle("Smaller version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { onSave() }
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoBlue)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Shared save action

enum DeriveCounterAction {
    /// Validates the goal input and persists the LINKED smaller counter.
    /// Off-main; calls back on main with the created task or an error
    /// message. Shared by the source-board grid, the library sheet, and
    /// the pool-edit sheet so the three derive flows can't drift.
    static func createDerived(
        source: OYBC.Task,
        goalInput: String,
        userId: String,
        onError: @escaping (String) -> Void,
        onCreated: @escaping (OYBC.Task) -> Void
    ) {
        guard let action = source.action,
              let unit = source.unit,
              let parsed = Int(goalInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0
        else {
            onError("Goal must be a positive integer")
            return
        }

        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = TaskTitle.generateCounterTaskTitle(action: trimmedAction, maxCount: parsed, unit: trimmedUnit)
        let now = AppDatabase.currentTimestamp()
        let newId = AppDatabase.generateUUID()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let rootId = source.sharedCounterId ?? source.id
                let rootTask = rootId == source.id ? source : try AppDatabase.shared.fetchTask(id: rootId)
                let linkTarget = resolveDeriveLinkTarget(source: source, rootTask: rootTask)

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
                    isDeleted: false,
                    sharedCounterId: linkTarget.sharedCounterId,
                    baseline: linkTarget.baseline
                )

                try AppDatabase.shared.createTaskAndEnqueue(newTask, now: now)
                DispatchQueue.main.async { onCreated(newTask) }
            } catch {
                DispatchQueue.main.async {
                    onError("Failed to save: \(error.localizedDescription)")
                }
            }
        }
    }
}
