import SwiftUI

/// CompositeWizardReviewStepView — Step 3 of the composite-task mini-wizard.
/// iOS twin of web's `ReviewStep`. Shows a summary, a chip list of every
/// subtask (so mistakes surface before the write), and an explicit
/// "these inline tasks also land in your library" callout. Errors
/// include a Try again affordance that re-runs the transaction instead
/// of forcing a Back + re-submit trip.
struct CompositeWizardReviewStepView: View {
    let title: String
    let operatorType: OperatorType
    let threshold: Int
    let subtasks: [SubtaskItem]
    let libraryTasks: [OYBC.Task]
    let libraryCompositeTasks: [CompositeTask]
    let isSubmitting: Bool
    let errorMessage: String?
    let onBack: () -> Void
    let onCreate: () -> Void

    private var operatorLabel: String {
        switch operatorType {
        case .and: return "All of"
        case .or: return "Any of"
        case .mOfN: return "At least \(threshold) of"
        }
    }

    private var inlineCount: Int {
        subtasks.filter { $0.mode == .inline_ }.count
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready to create")
                .font(.title3)
                .fontWeight(.semibold)

            summaryCard
            chipSection

            if inlineCount > 0 {
                libraryCallout
            }

            if let err = errorMessage {
                errorBanner(message: err)
            }

            Divider()

            HStack {
                Button("‹ Back", action: onBack)
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting)
                Spacer()
                Button(action: onCreate) {
                    HStack(spacing: 6) {
                        if isSubmitting {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(.white)
                        }
                        Text(isSubmitting ? "Creating…" : "Create Composite")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(isSubmitting)
            }
        }
        .padding(14)
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryRow(label: "Title", value: trimmedTitle.isEmpty ? "(unset)" : trimmedTitle)
            summaryRow(
                label: "Completion rule",
                value: "\(operatorLabel) · \(subtasks.count) subtask\(subtasks.count == 1 ? "" : "s")"
            )
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func summaryRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Chip list

    private var chipSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUBTASKS")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            ForEach(Array(subtasks.enumerated()), id: \.element.id) { index, item in
                chipView(for: item, index: index + 1)
            }
        }
    }

    @ViewBuilder
    private func chipView(for item: SubtaskItem, index: Int) -> some View {
        let info = chipInfo(for: item)
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.secondary))

            Text(info.badge)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .stroke(Color(.systemGray4), lineWidth: 1)
                        .background(Capsule().fill(Color(.systemBackground)))
                )
                .foregroundColor(.secondary)

            Text(info.title)
                .font(.subheadline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let meta = info.meta {
                Text(meta)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(item.mode == .inline_
                      ? Color.blue.opacity(0.08)
                      : Color(.systemGray6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(item.mode == .inline_
                        ? Color.blue.opacity(0.25)
                        : Color(.systemGray4), lineWidth: 1)
        )
    }

    private struct ChipInfo {
        let badge: String
        let title: String
        let meta: String?
    }

    private func chipInfo(for item: SubtaskItem) -> ChipInfo {
        switch item.mode {
        case .existing:
            if item.selectionType == .task {
                let task = libraryTasks.first(where: { $0.id == item.selectedTaskId })
                let badge = (task?.type.rawValue ?? "task").uppercased()
                let title = task?.title ?? "(unknown task)"
                return ChipInfo(badge: badge, title: title, meta: nil)
            } else {
                let ct = libraryCompositeTasks.first(where: { $0.id == item.selectedCompositeId })
                return ChipInfo(badge: "COMPOSITE", title: ct?.title ?? "(unknown composite)", meta: nil)
            }
        case .inline_:
            let badge = item.inlineType.rawValue.uppercased()
            switch item.inlineType {
            case .counting:
                let t = item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let a = item.inlineAction.trimmingCharacters(in: .whitespacesAndNewlines)
                let c = item.inlineMaxCountStr.trimmingCharacters(in: .whitespacesAndNewlines)
                let u = item.inlineUnit.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = "\(a) \(c) \(u)".trimmingCharacters(in: .whitespacesAndNewlines)
                let title = !t.isEmpty ? t : (fallback.isEmpty ? "(untitled)" : fallback)
                let count = Int(c) ?? 0
                let meta = (count > 0 && !u.isEmpty) ? "\(count) \(u)" : nil
                return ChipInfo(badge: badge, title: title, meta: meta)
            case .progress:
                let t = item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = t.isEmpty ? "(untitled)" : t
                let n = item.inlineSteps.count
                return ChipInfo(badge: badge, title: title, meta: "\(n) step\(n == 1 ? "" : "s")")
            case .normal:
                let t = item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                return ChipInfo(badge: badge, title: t.isEmpty ? "(untitled)" : t, meta: nil)
            }
        }
    }

    // MARK: - Library callout

    private var libraryCallout: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
                .foregroundColor(.blue)
            Text("\(inlineCount) inline task\(inlineCount == 1 ? "" : "s") will also be saved to your library.")
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.blue.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }

    // MARK: - Error banner with retry

    @ViewBuilder
    private func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.caption)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: onCreate)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .disabled(isSubmitting)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
        .cornerRadius(6)
    }
}
