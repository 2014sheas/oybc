import SwiftUI

/// The Simple / Counting / Compound type picker every task-row editor shows —
/// the Board Edit square sheet (`SquareEditTaskSheet`) and the global editor
/// (`EditTaskSheet`, Task Detail + Tasks tab) — so both offer the same control.
/// Whether it shows at all is `TaskTypeSwitch.showsPicker(task:original:)`.
/// Web twin: `components/taskEdit/TaskTypeControl.tsx`.
struct TaskTypePickerView: View {
    /// The selected type.
    @Binding var selection: TaskType

    /// The segments, labels shared with web (`TYPE_OPTIONS`).
    static let options: [(TaskType, String)] = [
        (.normal, "Simple"),
        (.counting, "Counting"),
        (.compound, "Compound"),
    ]

    var body: some View {
        RisoSegmented(options: Self.options.map { (value: $0.0, label: $0.1) }, selection: $selection)
    }
}
