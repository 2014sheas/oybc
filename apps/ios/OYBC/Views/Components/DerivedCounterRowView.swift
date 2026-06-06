import SwiftUI

// MARK: - Data types

/// Data required to render one derived-counter row.
/// Mirrors `DerivedCounterRowData` in `DerivedCounterRow.tsx`.
struct DerivedCounterRowData: Identifiable {
    /// Stable identifier.
    let id: String
    /// Auto-generated title from `generateCounterTaskTitle()`.
    let title: String
    /// The derived task's personal threshold.
    let maxCount: Int
    /// The source count at the time this task was linked.
    let baseline: Int
    /// How the baseline was established.
    let baselineMode: DerivedCounterBaselineMode
}

/// Baseline mode choices — mirrors `BaselineMode` in the web playground.
enum DerivedCounterBaselineMode: String {
    case inherit = "Inherit"
    case startFromZero = "Start from zero"
}

// MARK: - View

/// Renders a single derived counting task's live progress.
///
/// Designed for Phase 1 playground and reusable in Phase 2's
/// `CountingTemplatePickerView` detail section. Shows the task title,
/// baseline mode, progress fraction, and a completion badge.
///
/// No list-badge for the linked relationship (Decision 3: detail-sheet only).
/// Mirrors `DerivedCounterRow.tsx` on the web.
///
/// - Parameters:
///   - data: Static descriptor (title, maxCount, baseline, baselineMode).
///   - displayed: Live displayed count from `deriveDisplayedCount()`.
///   - isCompleted: Live completion snapshot from `deriveDisplayedCount()`.
///   - onRemove: Optional remove callback (playground use only).
struct DerivedCounterRowView: View {

    // MARK: - Parameters

    let data: DerivedCounterRowData
    let displayed: Int
    let isCompleted: Bool
    var onRemove: ((String) -> Void)? = nil

    // MARK: - Derived

    private var progressFraction: Double {
        guard data.maxCount > 0 else { return 1.0 }
        return min(1.0, Double(displayed) / Double(data.maxCount))
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 10) {
            // Left: type badge + title
            HStack(spacing: 6) {
                TypeBadgeView(type: "counting", size: .small)
                Text(data.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isCompleted ? Color.green : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Center: baseline mode + fraction + progress bar
            VStack(alignment: .leading, spacing: 3) {
                Text(data.baselineMode.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text("\(displayed) / \(data.maxCount)")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(.primary)

                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                    .tint(isCompleted ? .green : Color.blue)
            }
            .frame(minWidth: 90)

            // Right: completion badge + optional remove
            HStack(spacing: 6) {
                if isCompleted {
                    Text("Done")
                        .font(.system(size: 10, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text("\(Int(progressFraction * 100))%")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                if let onRemove {
                    Button {
                        onRemove(data.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCompleted ? Color.green.opacity(0.08) : Color(.systemBackground))
                .strokeBorder(isCompleted ? Color.green.opacity(0.3) : Color(.separator), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Derived task: \(data.title), \(displayed) of \(data.maxCount)\(isCompleted ? ", completed" : "")")
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 8) {
        DerivedCounterRowView(
            data: DerivedCounterRowData(
                id: "1",
                title: "Read 100 pages",
                maxCount: 100,
                baseline: 0,
                baselineMode: .inherit
            ),
            displayed: 42,
            isCompleted: false
        )
        DerivedCounterRowView(
            data: DerivedCounterRowData(
                id: "2",
                title: "Read 50 pages",
                maxCount: 50,
                baseline: 200,
                baselineMode: .startFromZero
            ),
            displayed: 5500,
            isCompleted: true
        )
    }
    .padding()
}
