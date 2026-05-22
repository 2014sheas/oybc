import SwiftUI

/// Prev / label / next navigation bar for the core-board window pager,
/// with a trailing list button that opens the full browser.
///
/// Prev and next paging is always enabled (unbounded — the user can
/// page as far into the past or future as they like). The label
/// reflects the current window (e.g. "Today", "Week of May 18 – 24").
///
/// Mirrors the web `CoreBoardWindowBar` component.
struct CoreBoardWindowBarView: View {
    let label: String
    let onPrev: () -> Void
    let onNext: () -> Void
    let onOpenList: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPrev) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
            }
            .accessibilityLabel("Previous window")

            Spacer()

            Text(label)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
            }
            .accessibilityLabel("Next window")

            Button(action: onOpenList) {
                Label("List", systemImage: "list.bullet")
            }
            .accessibilityLabel("Show all windows")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
