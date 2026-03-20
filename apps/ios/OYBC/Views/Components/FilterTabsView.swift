import SwiftUI

/// A single tab definition for `FilterTabsView`.
struct FilterTab {
    /// Underlying value used for comparison and callbacks.
    let value: String
    /// Human-readable label displayed on the button.
    let label: String
}

/// Horizontal pill-button group for filtering lists.
///
/// Active tab is rendered with a filled blue background; inactive tabs
/// show an outlined pill. Mirrors the web `FilterTabs` component in
/// `FilterTabs.tsx`.
///
/// - Parameters:
///   - tabs: Array of tab definitions with value and display label.
///   - activeTab: Binding to the currently selected tab value.
///   - onTabChange: Called with the new tab value when a tab is tapped.
struct FilterTabsView: View {

    // MARK: - Parameters

    let tabs: [FilterTab]
    @Binding var activeTab: String
    let onTabChange: (String) -> Void

    // MARK: - Body

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs, id: \.value) { tab in
                    let isActive = activeTab == tab.value
                    Button {
                        activeTab = tab.value
                        onTabChange(tab.value)
                    } label: {
                        Text(tab.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(isActive ? .white : .blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isActive ? Color.blue : Color.clear)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.blue, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isActive ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 1) // hairline space so stroke is not clipped
        }
    }
}

#Preview {
    struct Preview: View {
        @State private var active = "all"
        var body: some View {
            FilterTabsView(
                tabs: [
                    FilterTab(value: "all", label: "All"),
                    FilterTab(value: "normal", label: "Normal"),
                    FilterTab(value: "counting", label: "Counting"),
                    FilterTab(value: "progress", label: "Progress"),
                    FilterTab(value: "composite", label: "Composite"),
                ],
                activeTab: $active,
                onTabChange: { _ in }
            )
            .padding()
        }
    }
    return Preview()
}
