import SwiftUI

/// Profile-home "SHARED COUNTERS" section (design handoff §1.4) — a section
/// label with a trailing "All {n} ›" link, then either up to 2 compact
/// counter rows (`SharedCounterLedgerCard(compact: true)`) in one shared
/// card, or the dashed empty state.
///
/// Pure-props leaf — no environment, no DB — so `ProfileView` owns loading /
/// the "+ Log" write / sheet presentation and this stays snapshot-testable
/// in isolation (same convention as `CountersHubContent` / `StreaksContent`).
struct ProfileCountersSection: View {
    /// Up to 2 groups, most-recently-logged first (`ProfileHomeViewModel`
    /// already truncates — this view just renders what it's given).
    let groups: [SharedCounterGroup]
    /// Total live counter count (unfiltered by the 2-row cap) — drives the
    /// "All {n} ›" link. The link itself hides when there are no counters
    /// at all (matching the Hub's own header convention).
    let totalCount: Int
    var loggingCounterIds: Set<String> = []
    let onOpenHub: () -> Void
    let onOpenDetail: (String) -> Void
    let onNewCounter: () -> Void
    let onLog: (SharedCounterGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Riso.gutter)
                .padding(.bottom, 8)

            if groups.isEmpty {
                emptyCard
                    .padding(.horizontal, Riso.gutter)
            } else {
                populatedCard
                    .padding(.horizontal, Riso.gutter)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("SHARED COUNTERS")
                .risoSectionLabel()
            Spacer()
            if totalCount > 0 {
                Button(action: onOpenHub) {
                    Text("All \(totalCount) ›")
                        .font(.risoBody(12, .bold))
                        .foregroundStyle(Color.risoBlue)
                        // 12pt text is well under the 44pt HIG minimum: lay
                        // the hit shape on a padded frame, then give the
                        // padding back so the header's layout is unchanged
                        // (same trick as ProfileView's gear button).
                        .padding(.vertical, 14)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                        .padding(.vertical, -14)
                        .padding(.horizontal, -12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All \(totalCount) counters")
            }
        }
    }

    // MARK: - Populated card

    private var populatedCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { rowDivider }
                SharedCounterLedgerCard(
                    group: group,
                    isLogging: loggingCounterIds.contains(group.counterId),
                    onOpenDetail: { onOpenDetail(group.counterId) },
                    onLog: { onLog(group) },
                    compact: true
                )
            }
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    private var rowDivider: some View {
        Divider()
            .background(Color.risoInk.opacity(0.12))
            .padding(.horizontal, Riso.cardPadding)
    }

    // MARK: - Empty state

    private var emptyCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                emptySquare(fill: .risoPaper)
                emptySquare(fill: .risoBlue)
                emptySquare(fill: .risoPaper)
            }

            Text("One tally, many squares")
                .font(.risoHead(15, .extraBold))
                .foregroundStyle(Color.risoInk)

            RisoButton(title: "New counter", kind: .blue, small: true) {
                onNewCounter()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, Riso.cardPadding)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(
                    Color.risoInk.opacity(0.45),
                    style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [6, 4])
                )
        )
    }

    private func emptySquare(fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(fill)
            .frame(width: 26, height: 26)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }
}

#if DEBUG
#Preview("Populated") {
    let a = SharedCounterGroup(
        counterId: "a", name: "Push-ups", action: "Do", unit: "reps",
        lifetime: 512, tasks: [], taskCount: 2, boardCount: 2, activeTaskCount: 2
    )
    let b = SharedCounterGroup(
        counterId: "b", name: "Pages read", action: "Read", unit: "pages",
        lifetime: 1240, tasks: [], taskCount: 1, boardCount: 1, activeTaskCount: 1
    )
    return ZStack {
        RisoPaperBackground()
        ProfileCountersSection(
            groups: [a, b], totalCount: 3,
            onOpenHub: {}, onOpenDetail: { _ in }, onNewCounter: {}, onLog: { _ in }
        )
        .padding(.vertical, 20)
    }
}

#Preview("Empty") {
    ZStack {
        RisoPaperBackground()
        ProfileCountersSection(
            groups: [], totalCount: 0,
            onOpenHub: {}, onOpenDetail: { _ in }, onNewCounter: {}, onLog: { _ in }
        )
        .padding(.vertical, 20)
    }
}
#endif
