import SwiftUI

// MARK: - Ledger card (Counters Hub)

/// A single counter card in the Counters Hub "Ledger" layout.
///
/// Layout (mirrors the design handoff `cn-led` card):
/// - Top row: counter name + unit tag left; big blue lifetime + "all-time {unit}" right.
/// - One `SharedCounterMemberRow` per ACTIVE member task.
/// - Dashed divider.
/// - Footer meta: "Shared by N tasks · N boards" + "Open ›" affordance.
///
/// Tapping the card (anywhere) triggers `onTap` — the Hub routes to CounterDetailView.
struct SharedCounterLedgerCard: View {
    let group: SharedCounterGroup
    let onTap: () -> Void

    // MARK: - Derived

    private var activeMembers: [SharedCounterMemberTask] {
        group.tasks.filter { $0.isActive }
    }

    private var unitLabel: String { group.unit ?? "units" }

    // MARK: - Body

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Top row: name + unit tag / lifetime number
                HStack(alignment: .top, spacing: 10) {
                    // Left: name + unit tag
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.name)
                            .font(.risoHead(16, .bold))
                            .foregroundStyle(Color.risoInk)
                            .lineLimit(1)

                        if let action = group.action {
                            Text("\(action) · \(unitLabel)")
                                .font(.risoBody(11, .semibold))
                                .foregroundStyle(Color.risoMuted)
                        }
                    }

                    Spacer(minLength: 8)

                    // Right: big blue lifetime + "all-time {unit}"
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(group.lifetime)")
                            .font(.risoHead(28, .extraBold))
                            .foregroundStyle(Color.risoBlue)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text("all-time \(unitLabel)")
                            .font(.risoBody(10, .semibold))
                            .foregroundStyle(Color.risoMuted)
                    }
                }
                .padding(.horizontal, Riso.cardPadding)
                .padding(.top, Riso.cardPadding)

                // Member task rows (active only)
                if !activeMembers.isEmpty {
                    Divider()
                        .background(Color.risoInk.opacity(0.12))
                        .padding(.horizontal, Riso.cardPadding)
                        .padding(.top, 10)

                    ForEach(activeMembers) { member in
                        SharedCounterMemberRow(member: member, unit: unitLabel)
                    }
                }

                // Dashed divider before footer
                dashedDivider
                    .padding(.horizontal, Riso.cardPadding)
                    .padding(.top, 10)

                // Footer: "Shared by N tasks · N boards" / "Open ›"
                HStack(spacing: 6) {
                    Text("Shared by \(group.taskCount) task\(group.taskCount == 1 ? "" : "s") · \(group.boardCount) board\(group.boardCount == 1 ? "" : "s")")
                        .font(.risoBody(11, .regular))
                        .foregroundStyle(Color.risoMuted)

                    Spacer(minLength: 4)

                    Text("Open ›")
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoBlue)
                }
                .padding(.horizontal, Riso.cardPadding)
                .padding(.top, 8)
                .padding(.bottom, Riso.cardPadding)
            }
        }
        .buttonStyle(.plain)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name), \(group.lifetime) all-time \(unitLabel), \(group.taskCount) tasks on \(group.boardCount) boards")
    }

    // MARK: - Dashed divider

    private var dashedDivider: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay(
                GeometryReader { geo in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0.5))
                        path.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
                    }
                    .stroke(
                        Color.risoInk.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
                }
            )
    }
}

// MARK: - Member row (used inside the Ledger card)

/// One active-member row in a `SharedCounterLedgerCard`.
///
/// Layout: `[dot] [board name + window label]  [logged/goal]`
///          [thin progress bar across the full width]
struct SharedCounterMemberRow: View {
    let member: SharedCounterMemberTask
    let unit: String

    // MARK: - Derived

    private var progressFraction: Double {
        guard member.goal > 0 else { return 1.0 }
        return min(1.0, Double(member.logged) / Double(member.goal))
    }

    private var progressColor: Color {
        member.met ? .risoGreen : .risoBlue
    }

    private var loggedLabel: String {
        "\(member.logged)/\(member.goal)"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // Timeframe accent dot
                Circle()
                    .fill(member.timeframe?.risoColor ?? Color.risoMuted)
                    .frame(width: 8, height: 8)

                // Board name + window
                VStack(alignment: .leading, spacing: 1) {
                    Text(member.boardName ?? "–")
                        .font(.risoBody(12, .bold))
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)

                    if let window = member.window {
                        Text(window)
                            .font(.risoBody(10, .regular))
                            .foregroundStyle(Color.risoMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                // Logged / goal
                Text(loggedLabel)
                    .font(.risoHead(13, .bold))
                    .foregroundStyle(member.met ? Color.risoGreen : Color.risoInk)
            }

            // Thin progress bar
            RisoProgressBar(value: progressFraction, color: progressColor, height: 5)
        }
        .padding(.horizontal, Riso.cardPadding)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(member.boardName ?? "no board"), \(member.logged) of \(member.goal) \(unit)\(member.met ? ", goal met" : "")"
        )
    }
}
