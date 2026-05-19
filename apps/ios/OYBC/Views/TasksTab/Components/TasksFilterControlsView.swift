import SwiftUI

/// Tasks-tab filter controls — two primary rows (search + type chips)
/// stay visible; Sort / Status / Usage tuck behind a "Filters"
/// disclosure button so the default state doesn't crowd the page
/// above the library. A dot badge on the disclosure indicates when
/// any secondary filter is non-default; the expanded panel exposes a
/// "Clear all" button that resets them in one tap.
///
/// Mirrors web's `TasksFilterControls.tsx`.
struct TasksFilterControlsView: View {
    @Binding var search: String
    @Binding var typeFilter: TasksTabTypeFilter
    @Binding var statusFilter: TasksTabStatusFilter
    @Binding var usageFilter: TasksTabUsageFilter
    @Binding var sortBy: TasksTabSort
    /// Phase 6.Y — Timeboxed Tasks toggle. False (the default) hides
    /// tasks whose `endDate < now`; toggle reveals them.
    @Binding var showExpired: Bool

    @State private var isExpanded: Bool = false

    private static let defaultSort: TasksTabSort = .updatedDesc
    private static let defaultStatus: TasksTabStatusFilter = .any
    private static let defaultUsage: TasksTabUsageFilter = .any
    private static let defaultShowExpired: Bool = false

    private var isAnyFilterActive: Bool {
        sortBy != Self.defaultSort
            || statusFilter != Self.defaultStatus
            || usageFilter != Self.defaultUsage
            || showExpired != Self.defaultShowExpired
    }

    private var typeTabs: [FilterTab] {
        TasksTabTypeFilter.allCases.map { FilterTab(value: $0.rawValue, label: $0.rawValue) }
    }

    private var typeFilterRaw: Binding<String> {
        Binding(
            get: { typeFilter.rawValue },
            set: { newValue in
                if let next = TasksTabTypeFilter(rawValue: newValue) {
                    typeFilter = next
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                searchField
                Spacer(minLength: 0)
                disclosureButton
            }

            FilterTabsView(
                tabs: typeTabs,
                activeTab: typeFilterRaw,
                onTabChange: { _ in }
            )

            if isExpanded {
                expandedPanel
            }
        }
    }

    // MARK: - Top row

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search tasks…", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var disclosureButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("Filters")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                if isAnyFilterActive {
                    // 6pt dot badge to flag a non-default secondary
                    // filter; matches the web `.badge` element.
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide filters" : "Show filters")
    }

    // MARK: - Expanded panel

    @ViewBuilder
    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sortMenu
            statusMenu
            usageMenu
            Toggle("Show expired tasks", isOn: $showExpired)
                .font(.system(size: 13))
            if isAnyFilterActive {
                Button {
                    sortBy = Self.defaultSort
                    statusFilter = Self.defaultStatus
                    usageFilter = Self.defaultUsage
                    showExpired = Self.defaultShowExpired
                } label: {
                    Text("Clear all")
                        .font(.system(size: 13, weight: .semibold))
                        .underline()
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(TasksTabSort.allCases) { option in
                Button {
                    sortBy = option
                } label: {
                    if option == sortBy {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            chipLabel(prefix: "Sort", value: sortBy.rawValue)
        }
    }

    private var statusMenu: some View {
        Menu {
            ForEach(TasksTabStatusFilter.allCases) { option in
                Button {
                    statusFilter = option
                } label: {
                    if option == statusFilter {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            chipLabel(prefix: "Status", value: statusFilter.rawValue)
        }
    }

    private var usageMenu: some View {
        Menu {
            ForEach(TasksTabUsageFilter.allCases) { option in
                Button {
                    usageFilter = option
                } label: {
                    if option == usageFilter {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            chipLabel(prefix: "Usage", value: usageFilter.rawValue)
        }
    }

    private func chipLabel(prefix: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(prefix).font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Text(value).font(.system(size: 13, weight: .medium))
                .foregroundColor(.blue)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.blue)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
