import SwiftUI

/// Search + type-chip-row + (status / usage / sort) controls for the
/// Tasks tab. Layout is stacked rather than a single row so it stays
/// readable on phone widths. Mirrors web's `TasksFilterControls.tsx`.
struct TasksFilterControlsView: View {
    @Binding var search: String
    @Binding var typeFilter: TasksTabTypeFilter
    @Binding var statusFilter: TasksTabStatusFilter
    @Binding var usageFilter: TasksTabUsageFilter
    @Binding var sortBy: TasksTabSort

    private var typeTabs: [FilterTab] {
        TasksTabTypeFilter.allCases.map { FilterTab(value: $0.rawValue, label: $0.rawValue) }
    }

    /// `FilterTabsView` takes a `Binding<String>` because that's how it
    /// works for the wizard's filter row. We bridge from the enum
    /// binding through a computed property so the API surface stays the
    /// same.
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
                sortMenu
            }

            FilterTabsView(
                tabs: typeTabs,
                activeTab: typeFilterRaw,
                onTabChange: { _ in }
            )

            HStack(spacing: 12) {
                statusMenu
                usageMenu
                Spacer(minLength: 0)
            }
        }
    }

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
            HStack(spacing: 4) {
                Text("Sort: \(sortBy.rawValue)")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.blue)
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
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
