import SwiftUI

/// The square sheet (docs/TASK_DETAIL_REDESIGN.md §Square sheet): the one
/// surface a tap on a Counting / Compound / Achievement square opens — and a
/// Normal square's "Details". A pure-props leaf: the presenter in
/// `BoardPlayView+SquareSheet.swift` builds `content` from the live board.
/// Web twin: `components/boardPlay/squareSheet/SquareSheet.tsx`.
struct SquareSheetView: View {

    let content: SquareSheetContent
    var strip: SquareLogStrip? = nil
    var actions = SquareSheetActions()
    /// Snapshot seam: a compound's counting child opened on appear.
    var initialOpenChildId: String? = nil

    @State private var entry: SquareSheetEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 14)
            ScrollView(showsIndicators: false) {
                bodyContent
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 34)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.risoPaper)
        .overlay(alignment: .top) { Rectangle().fill(Color.risoInk).frame(height: Riso.Keyline.container) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                RisoTypeBadge(kind: content.kind, style: .letterSquare, size: 22)
                Text(content.title)
                    .font(.risoHead(18, .extraBold))
                    .tracking(-0.36)
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { actions.onOpenLibrary(content.taskId) } label: {
                    HStack(spacing: 4) {
                        Text("Library")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                    .font(.risoHead(12, .bold))
                    .foregroundStyle(Color.risoInk)
                    .padding(.vertical, 6)
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
                    .background(Capsule().fill(Color.risoPaper2))
                    .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open in library")
            }
            if content.closed != nil {
                HStack(spacing: 8) {
                    Text(content.boardName)
                        .font(.risoHead(12, .bold))
                        .foregroundStyle(Color.risoMuted)
                    SquareSheetBadge(text: "Closed", systemImage: "lock.fill")
                }
                .padding(.leading, 32)
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyContent: some View {
        switch content.body {
        case let .normal(isDone, sealBlocked):
            normalBody(isDone: isDone, sealBlocked: sealBlocked)
        case let .counting(count):
            SquareSheetCountingView(content: content, count: count, strip: strip, entry: $entry, actions: actions)
        case let .compound(compound):
            SquareSheetCompoundView(content: content, compound: compound, strip: strip, entry: $entry, actions: actions, initialOpenChildId: initialOpenChildId)
        case let .achievement(achievement):
            SquareSheetAchievementView(achievement: achievement, actions: actions)
        }
    }

    /// Normal: reached through "View Details". A status pill and the Mark done / Done button.
    @ViewBuilder
    private func normalBody(isDone: Bool, sealBlocked: Bool) -> some View {
        HStack {
            if isDone { RisoStatusPill(status: .done) } else { SquareSheetBadge(text: "Not done") }
            Spacer()
        }
        .padding(.top, 14)

        if let closed = content.closed {
            SquareSheetClosedRow(closed: closed, onLateLog: actions.onLateLog)
                .padding(.top, 14)
        } else {
            RisoButton(
                title: isDone ? "Done" : "Mark done",
                kind: isDone ? .green : .gold,
                systemImage: "checkmark",
                fullWidth: true,
                action: actions.onMarkDone
            )
            .disabled(content.isBusy || (isDone && sealBlocked))
            .opacity(content.isBusy || (isDone && sealBlocked) ? 0.45 : 1)
            .padding(.top, 14)
        }
    }
}
