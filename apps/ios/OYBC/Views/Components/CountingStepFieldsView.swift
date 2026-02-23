import SwiftUI

/// Reusable counting step sub-fields view (Action → Max Count → Unit).
///
/// Used inside progress task step rows to display the three fields required
/// for a counting-type step. The field order matches the canonical web
/// implementation in `CountingStepFields.tsx`.
///
/// - Parameters:
///   - action: Binding to the action string (e.g., "Read").
///   - maxCount: Binding to the max count string (positive integer).
///   - unit: Binding to the unit string (e.g., "pages").
///   - actionError: Optional inline error message shown below the action field.
///   - maxCountError: Optional inline error message shown below the max count field.
///   - unitError: Optional inline error message shown below the unit field.
struct CountingStepFieldsView: View {
    @Binding var action: String
    @Binding var maxCount: String
    @Binding var unit: String
    var actionError: String? = nil
    var maxCountError: String? = nil
    var unitError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Action (e.g. Read)", text: $action)
                .textFieldStyle(.roundedBorder)
            if let error = actionError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            TextField("Max count", text: $maxCount)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
            if let error = maxCountError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            TextField("Unit (e.g. pages)", text: $unit)
                .textFieldStyle(.roundedBorder)
            if let error = unitError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
    }
}
