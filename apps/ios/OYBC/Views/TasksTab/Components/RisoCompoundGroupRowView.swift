import SwiftUI

/// Riso-styled compound group row.
///
/// Renders a compound parent with a trailing disclosure chevron; when
/// expanded, indented child rows appear below it with a dashed left
/// border. Mirrors the prototype's compound grouping in `TTRow` and the
/// expanded child list in `TasksTab`.
///
/// The view is intentionally non-interactive beyond the expand chevron —
/// the caller (`TasksTabView`) wraps the compound row in a `Button` for
/// navigation and supplies swipe-action handlers for edit / delete.
struct RisoCompoundGroupRowView: View {
    let task: Task
    let placementCount: Int
    let activePlacementCount: Int
    let childCount: Int
    let isExpandable: Bool
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    /// Child tasks to display when expanded. Caller resolves the actual
    /// `Task` objects from `library.taskMap`; nil entries are skipped.
    let children: [(link: CompoundChild, task: Task?)]

    /// Per-child placement counts, keyed by taskId.
    let childPlacementCounts: [String: Int]
    let childActivePlacementCounts: [String: Int]

    /// Called when the user taps a child row to navigate to its detail.
    let onChildTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ── Parent row + chevron ───────────────────────────────────
            HStack(spacing: 8) {
                RisoTaskRowView(
                    task: task,
                    placementCount: placementCount,
                    activePlacementCount: activePlacementCount,
                    childCount: childCount
                )

                if isExpandable {
                    Button {
                        onToggleExpand()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.risoInk)
                            .frame(width: 26, height: 26)
                            .risoCard(radius: Riso.cardRadius, keyline: Riso.Keyline.dense, fill: .risoPaper2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isExpanded
                            ? "Collapse subtasks of \(task.title)"
                            : "Expand subtasks of \(task.title)"
                    )
                }
            }

            // ── Nested children ────────────────────────────────────────
            if isExpanded && !children.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(children, id: \.link.id) { pair in
                        if let child = pair.task {
                            Button {
                                onChildTap(child.id)
                            } label: {
                                HStack(spacing: 0) {
                                    // Dashed left connector
                                    dashedConnector
                                    RisoTaskRowView(
                                        task: child,
                                        placementCount: childPlacementCounts[child.id] ?? 0,
                                        activePlacementCount: childActivePlacementCounts[child.id] ?? 0,
                                        childCount: 0
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Dashed connector

    /// Vertical dashed rule + small horizontal bar connecting child rows
    /// to their parent — the "indented dashed" style shown in the prototype.
    private var dashedConnector: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 24)
            Canvas { ctx, size in
                let inkColor = GraphicsContext.Shading.color(Color.risoMuted.opacity(0.5))
                // Vertical dashed line
                let vPath = Path { p in
                    p.move(to: CGPoint(x: 8, y: 0))
                    p.addLine(to: CGPoint(x: 8, y: size.height))
                }
                ctx.stroke(vPath, with: inkColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                // Horizontal jog to row
                let hPath = Path { p in
                    p.move(to: CGPoint(x: 8, y: size.height / 2))
                    p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                ctx.stroke(hPath, with: inkColor, style: StrokeStyle(lineWidth: 1.5))
            }
            .allowsHitTesting(false)
        }
        .frame(width: 24)
    }
}
