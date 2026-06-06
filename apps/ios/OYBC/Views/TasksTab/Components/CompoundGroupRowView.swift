import SwiftUI

/// Tasks-tab compound-group row. Renders a compound parent with a
/// leading disclosure chevron; when expanded, indented child rows
/// appear below it. Mirrors the `<li>` + nested `<ul>` structure in
/// web's `TasksPage.tsx` (Issue #73).
///
/// The view is intentionally non-interactive itself — the caller
/// (`TasksTabView`) still wraps the parent row in a `Button` for
/// navigation and supplies swipe-action handlers for edit / delete.
/// This view only owns the expand/collapse affordance and the child
/// layout.
struct CompoundGroupRowView: View {
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
        VStack(alignment: .leading, spacing: 0) {
            // ── Parent row with optional disclosure chevron ───────────
            HStack(spacing: 0) {
                if isExpandable {
                    Button {
                        onToggleExpand()
                    } label: {
                        Image(
                            systemName: isExpanded ? "chevron.down" : "chevron.right"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isExpanded
                            ? "Collapse subtasks of \(task.title)"
                            : "Expand subtasks of \(task.title)"
                    )
                }
                // The TaskRowView itself; the caller wraps this entire
                // `CompoundGroupRowView` in a Button for navigation.
                TaskRowView(
                    task: task,
                    placementCount: placementCount,
                    activePlacementCount: activePlacementCount,
                    childCount: childCount
                )
            }

            // ── Nested children (single level only — Issue #73) ───────
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(children, id: \.link.id) { pair in
                        if let child = pair.task {
                            Button {
                                onChildTap(child.id)
                            } label: {
                                TaskRowView(
                                    task: child,
                                    placementCount: childPlacementCounts[child.id] ?? 0,
                                    activePlacementCount: childActivePlacementCounts[child.id] ?? 0,
                                    // Grandchild count shown but not recursively expandable
                                    // (single-level rule, Issue #73).
                                    childCount: 0
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 6)
            }
        }
    }
}
