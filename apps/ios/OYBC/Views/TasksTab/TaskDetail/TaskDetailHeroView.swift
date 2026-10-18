import SwiftUI

/// The type-coloured hero band (frames 2a / 4a–4c): nav row, kicker, 32pt title,
/// description and the type's one live control. Pure props — `TaskDetailViewModel`
/// builds the model. Web twin: `pages/tasks/taskDetailHero/`.
struct TaskDetailHeroView: View {

    let model: TaskDetailModel
    var strip: SquareLogStrip? = nil
    var isBusy = false
    /// Whether the dimmed busy look shows (only after `BusyLook.delay`); nil follows `isBusy`.
    var busyLook: Bool? = nil
    var presentation: TaskDetailPresentation = .route
    var actions = TaskDetailActions()
    /// Snapshot seam: a compound's counting child opened on appear.
    var initialOpenChildId: String? = nil
    /// Snapshot seam: opens an amount entry on appear.
    var initialEntry: SquareSheetEntry? = nil

    @State private var openChildId: String?
    @State private var entry: SquareSheetEntry?

    init(
        model: TaskDetailModel, strip: SquareLogStrip? = nil, isBusy: Bool = false, busyLook: Bool? = nil,
        presentation: TaskDetailPresentation = .route, actions: TaskDetailActions = TaskDetailActions(),
        initialOpenChildId: String? = nil, initialEntry: SquareSheetEntry? = nil
    ) {
        self.model = model
        self.strip = strip
        self.isBusy = isBusy
        self.busyLook = busyLook
        self.presentation = presentation
        self.actions = actions
        _openChildId = State(initialValue: initialOpenChildId)
        _entry = State(initialValue: initialEntry)
    }

    /// The 45% busy look — delayed behind `BusyLook.delay`; the controls themselves go inert at once.
    private var looksBusy: Bool { busyLook ?? isBusy }

    // MARK: - Palette

    private var isDark: Bool { model.kind != .normal }
    private var bg: Color {
        switch model.kind {
        case .counting: return .risoBlue
        case .compound: return .risoTeal
        case .achievement: return .risoAchievement
        case .normal: return .risoPaper2
        }
    }
    private var fg: Color { isDark ? .risoOnColor : .risoInk }
    private var sub: Color { isDark ? .risoLavender : .risoMuted }
    private var border: Color { isDark ? .risoInkStatic : .risoInk }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            navRow
            VStack(alignment: .leading, spacing: 0) {
                Text(model.kicker.uppercased())
                    .font(.risoHead(12, .bold))
                    .tracking(2.64)
                    .foregroundStyle(sub)
                Text(model.title)
                    .font(.risoHead(32, .extraBold))
                    .tracking(-0.96)
                    .lineSpacing(0)
                    .foregroundStyle(fg)
                    .padding(.top, 6)
                if let description = model.description {
                    Text(description)
                        .font(.risoBody(13, .medium))
                        .foregroundStyle(sub)
                        .padding(.top, 8)
                }
                heroBody
            }
            .padding(.horizontal, Riso.gutter)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(border).frame(height: 2) }
    }

    // MARK: - Nav row

    private var navRow: some View {
        HStack(spacing: 10) {
            switch presentation {
            case .route:
                Button(action: actions.onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(fg)
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            case let .sheet(returnTo):
                if let returnTo {
                    RisoReturnPill(title: returnTo.title, kind: returnTo.kind, border: border, action: actions.onReturn)
                }
            }
            Spacer(minLength: 0)
            optionsMenu
            if presentation.isSheet {
                Button(action: actions.onDone) {
                    Text("Done")
                        .font(.risoHead(13, .extraBold))
                        .foregroundStyle(Color.risoInkStatic)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(Capsule().fill(Color.risoGold))
                        .overlay(Capsule().strokeBorder(border, lineWidth: Riso.Keyline.container))
                }
                .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: 999))
            }
        }
        .padding(.leading, presentation == .route ? 12 : Riso.gutter)
        .padding(.trailing, Riso.gutter)
        .padding(.top, presentation.isSheet ? 22 : 0)
        .frame(minHeight: 44)
    }

    /// The ⋯ menu: Open counter settings (counting with a counter) · Delete task….
    /// "Place on a board…" is omitted — no placement flow is reachable from here.
    private var optionsMenu: some View {
        Menu {
            if model.kind == .counting, model.counter != nil {
                Button("Open counter settings", systemImage: "slider.horizontal.3", action: actions.onOpenCounterSettings)
                Divider()
            }
            Button("Delete task…", systemImage: "trash", role: .destructive, action: actions.onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.risoPaper2))
                .overlay(Circle().strokeBorder(border, lineWidth: Riso.Keyline.container))
                .background(Circle().fill(border).offset(x: Riso.Shadow.small, y: Riso.Shadow.small))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Task options")
    }

    // MARK: - Body per type

    @ViewBuilder
    private var heroBody: some View {
        switch model.hero {
        case .none:
            HStack { Spacer(); editButton }.padding(.top, 18)
        case let .counting(count):
            countingBody(count)
        case let .boardlessCounting(count):
            countingBody(count, boardless: true)
        case let .normal(isDone, sealBlocked):
            normalBody(isDone: isDone, sealBlocked: sealBlocked)
        case let .compound(compound, rule):
            compoundBody(compound, rule: rule)
        case let .achievement(a):
            achievementBody(a)
        }
    }

    private var editButton: some View {
        RisoButton(title: "Edit", kind: .neutral, action: actions.onEdit)
    }

    private func stripView(scope: String, compact: Bool) -> some View {
        Group {
            if let strip, strip.scopeTaskId == scope {
                UndoStrip(text: strip.text, compact: compact, disabled: isBusy, busyLook: looksBusy, onUndo: actions.onUndo)
            }
        }
    }

    private func pill(_ status: RisoStatusPill.Status?) -> some View {
        Group { if let status { RisoStatusPill(status: status) } }
    }

    // MARK: Counting

    /// - Parameter boardless: No square in play — the all-time count with no goal,
    ///   bar or rest line (binding decision 3 (4)).
    private func countingBody(_ count: SquareSheetContent.ChildCount, boardless: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(formatCount(count.current, kind: count.kind))
                    .font(.risoHead(SquareSheetFormat.heroCountSize(count.kind), .extraBold))
                    .tracking(-1)
                    .monospacedDigit()
                    .foregroundStyle(fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(boardless ? TaskDetailViewModel.allTime : SquareSheetFormat.countLine(goal: count.goal, unit: count.unit, kind: count.kind, board: model.anchorName ?? ""))
                    .font(.risoHead(14, .bold))
                    .foregroundStyle(sub)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if !boardless { pill(SquareSheetFormat.countStatus(current: count.current, goal: count.goal)) }
            }
            .padding(.top, 18)

            if !boardless {
                HeroBar(value: count.goal > 0 ? min(count.current, count.goal) / count.goal : 0, height: 12, keyline: fg)
                    .padding(.top, 12)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("TAP TO LOG").font(.risoBody(9, .bold)).tracking(1).foregroundStyle(sub)
                Spacer()
                if !boardless, let rest = SquareSheetFormat.restLine(current: count.current, goal: count.goal, kind: count.kind, board: model.anchorName ?? "") {
                    Text(rest).font(.risoBody(11, .semibold)).foregroundStyle(sub)
                }
            }
            .padding(.top, 16)

            TapLogChipRow(chips: count.chips, disabled: isBusy, busyLook: looksBusy, onColor: true) { chip in
                if let value = chip.value {
                    actions.onLog(model.taskId, value, false)
                } else {
                    entry = SquareSheetEntry(scopeTaskId: model.taskId, isRemove: false)
                }
            }
            .padding(.top, 8)

            if let open = entry, open.scopeTaskId == model.taskId {
                SquareSheetEntryRow(kind: count.kind, unit: count.unit, isRemove: open.isRemove, onSubmit: { amount in
                    entry = nil
                    if open.isRemove { actions.onRemove(model.taskId, amount) } else { actions.onLog(model.taskId, amount, true) }
                }, onCancel: { entry = nil })
                .padding(.top, 10)
            }
            stripView(scope: model.taskId, compact: false).padding(.top, 10)

            HStack {
                Button { entry = SquareSheetEntry(scopeTaskId: model.taskId, isRemove: true) } label: {
                    Text(count.kind == .discrete && !count.unit.isEmpty ? "− Remove \(count.unit)…" : "− Remove…")
                        .font(.risoHead(12, .bold))
                        .foregroundStyle(sub)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy || count.current <= 0)
                .opacity(looksBusy || count.current <= 0 ? 0.45 : 1)
                Spacer()
                editButton
            }
            .padding(.top, 8)

            counterRow
        }
    }

    /// Shared counter (on colour) / Counts toward (on paper) → Counter Detail.
    @ViewBuilder
    private var counterRow: some View {
        if let c = model.counter {
            Button { actions.onOpenCounter(c.counterId) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.label.uppercased()).font(.risoBody(9, .bold)).tracking(1).foregroundStyle(sub)
                        Text(c.name).font(.risoHead(15, .extraBold)).foregroundStyle(isDark ? Color.risoOnColor : Color.risoInk).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Text(c.total).font(.risoHead(15, .extraBold)).monospacedDigit()
                            .foregroundStyle(isDark ? Color.risoOnColor : Color.risoBlue)
                        Text("all-time").font(.risoBody(11, .semibold)).foregroundStyle(sub)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(sub)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(isDark ? Color.clear : Color.risoPaper))
                .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(isDark ? Color.risoOnColor : Color.risoInk, lineWidth: Riso.Keyline.dense))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the \(c.name) counter")
            .padding(.top, 14)
        }
    }

    // MARK: Normal

    private func normalBody(isDone: Bool, sealBlocked: Bool) -> some View {
        let anchorTimeframe = model.anchorName == nil ? nil : model.anchorTimeframe
        return VStack(alignment: .leading, spacing: 0) {
            Text(TaskDetailFormat.normalStatus(isDone: isDone, timeframe: anchorTimeframe).uppercased())
                .font(.risoHead(9, .bold))
                .tracking(0.45)
                .foregroundStyle(isDone ? Color.risoPaper : Color.risoMuted)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Capsule().fill(isDone ? Color.risoGreen : Color.risoPaper))
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                .padding(.top, 18)
            HStack(spacing: 10) {
                RisoButton(title: isDone ? "Done" : "Mark done", kind: isDone ? .green : .gold, systemImage: "checkmark", fullWidth: true, action: actions.onMarkDone)
                    .disabled(isBusy || (isDone && sealBlocked))
                    .opacity(looksBusy || (isDone && sealBlocked) ? 0.45 : 1)
                editButton
            }
            .padding(.top, 14)
            stripView(scope: model.taskId, compact: false).padding(.top, 10)
            counterRow
        }
    }

    // MARK: Compound

    private func compoundBody(_ compound: SquareSheetContent.Compound, rule: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(compound.doneCount)")
                    .font(.risoHead(52, .extraBold)).tracking(-1).monospacedDigit().foregroundStyle(fg)
                Text(SquareSheetFormat.subtaskLine(total: compound.children.count, board: model.anchorName ?? ""))
                    .font(.risoHead(14, .bold)).foregroundStyle(sub).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                pill(SquareSheetFormat.compoundStatus(doneCount: compound.doneCount, isComplete: compound.isComplete))
            }
            .padding(.top, 18)

            HStack(spacing: 4) {
                ForEach(compound.children) { child in
                    Capsule()
                        .fill(child.isDone ? Color.risoGold : Color.clear)
                        .frame(height: 12)
                        .overlay(Capsule().strokeBorder(fg, lineWidth: Riso.Keyline.container))
                }
            }
            .padding(.top, 12)

            Text("SUB-TASKS · \(rule.uppercased())")
                .font(.risoBody(9, .bold)).tracking(1).foregroundStyle(sub)
                .padding(.top, 16)

            VStack(spacing: 6) {
                ForEach(compound.children) { child in childRow(child) }
            }
            .padding(.top, 8)

            HStack { Spacer(); editButton }.padding(.top, 12)
        }
    }

    private func childRow(_ child: SquareSheetContent.Child) -> some View {
        let isOpen = openChildId == child.id && child.counting != nil
        let locked = isBusy || (child.isDone && child.sealBlocked)
        let looksLocked = looksBusy || (child.isDone && child.sealBlocked)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    if child.counting != nil { openChildId = isOpen ? nil : child.id } else { actions.onToggleChild(child.id) }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(child.isDone ? Color.risoOnColor : (isOpen ? Color.risoGold : Color.clear))
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoOnColor, lineWidth: Riso.Keyline.container)
                        if child.isDone {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.risoTeal)
                        } else if child.counting != nil {
                            Text("+").font(.risoHead(16, .extraBold)).foregroundStyle(isOpen ? Color.risoInkStatic : Color.risoOnColor)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(child.counting == nil && locked)
                .opacity(child.counting == nil && looksLocked ? 0.45 : 1)
                .accessibilityLabel(SquareSheetFormat.childBoxLabel(child, isOpen: isOpen))
                RisoTypeBadge(kind: child.kind, style: .letterSquare)
                Button { actions.onOpenTask(child.id) } label: {
                    HStack(spacing: 6) {
                        Text(child.title)
                            .font(.risoHead(14, .bold))
                            .foregroundStyle(Color.risoOnColor)
                            .opacity(child.isDone ? 0.75 : 1)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let count = child.counting {
                            Text(count.meta).font(.risoBody(11, .semibold)).monospacedDigit().foregroundStyle(Color.risoLavender).fixedSize()
                        }
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.risoLavender)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(child.title)")
            }
            .padding(.vertical, 8)
            .padding(.leading, 10)
            .padding(.trailing, 8)

            if isOpen, let count = child.counting {
                VStack(alignment: .leading, spacing: 8) {
                    HeroBar(value: count.goal > 0 ? min(count.current, count.goal) / count.goal : 0, height: 8, keyline: Color.risoOnColor)
                    TapLogChipRow(chips: count.chips, size: .compact, disabled: isBusy, busyLook: looksBusy, onColor: true) { chip in
                        if let value = chip.value { actions.onLog(child.id, value, false) } else {
                            entry = SquareSheetEntry(scopeTaskId: child.id, isRemove: false)
                        }
                    }
                    if let open = entry, open.scopeTaskId == child.id {
                        SquareSheetEntryRow(kind: count.kind, unit: count.unit, isRemove: false, compact: true, onSubmit: { amount in
                            entry = nil
                            actions.onLog(child.id, amount, true)
                        }, onCancel: { entry = nil })
                    }
                    stripView(scope: child.id, compact: true)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Color.risoOnColor.opacity(0.35)).frame(height: 1.5) }
            }
            if child.counting == nil { stripView(scope: child.id, compact: true).padding(.horizontal, 10).padding(.bottom, 8) }
        }
        .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoOnColor, lineWidth: Riso.Keyline.dense))
    }

    // MARK: Achievement

    private func achievementBody(_ a: TaskDetailModel.AchievementHero) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if a.card.isMet { RisoStatusPill(status: .done) } else { SquareSheetBadge(text: "Watching") }
            }
            .padding(.top, 18)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("WATCHED BOARD").font(.risoBody(9, .bold)).tracking(1).foregroundStyle(sub)
                    if let badge = a.card.timeframeBadge {
                        Text(badge.uppercased())
                            .font(.risoHead(9, .bold)).tracking(0.45)
                            .foregroundStyle(Color.risoOnColor)
                            .padding(.vertical, 1).padding(.horizontal, 6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoOnColor, lineWidth: Riso.Keyline.dense))
                    }
                    Spacer(minLength: 4)
                    if let days = a.card.daysLeft { Text(days).font(.risoBody(11, .semibold)).foregroundStyle(sub) }
                }
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(a.card.watchedName ?? "Board unavailable")
                        .font(.risoHead(22, .extraBold)).tracking(-0.4).foregroundStyle(Color.risoOnColor)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text(a.card.progress).font(.risoHead(14, .extraBold)).monospacedDigit().foregroundStyle(Color.risoOnColor).fixedSize()
                }
                if let line = a.closestLine {
                    HStack(spacing: 8) {
                        Text("Closest line · \(line.done) of \(line.cells.count)")
                            .font(.risoBody(11, .semibold)).foregroundStyle(sub).lineLimit(1)
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            ForEach(Array(a.lineCells.enumerated()), id: \.offset) { _, done in
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(done ? Color.risoGold : Color.risoPaper)
                                    .frame(width: 22, height: 22)
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.risoInkStatic, lineWidth: Riso.Keyline.dense))
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoOnColor, lineWidth: Riso.Keyline.dense))
            .padding(.top, 14)

            HStack(spacing: 10) {
                if let id = a.card.openBoardId, let name = a.card.watchedName {
                    RisoButton(title: "Open \(name)", kind: .gold, fullWidth: true) { actions.onOpenBoard(id) }
                } else {
                    Spacer(minLength: 0)
                }
                editButton
            }
            .padding(.top, 14)
        }
    }
}

/// The hero's bar: a transparent track with a keyline and a gold fill.
struct HeroBar: View {
    let value: Double
    let height: CGFloat
    let keyline: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.clear)
                Rectangle().fill(Color.risoGold).frame(width: max(0, min(1, value)) * geo.size.width)
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(keyline, lineWidth: height >= 12 ? Riso.Keyline.container : Riso.Keyline.dense))
        }
        .frame(height: height)
    }
}
