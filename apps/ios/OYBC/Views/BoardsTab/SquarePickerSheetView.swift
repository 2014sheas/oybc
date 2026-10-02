import SwiftUI

// MARK: - SquarePickerMode

/// Which square the picker is filling (Board Edit redesign slice 3, D13).
enum SquarePickerMode: Equatable {
    /// An empty square — no exclusion beyond the standard eligibility rules.
    case add
    /// An occupied square — `currentTaskId` is excluded from candidates
    /// (its own family-mates are NOT excluded — replacing "Read 20" with
    /// "Read 50" legitimately swaps the family's slot).
    case replace(currentTaskId: String)
}

// MARK: - SquarePickerSheetView

/// The ONE picker sheet for both Replace and Add (D13, handoff i5/p5/d2) —
/// the wizard's quick-add row + special-type panel, reused verbatim so
/// "same job, same interface" (task creation) holds across the app. No
/// Library or Sources tab — those are wizard-only surfaces.
///
/// Everything staged here is written to the DB only when `BoardEditPanel`'s
/// Save commits (D14) — `onConfirm` hands the caller a `(taskId, pending)`
/// pair; the VM's `handleEditAdd` / `handleEditReplace` store it in the
/// draft. A Compound is deferred like every other new task on iOS: the panel
/// hands it over as a `PendingTaskPayload` (task + child tasks + links)
/// inserted at Save (web persists a picker-born compound immediately).
struct SquarePickerSheetView: View {

    // MARK: - Props

    let mode: SquarePickerMode
    let userId: String
    /// Eligibility-filtered candidates (`SquarePickerCandidates.filter`) —
    /// deleted / already-drafted / family-mate / ineligible-type tasks are
    /// already excluded. The quick-add row applies its own live text filter
    /// on top of this list.
    let candidateTasks: [Task]
    let onDismiss: () -> Void
    /// `pending` is non-nil for a not-yet-created task (Normal / Counting /
    /// Achievement, D14) — nil for an existing task OR a just-created
    /// Compound (created immediately by the special panel).
    let onConfirm: (_ taskId: String, _ pending: PendingTaskPayload?) -> Void

    // MARK: - Derived

    private var kicker: String {
        switch mode {
        case .add: return "ADD SQUARE"
        case .replace: return "REPLACE SQUARE"
        }
    }

    private var title: String {
        switch mode {
        case .add: return "Empty square"
        case .replace(let currentTaskId):
            return candidateTasks.first { $0.id == currentTaskId }?.title
                ?? "Replace this square"
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                RisoPaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header

                        RisoQuickAddRowView(
                            userId: userId,
                            defaultTimeframe: nil,
                            defaultStartDate: nil,
                            defaultEndDate: nil,
                            onTaskCreated: { _, _, _ in },
                            onPendingCreated: { payload in
                                onConfirm(payload.task.id, payload)
                            },
                            onLibraryReloadRequested: {},
                            libraryTasks: candidateTasks,
                            onExistingTaskPicked: { task in
                                onConfirm(task.id, nil)
                            }
                        )

                        RisoSpecialTaskPanel(
                            userId: userId,
                            defaultTimeframe: nil,
                            defaultStartDate: nil,
                            defaultEndDate: nil,
                            taskLibrary: candidateTasks,
                            onTaskCreated: { _, _, _ in },
                            onCompoundCreated: { task in
                                onConfirm(task.id, nil)
                            },
                            onPendingCreated: { payload in
                                onConfirm(payload.task.id, payload)
                            },
                            onLibraryReloadRequested: {},
                            allowAchievement: true,
                            submitLabel: "Add to board ✦"
                        )
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(22)
        .presentationBackground(Color.risoPaper)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kicker)
                .risoKicker()
            Text(title)
                .risoH2()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

#Preview {
    SquarePickerSheetView(
        mode: .add,
        userId: "u1",
        candidateTasks: [],
        onDismiss: {},
        onConfirm: { _, _ in }
    )
}
