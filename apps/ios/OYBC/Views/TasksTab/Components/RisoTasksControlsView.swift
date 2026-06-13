import SwiftUI

/// Riso-styled Tasks-tab filter controls.
///
/// Three rows:
///  1. Riso search field (paper2 bg, ink border, magnifier icon, clear ✕).
///  2. Type chips: All / Normal / Counting / Compound / Achievement
///     (`RisoChip`, drive `typeFilter`).
///  3. Sort row: "SORT" label + Recent / Most used / A–Z chips + live
///     result count. Chip selection maps to `TasksTabSort` cases.
///
/// Secondary filters (Status / Usage / Show expired / Group by compound)
/// stay reachable behind a "Filters" disclosure — the expanded panel is
/// Riso-card-styled (paper2 bg, 2px keyline).
///
/// Mirrors `proto/tabs.jsx` `TasksTab` controls region + the existing
/// `TasksFilterControlsView` secondary panel.
struct RisoTasksControlsView: View {
    @Binding var search: String
    @Binding var typeFilter: TasksTabTypeFilter
    @Binding var statusFilter: TasksTabStatusFilter
    @Binding var usageFilter: TasksTabUsageFilter
    @Binding var sortBy: TasksTabSort
    @Binding var showExpired: Bool
    @Binding var groupByCompound: Bool
    let resultCount: Int

    @State private var filtersExpanded: Bool = false

    // Default secondary values — used for "any filters active" dot badge.
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

    // MARK: - Sort chip model

    private struct SortOption {
        let label: String
        let sortValue: TasksTabSort
    }

    /// Three sort options the spec shows as chips (Recent / Most used / A–Z).
    private let sortOptions: [SortOption] = [
        SortOption(label: "Recent", sortValue: .updatedDesc),
        SortOption(label: "Most used", sortValue: .mostUsedDesc),
        SortOption(label: "A–Z", sortValue: .titleAsc),
    ]

    private var sortLabelIsOneOfThree: Bool {
        sortOptions.map { $0.sortValue }.contains(sortBy)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. Search field
            searchField

            // 2. Type chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TasksTabTypeFilter.allCases) { filter in
                        RisoChip(
                            title: filter.rawValue,
                            isOn: typeFilter == filter
                        ) {
                            typeFilter = filter
                        }
                    }
                }
                .padding(.horizontal, 1) // prevent clipping of keyline
            }

            // 3. Sort row + result count
            sortRow

            // 4. Filters disclosure (secondary)
            HStack {
                filtersToggle
                Spacer(minLength: 0)
            }

            if filtersExpanded {
                secondaryPanel
            }
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.risoMuted)
            TextField("Search tasks…", text: $search)
                .font(.risoBody(14, .regular))
                .foregroundStyle(Color.risoInk)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.risoMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .risoCard(keyline: Riso.Keyline.dense)
    }

    // MARK: - Sort row

    private var sortRow: some View {
        HStack(spacing: 8) {
            Text("SORT")
                .risoSectionLabel()
            ForEach(sortOptions, id: \.label) { opt in
                RisoChip(
                    title: opt.label,
                    isOn: sortBy == opt.sortValue
                ) {
                    sortBy = opt.sortValue
                }
            }
            Spacer(minLength: 0)
            Text("\(resultCount) task\(resultCount == 1 ? "" : "s")")
                .font(.risoBody(12, .medium))
                .foregroundStyle(Color.risoMuted)
        }
    }

    // MARK: - Filters disclosure

    private var filtersToggle: some View {
        Button {
            filtersExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Text("Filters")
                    .font(.risoBody(13, .semibold))
                Image(systemName: filtersExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                if isAnyFilterActive {
                    Circle()
                        .fill(Color.risoBlue)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(Color.risoInk)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .risoCard(keyline: Riso.Keyline.dense)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filtersExpanded ? "Hide filters" : "Show filters")
    }

    // MARK: - Secondary panel

    @ViewBuilder
    private var secondaryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sortMenu
            statusMenu
            usageMenu
            Toggle("Show expired tasks", isOn: $showExpired)
                .font(.risoBody(13, .medium))
                .tint(Color.risoBlue)

            // Group by compound toggle
            Button {
                groupByCompound.toggle()
            } label: {
                HStack(spacing: 6) {
                    if groupByCompound {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text("Group subtasks")
                        .font(.risoBody(13, .medium))
                }
                .foregroundStyle(groupByCompound ? Color.risoBlue : Color.risoMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(groupByCompound
                ? "Group subtasks, on. Tap to show flat list."
                : "Group subtasks, off. Tap to group subtasks under parents.")
            .accessibilityAddTraits(.isToggle)

            if isAnyFilterActive {
                Button {
                    sortBy = Self.defaultSort
                    statusFilter = Self.defaultStatus
                    usageFilter = Self.defaultUsage
                    showExpired = Self.defaultShowExpired
                } label: {
                    Text("Clear all")
                        .font(.risoBody(13, .bold))
                        .foregroundStyle(Color.risoBlue)
                        .underline()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: Riso.Keyline.dense)
    }

    // MARK: - Menu helpers

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
            menuChipLabel(prefix: "Sort", value: sortBy.rawValue)
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
            menuChipLabel(prefix: "Status", value: statusFilter.rawValue)
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
            menuChipLabel(prefix: "Usage", value: usageFilter.rawValue)
        }
    }

    private func menuChipLabel(prefix: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(prefix)
                .risoSectionLabel()
            Text(value)
                .font(.risoBody(13, .medium))
                .foregroundStyle(Color.risoBlue)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.risoBlue)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .risoCard(keyline: Riso.Keyline.dense)
    }
}
