import SwiftUI

/// The segmented section bodies under the hero: All (overview with "›" jumps), Boards,
/// Links, Activity. Pure props. Web twin: `pages/tasks/taskDetailSections/`.
struct TaskDetailSectionsView: View {

    let model: TaskDetailModel
    @Binding var tab: TaskDetailTab
    var actions = TaskDetailActions()

    var body: some View {
        VStack(spacing: 14) {
            RisoSegmented(
                options: [
                    (TaskDetailTab.all, "All"),
                    (.boards, "Boards · \(model.boardCount)"),
                    (.links, "Links"),
                    (.activity, "Activity"),
                ],
                selection: $tab, equalWidth: false, style: .pill
            )
            switch tab {
            case .all: overview
            case .boards: boardsTab
            case .links: linksTab
            case .activity: activityCard(full: true)
            }
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Cards

    private func card<Content: View>(
        _ label: String, keyline: CGFloat = Riso.Keyline.dense, jump: (String, TaskDetailTab)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).risoSectionLabel()
                Spacer()
                if let jump {
                    Button { tab = jump.1 } label: {
                        HStack(spacing: 2) {
                            Text(jump.0)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                        .font(.risoHead(12, .bold))
                        .foregroundStyle(Color.risoBlue)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: keyline)
    }

    private func linkChip(_ link: TaskDetailModel.Link) -> some View {
        Button { actions.onOpenTask(link.id) } label: {
            HStack(spacing: 5) {
                RisoTypeBadge(kind: link.kind, style: .letterSquare)
                Text(link.title).font(.risoBody(12, .semibold)).foregroundStyle(Color.risoInk).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.risoMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .risoCard(keyline: Riso.Keyline.dense, fill: .risoPaper)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - All

    @ViewBuilder
    private var overview: some View {
        boardsCard(showJump: true)
        if !model.parents.isEmpty {
            card("Subtask of", jump: ("All links", .links)) {
                FlowLayout(spacing: 6) { ForEach(model.parents) { linkChip($0) } }
            }
        }
        activityCard(full: false)
    }

    // MARK: - Boards

    private func boardsCard(showJump: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("On boards now · \(model.activeBoards.count)").risoSectionLabel()
                Spacer()
                if showJump {
                    Button { tab = .boards } label: {
                        HStack(spacing: 2) { Text("All boards"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                            .font(.risoHead(12, .bold)).foregroundStyle(Color.risoBlue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            if model.activeBoards.isEmpty {
                Text("Not on a board")
                    .font(.risoBody(13, .semibold)).foregroundStyle(Color.risoMuted)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(Color.risoInk.opacity(0.14)).frame(height: 1.5) }
            }
            ForEach(model.activeBoards) { boardRow($0, past: false) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: Riso.Keyline.container)
    }

    private func boardRow(_ row: TaskDetailModel.BoardRow, past: Bool) -> some View {
        Button { actions.onOpenBoard(row.id) } label: {
            HStack(spacing: 12) {
                ProgressRing(row: row)
                VStack(alignment: .leading, spacing: past ? 2 : 3) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.risoHead(past ? 14 : 15, past ? .bold : .extraBold))
                            .foregroundStyle(Color.risoInk).lineLimit(1)
                        if let badge = row.badge, !past {
                            Text(badge.uppercased())
                                .font(.risoHead(9, .bold)).tracking(0.45).foregroundStyle(Color.risoMuted)
                                .padding(.vertical, 1).padding(.horizontal, 6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.risoPaper))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                                .fixedSize()
                        }
                    }
                    Text(row.caption).font(.risoBody(past ? 11 : 12, .semibold)).foregroundStyle(Color.risoMuted).lineLimit(2)
                }
                Spacer(minLength: 4)
                if row.isDraft {
                    Text("DRAFT").font(.risoHead(9, .bold)).tracking(0.45).foregroundStyle(Color.risoMuted)
                        .padding(.vertical, 2).padding(.horizontal, 7)
                        .overlay(Capsule().strokeBorder(Color.risoMuted, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
                } else if let value = row.value {
                    HStack(spacing: 0) {
                        Text(value).foregroundStyle(row.isDone && row.valueSub == nil ? Color.risoGreen : (row.valueSub == nil ? Color.risoMuted : Color.risoInk))
                        if let sub = row.valueSub { Text(sub).foregroundStyle(Color.risoMuted) }
                    }
                    .font(.risoHead(14, .extraBold)).monospacedDigit().lineLimit(1).fixedSize()
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.risoMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, past ? 11 : 12)
            .background(past ? Color.risoPaper : Color.clear)
            .overlay(alignment: .top) { Rectangle().fill(Color.risoInk.opacity(0.14)).frame(height: 1.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open board \(row.name)")
    }

    @ViewBuilder
    private var boardsTab: some View {
        VStack(spacing: 0) {
            boardsCard(showJump: false)
        }
        if !model.pastBoards.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Past & drafts · \(model.pastBoards.count)").risoSectionLabel()
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.risoPaper)
                ForEach(model.pastBoards) { boardRow($0, past: true) }
            }
            .risoCard(keyline: Riso.Keyline.container, fill: .risoPaper)
        }
    }

    // MARK: - Links

    private func subtasksCard(showJump: Bool) -> some View {
        card(
            "Sub-tasks (\(model.subtasks.count))" + (model.subtaskRule.map { " · \($0)" } ?? ""),
            jump: showJump ? ("All links", .links) : nil
        ) {
            VStack(spacing: 5) {
                ForEach(model.subtasks) { child in
                    Button { actions.onOpenTask(child.id) } label: {
                        HStack(spacing: 8) {
                            RisoTypeBadge(kind: child.kind, style: .letterSquare)
                            Text(child.title).font(.risoBody(13, .medium)).foregroundStyle(Color.risoInk).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if child.isDone { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Color.risoGreen) }
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.risoMuted)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .risoCard(keyline: Riso.Keyline.dense, fill: .risoPaper)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func watchesCard(_ link: TaskDetailModel.Link, showJump: Bool) -> some View {
        card(model.watchesHeading, jump: showJump ? ("All links", .links) : nil) {
            Button {
                if let id = model.watchedBoardId { actions.onOpenBoard(id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3").font(.system(size: 13)).foregroundStyle(Color.risoMuted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.title).font(.risoBody(13, .semibold)).foregroundStyle(Color.risoInk)
                        if let meta = model.watchesMeta { Text(meta).font(.risoBody(11, .semibold)).foregroundStyle(Color.risoMuted) }
                    }
                    Spacer(minLength: 4)
                    if model.watchedBoardId != nil {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.risoMuted)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .risoCard(keyline: Riso.Keyline.dense, fill: .risoPaper)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.watchedBoardId == nil)
        }
    }

    @ViewBuilder
    private var linksTab: some View {
        if let c = model.counter {
            card(c.label) {
                Button { actions.onOpenCounter(c.counterId) } label: {
                    HStack(spacing: 10) {
                        RisoTypeBadge(kind: .counting, style: .letterSquare)
                        Text(c.name).font(.risoBody(14, .semibold)).foregroundStyle(Color.risoInk).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(c.unit.isEmpty ? c.total : "\(c.total) \(c.unit)")
                            .font(.risoHead(14, .bold)).foregroundStyle(Color.risoBlue).lineLimit(1).fixedSize()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.risoMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open the \(c.name) counter")
            }
        }
        if !model.parents.isEmpty {
            card("Subtask of") { FlowLayout(spacing: 6) { ForEach(model.parents) { linkChip($0) } } }
        }
        if !model.subtasks.isEmpty { subtasksCard(showJump: false) }
        if let watches = model.watches { watchesCard(watches, showJump: false) }
        if !model.templates.isEmpty {
            card("Part of repeating board") {
                VStack(spacing: 5) {
                    ForEach(model.templates) { t in
                        HStack(spacing: 8) {
                            Image(systemName: "repeat").font(.system(size: 12)).foregroundStyle(Color.risoMuted)
                            Text(t.name).font(.risoBody(13, .medium)).foregroundStyle(Color.risoInk).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .risoCard(keyline: Riso.Keyline.dense, fill: .risoPaper)
                    }
                }
            }
        }
        if model.counter == nil, model.parents.isEmpty, model.subtasks.isEmpty, model.watches == nil, model.templates.isEmpty {
            Text("No links").font(.risoBody(13, .semibold)).foregroundStyle(Color.risoMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Activity

    private func activityCard(full: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").risoSectionLabel()
                Spacer()
                if !full {
                    Button { tab = .activity } label: {
                        HStack(spacing: 2) { Text("Full activity"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                            .font(.risoHead(12, .bold)).foregroundStyle(Color.risoBlue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, full ? 6 : 4)
            if full {
                ForEach(model.activity) { line in
                    HStack(spacing: 10) {
                        Circle().fill(Self.dot(line.kind)).frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                        Text(line.text).font(.risoBody(13, .semibold)).foregroundStyle(Color.risoInk).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(line.when).font(.risoBody(11, .semibold)).foregroundStyle(Color.risoMuted).fixedSize()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .overlay(alignment: .top) { Rectangle().fill(Color.risoInk.opacity(0.14)).frame(height: 1.5) }
                }
                Text(model.footer)
                    .font(.risoBody(11, .semibold)).foregroundStyle(Color.risoMuted)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.risoPaper)
                    .overlay(alignment: .top) { Rectangle().fill(Color.risoInk).frame(height: 1.5) }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    if let first = model.activity.first { Text(first.text).font(.risoBody(13, .medium)).foregroundStyle(Color.risoInk) }
                    if model.activity.count > 1 { Text(model.activity[1].text).font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted) }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: Riso.Keyline.dense)
    }

    /// Dot colour per activity kind: blue logged / removed, green completed, gold placed,
    /// red missed, paper created.
    static func dot(_ kind: TaskDetailKernel.ActivityKind) -> Color {
        switch kind {
        case .logged, .removed: return .risoBlue
        case .completed: return .risoGreen
        case .placed: return .risoGold
        case .missed: return .risoRed
        case .created: return .risoPaper
        }
    }
}

/// The 24pt placement ring: a gold pie for progress, a green check when done, a dashed outline for a draft.
struct ProgressRing: View {
    let row: TaskDetailModel.BoardRow

    var body: some View {
        ZStack {
            if row.isDone {
                Circle().fill(Color.risoGreen)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.risoOnColor)
            } else if row.isDraft {
                Circle().fill(Color.clear)
            } else {
                Circle().fill(Color.risoPaper)
                PieSlice(fraction: row.fraction).fill(Color.risoGold)
            }
            if row.isDraft {
                Circle().strokeBorder(Color.risoMuted, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            } else {
                Circle().strokeBorder(Color.risoInk, lineWidth: 2)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct PieSlice: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let f = max(0, min(1, fraction))
        guard f > 0 else { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: c)
        p.addArc(center: c, radius: rect.width / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * f), clockwise: false)
        p.closeSubpath()
        return p
    }
}
