import SwiftUI

// MARK: - Ledger card (Counters Hub)

/// A single counter card in the Counters Hub "Ledger" layout (R2 Counters UX
/// refresh — design handoff §Counters Hub).
///
/// Layout:
///   Top row:  counter name (left, Bricolage 800/21) | big blue lifetime +
///             "ALL-TIME" label (right)
///   Rows:     one row per ACTIVE member task (dot + board · window,
///             logged/goal, full-width progress bar)
///   Footer:   dashed divider · "N tasks · N boards" · "+ Log" pill (blue) ·
///             muted "›" chevron
///
/// The WHOLE card is tappable → Detail (`onOpenDetail`), except the "+ Log"
/// pill, which is a genuinely distinct tap target (`onLog`) that logs the
/// counter's current default amount (`group.defaultLogAmount ?? 1`) in
/// place — one tap, no chip picker (that lives on Detail).
///
/// Nested-tap-target note: the card body drives navigation via
/// `.onTapGesture` on the whole card rather than wrapping it in a `Button`
/// or `NavigationLink` — a `Button`'s label containing another `Button`
/// swallows the inner one's taps, but a `Button` nested inside an ancestor's
/// `.onTapGesture` keeps receiving its own taps (SwiftUI resolves the tap to
/// the most specific/deepest recognizer). This is what lets the "+ Log"
/// pill act independently of the card-wide "open detail" tap.
struct SharedCounterLedgerCard: View {
    let group: SharedCounterGroup
    /// Disables the "+ Log" pill while a log write is in flight for this counter.
    var isLogging: Bool = false
    /// Fired by a tap anywhere on the card EXCEPT the "+ Log" pill.
    let onOpenDetail: () -> Void
    /// Fired by the "+ Log" pill — logs `group.defaultLogAmount ?? 1`.
    let onLog: () -> Void

    // MARK: - Derived

    private var activeMembers: [SharedCounterMemberTask] {
        group.tasks.filter { $0.isActive }
    }

    private var unitLabel: String { group.unit ?? "" }
    private var logAmount: Int { group.defaultLogAmount ?? 1 }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: name + lifetime
            HStack(alignment: .top, spacing: 10) {
                Text(group.name)
                    .font(.risoHead(21, .extraBold))
                    .tracking(-0.42)
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(group.lifetime.formatted())
                        .font(.risoHead(26, .extraBold))
                        .foregroundStyle(Color.risoBlue)
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("ALL-TIME")
                        .font(.risoBody(9, .bold))
                        .tracking(0.9)
                        .foregroundStyle(Color.risoMuted)
                }
            }
            .padding(.horizontal, Riso.cardPadding)
            .padding(.top, 15)

            // Active member task rows
            if !activeMembers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(activeMembers) { member in
                        SharedCounterMemberRow(member: member, unit: unitLabel)
                    }
                }
                .padding(.top, 10)
            }

            // Dashed divider before footer
            dashedDivider
                .padding(.horizontal, Riso.cardPadding)
                .padding(.top, 12)

            // Footer: "N tasks · N boards" · "+ Log" pill · "›" chevron
            HStack(spacing: 10) {
                Text("\(group.taskCount) task\(group.taskCount == 1 ? "" : "s") · \(group.boardCount) board\(group.boardCount == 1 ? "" : "s")")
                    .font(.risoBody(11, .regular))
                    .foregroundStyle(Color.risoMuted)

                Spacer(minLength: 6)

                Button(action: onLog) {
                    Text("+ Log")
                        .font(.risoHead(12, .extraBold))
                        .foregroundStyle(Color.risoPaper)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        .background(Capsule().fill(Color.risoBlue))
                        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                }
                .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: 999))
                .disabled(isLogging)
                .accessibilityLabel("Log \(logAmount) \(unitLabel) for \(group.name)")

                Text("›")
                    .font(.risoHead(14, .bold))
                    .foregroundStyle(Color.risoMuted)
            }
            .padding(.horizontal, Riso.cardPadding)
            .padding(.top, 10)
            .padding(.bottom, Riso.cardPadding)
        }
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.card, radius: Riso.cardRadius)
        .contentShape(Rectangle())
        .onTapGesture { onOpenDetail() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name), \(group.lifetime) all-time \(unitLabel), \(group.taskCount) tasks on \(group.boardCount) boards")
        .accessibilityAddTraits(.isButton)
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
        "\(member.logged.formatted())/\(member.goal.formatted())"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // Timeframe accent dot
                Circle()
                    .fill(member.timeframe?.risoColor ?? Color.risoMuted)
                    .frame(width: 9, height: 9)

                // Board name + window (one line: "Board · window")
                Text(member.window.map { "\(member.boardName ?? "–") · \($0)" } ?? (member.boardName ?? "–"))
                    .font(.risoBody(11, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)

                Spacer(minLength: 6)

                // Logged / goal
                Text(loggedLabel)
                    .font(.risoHead(12, .bold))
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
