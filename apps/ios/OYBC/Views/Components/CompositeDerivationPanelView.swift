import SwiftUI

/// Panel for inspecting a composite task's operator and leaf nodes.
///
/// Shows the root operator type (AND / OR / M_OF_N) with a human-readable label,
/// then lists each leaf node resolved to its task or nested composite title.
/// Leaf nodes that reference a regular task also show counting metadata and a
/// type badge. Each leaf has an "Add to Pool" button unless it is already pooled.
///
/// Mirrors the web `CompositeDerivationPanel` component.
///
/// - Parameters:
///   - compositeTask: The parent CompositeTask being inspected.
///   - compositeNodes: All nodes belonging to the composite task.
///   - tasks: Full task library used to resolve leaf `taskId` references.
///   - compositeTasks: Full composite task library used to resolve nested composite references.
///   - boardPool: Current board pool entries; used to show "In Pool" state.
///   - onAddLeafToPool: Called with (taskId, title, type) when the user taps "Add to Pool".
struct CompositeDerivationPanelView: View {

    // MARK: - Parameters

    let compositeTask: CompositeTask
    let compositeNodes: [CompositeNode]
    let tasks: [Task]
    let compositeTasks: [CompositeTask]
    let boardPool: [(taskId: String, title: String, type: String)]
    let onAddLeafToPool: (String, String, String) -> Void

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(compositeTask.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                TypeBadgeView(type: "composite", size: .small)
            }

            if compositeNodes.isEmpty {
                Text("No nodes found for this composite task.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                let rootNode = compositeNodes.first(where: { $0.parentNodeId == nil })
                let leafNodes = compositeNodes.filter { $0.nodeType == .leaf }
                let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
                let compositeMap = Dictionary(uniqueKeysWithValues: compositeTasks.map { ($0.id, $0) })

                // Operator summary
                if let root = rootNode, let opType = root.operatorType {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Operator")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Text(operatorLabel(opType, threshold: root.threshold, leafCount: leafNodes.count))
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(opType.rawValue)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }

                    Divider()
                }

                // Leaf nodes
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(leafNodes.count) leaf node\(leafNodes.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(leafNodes.sorted(by: { $0.nodeIndex < $1.nodeIndex }), id: \.id) { node in
                        leafRow(node, taskMap: taskMap, compositeMap: compositeMap)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Leaf Row

    /// A single leaf node row showing the resolved task or composite title with pool action.
    ///
    /// - Parameters:
    ///   - node: The CompositeNode (leaf) to display.
    ///   - taskMap: Dictionary mapping task IDs to Task values for quick lookup.
    ///   - compositeMap: Dictionary mapping composite task IDs to CompositeTask values.
    @ViewBuilder
    private func leafRow(
        _ node: CompositeNode,
        taskMap: [String: Task],
        compositeMap: [String: CompositeTask]
    ) -> some View {
        HStack {
            Text("\u{00B7}")
                .foregroundColor(.secondary)

            if let taskId = node.taskId, let task = taskMap[taskId] {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.subheadline)
                    if task.type == .counting,
                       let action = task.action,
                       let maxCount = task.maxCount,
                       let unit = task.unit {
                        Text("\(action) \(maxCount) \(unit)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                TypeBadgeView(type: task.type.rawValue, size: .small)

                // Pool action for regular task leaf
                if boardPool.contains(where: { $0.taskId == task.id }) {
                    Text("In Pool \u{2713}")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                } else {
                    Button("Add to Pool") {
                        onAddLeafToPool(task.id, task.title, task.type.rawValue)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }

            } else if let childId = node.childCompositeTaskId, let child = compositeMap[childId] {
                Text(child.title)
                    .font(.subheadline)
                Spacer()
                TypeBadgeView(type: "composite", size: .small)
            } else {
                Text("Unknown reference")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(8)
        .background(Color(.systemGray5))
        .cornerRadius(6)
    }

    // MARK: - Helpers

    /// Human-readable label for a composite operator.
    ///
    /// - Parameters:
    ///   - type: The OperatorType.
    ///   - threshold: Threshold for M_OF_N; unused for AND/OR.
    ///   - leafCount: Total leaf count for M_OF_N context.
    /// - Returns: A descriptive string such as "All of", "Any of", or "At least 2 of 4".
    private func operatorLabel(_ type: OperatorType, threshold: Int?, leafCount: Int) -> String {
        switch type {
        case .and:  return "All of"
        case .or:   return "Any of"
        case .mOfN: return "At least \(threshold ?? 0) of \(leafCount)"
        }
    }
}
