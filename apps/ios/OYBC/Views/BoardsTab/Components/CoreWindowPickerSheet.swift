import SwiftUI

/// Half-sheet window picker opened from the pager's window chip.
///
/// Paper background, 2.5pt ink top keyline, 22pt top radii, custom
/// grabber. Header: timeframe kicker + "Jump to a month" + the page
/// chip. Body: a calendar-aligned tile grid (per-timeframe layouts —
/// DAILY = 7-column month calendar, WEEKLY = quarter rows, MONTHLY =
/// 4-column year grid, YEARLY = 4-column decade grid). Footer:
/// `‹ 2025 · Today · September · 2027 ›` page stepper.
///
/// Tapping a tile dismisses and lands the pager on that window — empty
/// windows get the setup prompt; **no board row is ever created here**
/// (lazy creation, CLAUDE.md §Recurring Boards).
///
/// Pure presentation — tiles come from `CoreWindowPicker.buildPage`
/// over a `boardsByStart` lookup the caller supplies. Mirrors the web
/// `CoreWindowPickerPopover`.
struct CoreWindowPickerSheet: View {
    let timeframe: Timeframe
    let weekStartDay: String
    /// Core boards for this timeframe keyed by `startDate`.
    let boardsByStart: [String: Board]
    /// The pager's displayed window start — seeds the initial page.
    let displayedWindowStart: String
    /// Reference instant for current/past flags. Injectable for snapshots.
    var now: Date = Date()
    /// Tile tap — the pager lands on this window.
    let onSelect: (String) -> Void

    @State private var pageStart: Date

    init(
        timeframe: Timeframe,
        weekStartDay: String,
        boardsByStart: [String: Board],
        displayedWindowStart: String,
        now: Date = Date(),
        onSelect: @escaping (String) -> Void
    ) {
        self.timeframe = timeframe
        self.weekStartDay = weekStartDay
        self.boardsByStart = boardsByStart
        self.displayedWindowStart = displayedWindowStart
        self.now = now
        self.onSelect = onSelect
        let seed = parseISO8601Date(displayedWindowStart) ?? now
        _pageStart = State(initialValue: CoreWindowPicker.pageStart(timeframe: timeframe, containing: seed))
    }

    private var page: CoreWindowPicker.Page {
        CoreWindowPicker.buildPage(
            timeframe: timeframe,
            pageStart: pageStart,
            boardsByStart: boardsByStart,
            now: now,
            weekStartDay: weekStartDay
        )
    }

    var body: some View {
        let copy = CoreWindowPicker.pickerCopy(timeframe: timeframe)
        let page = self.page

        VStack(spacing: 16) {
            // Custom grabber (44×5, hairline ink).
            Capsule()
                .fill(Color.risoInk.opacity(0.14))
                .frame(width: 44, height: 5)
                .padding(.top, 12)

            // Header: kicker + title, page chip at right.
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(copy.kicker)
                        .risoKicker()
                    Text(copy.title)
                        .risoH2()
                }
                Spacer(minLength: 8)
                RisoChip(title: page.title, isOn: true, action: {})
                    .allowsHitTesting(false)
            }

            // Body: per-timeframe tile layout.
            ScrollView(showsIndicators: false) {
                tileGrid(page: page)
            }

            // Footer: page stepper + Today.
            HStack {
                Button {
                    pageStart = CoreWindowPicker.stepPage(timeframe: timeframe, pageStart: pageStart, step: -1)
                } label: {
                    Text("‹ \(page.prevTitle)")
                        .font(.risoBody(12, .bold))
                        .foregroundStyle(Color.risoMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous page")

                Spacer()

                Button {
                    pageStart = CoreWindowPicker.pageStart(timeframe: timeframe, containing: now)
                } label: {
                    Text(CoreWindowPicker.todayLabel(timeframe: timeframe, now: now))
                        .font(.risoHead(12, .bold))
                        .foregroundStyle(Color.risoInk)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    pageStart = CoreWindowPicker.stepPage(timeframe: timeframe, pageStart: pageStart, step: 1)
                } label: {
                    Text("\(page.nextTitle) ›")
                        .font(.risoBody(12, .bold))
                        .foregroundStyle(Color.risoMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next page")
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, Riso.gutter)
        .background(RisoPaperBackground().ignoresSafeArea())
        .overlay(
            // 2.5pt ink top keyline along the sheet's top edge.
            Rectangle()
                .fill(Color.risoInk)
                .frame(height: 2.5)
                .ignoresSafeArea(edges: .horizontal),
            alignment: .top
        )
    }

    // MARK: - Tile grid

    @ViewBuilder
    private func tileGrid(page: CoreWindowPicker.Page) -> some View {
        switch timeframe {
        case .daily:
            dailyGrid(page: page)
        case .weekly:
            VStack(spacing: 8) {
                ForEach(page.tiles) { tile in
                    tileButton(tile, rowLayout: true)
                }
            }
        default:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(page.tiles) { tile in
                    tileButton(tile, rowLayout: false)
                }
            }
        }
    }

    /// DAILY: weekday header + leading blanks + day tiles, 7 columns.
    @ViewBuilder
    private func dailyGrid(page: CoreWindowPicker.Page) -> some View {
        let heads = weekStartDay == "sunday"
            ? ["S", "M", "T", "W", "T", "F", "S"]
            : ["M", "T", "W", "T", "F", "S", "S"]
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(Array(heads.enumerated()), id: \.offset) { _, head in
                Text(head)
                    .font(.risoBody(9, .bold))
                    .foregroundStyle(Color.risoMuted)
            }
            ForEach(0..<page.leadingBlanks, id: \.self) { _ in
                Color.clear.frame(height: 40)
            }
            ForEach(page.tiles) { tile in
                tileButton(tile, rowLayout: false, compact: true)
            }
        }
    }

    // MARK: - Tile

    /// One window tile per the spec's six-state table.
    @ViewBuilder
    private func tileButton(
        _ tile: CoreWindowPicker.Tile,
        rowLayout: Bool,
        compact: Bool = false
    ) -> some View {
        let style = tileStyle(tile.state)

        Button {
            onSelect(tile.windowStart)
        } label: {
            Group {
                if rowLayout {
                    HStack(spacing: 6) {
                        Text(tile.label)
                            .font(.risoHead(13, .extraBold))
                        Spacer(minLength: 4)
                        stateRow(tile, style: style)
                    }
                } else if compact {
                    VStack(spacing: 3) {
                        Text(tile.label)
                            .font(.risoHead(13, .extraBold))
                        if tile.state != .futureEmpty {
                            stateDot(style)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tile.label)
                            .font(.risoHead(13, .extraBold))
                        if tile.state != .futureEmpty {
                            stateRow(tile, style: style)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(style.label)
            .padding(compact ? 6 : 10)
            .background(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .fill(style.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(
                        style.border,
                        style: StrokeStyle(
                            lineWidth: Riso.Keyline.container,
                            dash: style.dashed ? [5, 4] : []
                        )
                    )
            )
            .background(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .fill(tile.state == .current ? Color.risoInk : Color.clear)
                    .offset(x: 3, y: 3)
            )
            .opacity(tile.state == .futureEmpty ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tileA11yLabel(tile))
    }

    /// State row: 7pt dot (1.5pt keyline) + Archivo 9 bold uppercase.
    @ViewBuilder
    private func stateRow(_ tile: CoreWindowPicker.Tile, style: TileStyle) -> some View {
        HStack(spacing: 4) {
            stateDot(style)
            Text(stateText(tile).uppercased())
                .font(.risoBody(9, .bold))
                .tracking(0.7)
        }
        .foregroundStyle(style.stateText)
    }

    @ViewBuilder
    private func stateDot(_ style: TileStyle) -> some View {
        Circle()
            .fill(style.dotFill)
            .overlay(Circle().strokeBorder(style.dotBorder, lineWidth: 1.5))
            .frame(width: 7, height: 7)
    }

    // MARK: - Tile styling (six-state table)

    private struct TileStyle {
        let fill: Color
        let border: Color
        let dashed: Bool
        let label: Color
        let stateText: Color
        let dotFill: Color
        let dotBorder: Color
    }

    private func tileStyle(_ state: CoreWindowPicker.TileState) -> TileStyle {
        switch state {
        case .closed:
            return TileStyle(
                fill: .risoPaper2, border: .risoInk, dashed: false,
                label: .risoInk, stateText: .risoMuted,
                dotFill: .risoRed, dotBorder: .risoRed
            )
        case .done:
            return TileStyle(
                fill: .risoPaper2, border: .risoInk, dashed: false,
                label: .risoInk, stateText: .risoMuted,
                dotFill: .risoGreen, dotBorder: .risoGreen
            )
        case .pastEmpty:
            return TileStyle(
                fill: .clear, border: .risoMuted, dashed: true,
                label: .risoMuted, stateText: .risoMuted,
                dotFill: .clear, dotBorder: .risoMuted
            )
        case .current:
            // Gold tile — ink-static content (never adaptive ink on gold).
            return TileStyle(
                fill: .risoGold, border: .risoInkStatic, dashed: false,
                label: .risoInkStatic, stateText: .risoInkStatic,
                dotFill: .risoBlue, dotBorder: .risoBlue
            )
        case .nextEmpty:
            return TileStyle(
                fill: .risoPaper2, border: .risoInk, dashed: true,
                label: .risoInk, stateText: .risoMuted,
                dotFill: .clear, dotBorder: .risoInk
            )
        case .futureEmpty:
            return TileStyle(
                fill: .clear, border: .risoMuted, dashed: true,
                label: .risoMuted, stateText: .risoMuted,
                dotFill: .clear, dotBorder: .clear
            )
        case .inProgress:
            return TileStyle(
                fill: .risoPaper2, border: .risoInk, dashed: false,
                label: .risoInk, stateText: .risoMuted,
                dotFill: .risoBlue, dotBorder: .risoBlue
            )
        case .draft:
            return TileStyle(
                fill: .risoPaper2, border: .risoInk, dashed: false,
                label: .risoInk, stateText: .risoMuted,
                dotFill: .risoMuted, dotBorder: .risoMuted
            )
        }
    }

    /// State word shown on a tile ("closed" / "done" / "set up" / …).
    private func stateText(_ tile: CoreWindowPicker.Tile) -> String {
        switch tile.state {
        case .closed: return "closed"
        case .done: return "done"
        case .pastEmpty: return "no board"
        case .current:
            if let done = tile.progressDone, let total = tile.progressTotal {
                return "\(done) of \(total)"
            }
            return "set up"
        case .nextEmpty: return "set up"
        case .futureEmpty: return ""
        case .inProgress:
            if let done = tile.progressDone, let total = tile.progressTotal {
                return "\(done) of \(total)"
            }
            return "open"
        case .draft: return "draft"
        }
    }

    private func tileA11yLabel(_ tile: CoreWindowPicker.Tile) -> String {
        let label = formatTimeframeLabel(
            timeframe: timeframe,
            startDate: parseISO8601Date(tile.windowStart) ?? now
        )
        let state = stateText(tile)
        return state.isEmpty ? label : "\(label), \(state)"
    }
}
