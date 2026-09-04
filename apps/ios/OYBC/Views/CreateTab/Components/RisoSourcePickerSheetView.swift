import SwiftUI

/// "Add a pool or board" bottom sheet (Board Sources P2 —
/// docs/BOARD_SOURCES.md §Surfaces item 2; handoff frames 2c/5c).
///
/// Search across POOLS and BOARDS sections (name match, case-insensitive;
/// a section with no matches is hidden), tap-to-toggle rows with a check
/// circle (ink fill + paper ✓ when pulled), and the empty state ("Nothing
/// to pull from yet" + dashed mini-grid) when neither pools nor boards
/// exist. Chrome follows `PoolPickerSheetView` (grab handle, title + Done
/// row) with `RisoLibrarySheetView`'s search-field pattern.
///
/// Props/callback-driven; the Tasks step wires the toggles to
/// `BoardWizardViewModel.pullPool` / `pullBoard` / `removeSource`.
struct RisoSourcePickerSheetView: View {
    struct BoardEntry: Identifiable {
        let board: Board
        let squares: Int
        let done: Int
        var id: String { board.id }
    }

    let pools: [Pool]
    let boards: [BoardEntry]
    let pulledSourceIds: Set<String>
    let onTogglePool: (Pool) -> Void
    let onToggleBoard: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isEmptyStore: Bool { pools.isEmpty && boards.isEmpty }
    private var matchingPools: [Pool] {
        guard !trimmedQuery.isEmpty else { return pools }
        return pools.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
    }
    private var matchingBoards: [BoardEntry] {
        guard !trimmedQuery.isEmpty else { return boards }
        return boards.filter { $0.board.name.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    var body: some View {
        VStack(spacing: 14) {
            grabber
            header
            searchField
                .opacity(isEmptyStore ? 0.5 : 1)
                .disabled(isEmptyStore)
            if isEmptyStore {
                emptyState
            } else if matchingPools.isEmpty && matchingBoards.isEmpty {
                noMatches
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        if !matchingPools.isEmpty {
                            sectionKicker("POOLS")
                            ForEach(matchingPools, id: \.id) { pool in
                                poolRow(pool)
                            }
                        }
                        if !matchingBoards.isEmpty {
                            sectionKicker("BOARDS")
                                .padding(.top, matchingPools.isEmpty ? 0 : 7)
                            ForEach(matchingBoards) { entry in
                                boardRow(entry)
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .padding(.horizontal, 20)
        .background(Color.risoPaper.ignoresSafeArea())
        .presentationDetents([.fraction(0.76)])
    }

    // MARK: - Chrome

    private var grabber: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.risoInk.opacity(0.35))
            .frame(width: 38, height: 4)
    }

    private var header: some View {
        HStack {
            Text("Add a pool or board")
                .font(.risoHead(20, .extraBold))
                .foregroundStyle(Color.risoInk)
            Spacer()
            RisoButton(title: "Done", kind: .primary, small: true) { dismiss() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.risoMuted)
            TextField("Search pools and boards", text: $query)
                .font(.risoHead(15, .bold))
                .foregroundStyle(Color.risoInk)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.risoInk)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
    }

    private func sectionKicker(_ label: String) -> some View {
        Text(label)
            .font(.risoBody(11, .bold))
            .kerning(1.1)
            .foregroundStyle(Color.risoMuted)
    }

    // MARK: - Rows

    private func poolRow(_ pool: Pool) -> some View {
        sourceRow(
            letter: "P",
            letterFill: .risoInk,
            letterForeground: .risoPaper,
            name: pool.name,
            subtitle: "\(pool.taskIds.count) task\(pool.taskIds.count == 1 ? "" : "s")",
            isOn: pulledSourceIds.contains(pool.id)
        ) { onTogglePool(pool) }
    }

    private func boardRow(_ entry: BoardEntry) -> some View {
        sourceRow(
            letter: "B",
            letterFill: .risoGold,
            letterForeground: .risoInkStatic,
            name: entry.board.name,
            subtitle: "\(entry.squares) square\(entry.squares == 1 ? "" : "s") · \(entry.done) done",
            isOn: pulledSourceIds.contains(entry.board.id)
        ) { onToggleBoard(entry.board.id) }
    }

    private func sourceRow(
        letter: String,
        letterFill: Color,
        letterForeground: Color,
        name: String,
        subtitle: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .fill(letterFill)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Text(letter)
                            .font(.risoBody(11, .extraBold))
                            .foregroundStyle(letterForeground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cellRadius)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.risoBody(14, .bold))
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.risoBody(10.5, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Circle()
                    .fill(isOn ? Color.risoInk : Color.clear)
                    .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.risoPaper)
                            .opacity(isOn ? 1 : 0)
                    )
                    .frame(width: 26, height: 26)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(subtitle)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Empty / no-match states

    private var noMatches: some View {
        VStack(spacing: 4) {
            Text("No pools or boards match \u{201C}\(trimmedQuery)\u{201D}")
                .font(.risoHead(15, .bold))
                .foregroundStyle(Color.risoInk)
                .multilineTextAlignment(.center)
            Text("Try another word, or add tasks from your library.")
                .font(.risoBody(11, .semibold))
                .foregroundStyle(Color.risoMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            miniGrid
            Text("Nothing to pull from yet")
                .font(.risoHead(16, .extraBold))
                .foregroundStyle(Color.risoInk)
            Text("Boards you make and pools you save will show up here.")
                .font(.risoBody(12, .semibold))
                .foregroundStyle(Color.risoMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    /// 3×3 dashed placeholder grid with a gold center — frame 5c.
    private var miniGrid: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { col in
                        RoundedRectangle(cornerRadius: Riso.cellRadius)
                            .strokeBorder(
                                Color.risoInk.opacity(0.35),
                                style: StrokeStyle(lineWidth: Riso.Keyline.dense, dash: [4, 3])
                            )
                            .background(
                                RoundedRectangle(cornerRadius: Riso.cellRadius)
                                    .fill(row == 1 && col == 1 ? Color.risoGold : Color.clear)
                            )
                            .frame(width: 26, height: 26)
                    }
                }
            }
        }
    }
}
