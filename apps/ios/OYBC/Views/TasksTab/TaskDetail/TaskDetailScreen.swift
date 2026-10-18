import SwiftUI

/// Task Detail's content: the hero band over the segmented sections — the same view
/// for the pushed route and the "Open in library" sheet (they differ only in the hero's
/// nav row). Pure props. Web twin: `pages/tasks/TaskDetailContent.tsx`.
struct TaskDetailScreen: View {

    let model: TaskDetailModel
    var strip: SquareLogStrip? = nil
    var isBusy = false
    var busyLook: Bool? = nil
    var presentation: TaskDetailPresentation = .route
    @Binding var tab: TaskDetailTab
    var actions = TaskDetailActions()
    var saveError: String? = nil
    /// Snapshot seams (see `TaskDetailHeroView`).
    var initialOpenChildId: String? = nil
    var initialEntry: SquareSheetEntry? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                TaskDetailHeroView(
                    model: model, strip: strip, isBusy: isBusy, busyLook: busyLook, presentation: presentation, actions: actions,
                    initialOpenChildId: initialOpenChildId, initialEntry: initialEntry
                )
                if let saveError {
                    Text(saveError)
                        .font(.risoBody(13, .regular))
                        .foregroundStyle(Color.risoRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.top, 12)
                }
                TaskDetailSectionsView(model: model, tab: $tab, actions: actions)
            }
        }
        .background(RisoPaperBackground().ignoresSafeArea())
    }
}
