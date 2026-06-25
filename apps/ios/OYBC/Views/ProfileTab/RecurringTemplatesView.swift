import SwiftUI

/// RecurringTemplatesView — Riso-styled Profile sub-page listing recurring
/// board templates. Design: §5a README + screenshot 09.
///
/// Each template is a keyline card: name + timeframe color tag + active switch.
/// Tapping a card or the dashed "+ New template" button opens TemplateEditSheet.
/// Paused templates dim the card and show "paused" in the meta line.
struct RecurringTemplatesView: View {

    var onEditTemplate: ((String) -> Void)? = nil

    @EnvironmentObject var authService: AuthService

    @State private var templatesVM = RecurringBoardTemplatesViewModel()
    @State private var pools: [DefaultPool] = []
    @State private var editTarget: TemplateEditTarget?

    enum TemplateEditTarget: Identifiable {
        case new
        case existing(RecurringBoardTemplate)
        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let t): return t.id
            }
        }
    }

    var body: some View {
        ZStack {
            RisoPaperBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    RisoSubPageHeader(title: "Recurring templates")
                        .padding(.top, 16)
                        .padding(.bottom, 16)

                    Text("Templates press a fresh core board each cycle — same pool, reshuffled squares.")
                        .font(.risoBody(13, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 14)

                    if !templatesVM.templates.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(templatesVM.templates, id: \.id) { tpl in
                                templateCard(tpl)
                                    .padding(.horizontal, Riso.gutter)
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    RisoDashedButton(label: "+ New template") { editTarget = .new }
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 16)

                    Text("Pausing a template keeps its pool — it just stops printing new boards.")
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 24)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(item: $editTarget) { target in
            TemplateEditSheet(
                template: { if case .existing(let t) = target { return t }; return nil }(),
                pools: pools,
                onSave: { tpl in saveTemplate(tpl) },
                onDelete: { id in deleteTemplate(id: id) },
                userId: authService.currentUser?.id ?? ""
            )
        }
        .onAppear { reload() }
    }

    // MARK: - Template card

    private func templateCard(_ tpl: RecurringBoardTemplate) -> some View {
        let active = tpl.isActive
        return Button { editTarget = .existing(tpl) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(tpl.name)
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(active ? Color.risoInk : Color.risoMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    timeframeTag(tpl.timeframe)
                    RisoPillSwitch(isOn: toggleBinding(for: tpl))
                }
                HStack(spacing: 4) {
                    Text("\(tpl.boardSize)×\(tpl.boardSize)").font(.risoBody(12, .bold))
                        .foregroundStyle(active ? Color.risoInk : Color.risoMuted)
                    Text("board").font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                    Text("·").foregroundStyle(Color.risoMuted)
                    Text("\(tpl.seedTaskIds.count)").font(.risoBody(12, .bold))
                        .foregroundStyle(active ? Color.risoInk : Color.risoMuted)
                    Text("-task pool").font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                    Text("·").foregroundStyle(Color.risoMuted)
                    Text(active ? "renews \(renewText(tpl))" : "paused")
                        .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                }
            }
            .padding(Riso.cardPadding)
            .risoCard(fill: active ? .risoPaper2 : .risoPaper)
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
            .opacity(active ? 1.0 : 0.7)
        }
        .buttonStyle(.plain)
    }

    private func timeframeTag(_ tf: Timeframe) -> some View {
        Text(tf.risoDisplayName.uppercased())
            .font(.risoHead(9, .bold))
            .tracking(0.4)
            .foregroundStyle(Color.risoPaper)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Capsule().fill(tf.risoColor))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    // MARK: - Binding / actions

    private func toggleBinding(for tpl: RecurringBoardTemplate) -> Binding<Bool> {
        Binding(
            get: { tpl.isActive },
            set: { newValue in
                guard let userId = authService.currentUser?.id else { return }
                let now = AppDatabase.currentTimestamp()
                var updated = tpl; updated.isActive = newValue
                updated.updatedAt = now; updated.version += 1
                _Concurrency.Task.detached {
                    do {
                        try AppDatabase.shared.saveRecurringBoardTemplateAndEnqueue(
                            updated, operation: .update, now: now
                        )
                        await MainActor.run { templatesVM.reloadAsync(userId: userId) }
                    } catch { print("[RecurringTemplatesView] toggle failed: \(error)") }
                }
            }
        )
    }

    private func saveTemplate(_ tpl: RecurringBoardTemplate) {
        guard let userId = authService.currentUser?.id else { return }
        editTarget = nil
        _Concurrency.Task.detached {
            do {
                let now = AppDatabase.currentTimestamp()
                var t = tpl; t.updatedAt = now; t.version += 1
                try AppDatabase.shared.saveRecurringBoardTemplateAndEnqueue(
                    t, operation: t.version <= 2 ? .create : .update, now: now
                )
                await MainActor.run { templatesVM.reloadAsync(userId: userId) }
            } catch { print("[RecurringTemplatesView] saveTemplate failed: \(error)") }
        }
    }

    private func deleteTemplate(id: String) {
        guard let userId = authService.currentUser?.id else { return }
        editTarget = nil
        _Concurrency.Task.detached {
            do {
                try AppDatabase.shared.softDeleteRecurringBoardTemplateAndEnqueue(
                    id: id, now: AppDatabase.currentTimestamp()
                )
                await MainActor.run { templatesVM.reloadAsync(userId: userId) }
            } catch { print("[RecurringTemplatesView] deleteTemplate failed: \(error)") }
        }
    }

    private func reload() {
        guard let userId = authService.currentUser?.id else { return }
        templatesVM.reloadAsync(userId: userId)
        _Concurrency.Task.detached {
            let loaded = try? AppDatabase.shared.fetchDefaultPools(userId: userId)
            await MainActor.run { pools = loaded ?? [] }
        }
    }

    private func renewText(_ tpl: RecurringBoardTemplate) -> String {
        switch tpl.timeframe {
        case .weekly: return "Mondays"
        case .monthly: return "the 1st"
        case .daily: return "every morning"
        case .yearly: return "Jan 1"
        case .custom: return "custom"
        case .indefinite: return "ongoing"
        }
    }
}

// MARK: - TemplateEditSheet

/// Bottom sheet for creating or editing a RecurringBoardTemplate.
/// Design: screenshot 16 / §5a.
struct TemplateEditSheet: View {

    let template: RecurringBoardTemplate?
    let pools: [DefaultPool]
    let onSave: (RecurringBoardTemplate) -> Void
    let onDelete: (String) -> Void
    /// Owner id for newly-created templates. Passed in (rather than read from
    /// `@EnvironmentObject AuthService`) so the sheet stays snapshot-testable.
    let userId: String

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var timeframe: Timeframe = .weekly
    @State private var boardSize: Int = 5
    @State private var weekday: Int = 0
    @State private var monthDom: Int = 0
    @State private var selectedPoolId: String? = nil
    @State private var isActive: Bool = true

    private let weekdayLetters = ["M","T","W","T","F","S","S"]
    private let weekdayNames = ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
    private let domLabels = ["1st","15th","Last"]

    private var isEditMode: Bool { template != nil }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var selectedPool: DefaultPool? { pools.first { $0.id == selectedPoolId } }

    private var previewText: String {
        let sz = "\(boardSize)×\(boardSize)"
        let count = selectedPool?.taskIds.count ?? 0
        let renew: String
        switch timeframe {
        case .weekly: renew = weekdayNames[weekday] + "s"
        case .monthly: renew = domLabels[monthDom]
        case .daily: renew = "every morning"
        case .yearly: renew = "Jan 1"
        case .custom: renew = "custom"
        case .indefinite: renew = "ongoing"
        }
        return "\(sz) board · \(count)-task pool · renews \(renew)"
    }

    var body: some View {
        ZStack { Color.risoPaper.ignoresSafeArea()
            VStack(spacing: 0) {
                grabHandle
                sheetHeader
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        fieldBlock(label: "Name") {
                            RisoTextField(placeholder: "e.g. Weekly Reset", text: $name)
                        }
                        fieldBlock(label: "Timeframe") { timeframeSegmented }
                        fieldBlock(label: "Board size") { boardSizeSegmented }
                        if timeframe == .weekly { fieldBlock(label: "Renews on") { weekdayPicker } }
                        if timeframe == .monthly { fieldBlock(label: "Renews on") { domPicker } }
                        if !pools.isEmpty { fieldBlock(label: "Deals from pool") { poolSelector } }
                        HStack(spacing: 12) {
                            Text("Start active")
                                .font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
                            Spacer()
                            RisoPillSwitch(isOn: $isActive)
                        }
                        Text("Paused templates keep their pool but stop printing boards.")
                            .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                        previewBox
                        actionButtons
                        if isEditMode, let tpl = template {
                            Button { onDelete(tpl.id) } label: {
                                Text("Delete template")
                                    .font(.risoBody(14, .semibold))
                                    .foregroundStyle(Color.risoRed)
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 32)
                }
            }
        }
        .onAppear { seedForm() }
    }

    private var grabHandle: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.risoInk.opacity(0.2))
            .frame(width: 36, height: 4).padding(.top, 10).padding(.bottom, 14)
    }

    private var sheetHeader: some View {
        HStack {
            Text(isEditMode ? "Edit template" : "New template")
                .font(.risoHead(19, .extraBold)).foregroundStyle(Color.risoInk)
            Spacer()
            RisoButton(title: "Close", kind: .neutral) { dismiss() }
        }
        .padding(.horizontal, Riso.gutter).padding(.bottom, 20)
    }

    @ViewBuilder
    private func fieldBlock<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.risoBody(11, .bold)).tracking(1.1).foregroundStyle(Color.risoMuted)
            content()
        }
    }

    private var timeframeSegmented: some View {
        RisoSegmented(
            options: [(Timeframe.daily, "Daily"), (.weekly, "Weekly"),
                      (.monthly, "Monthly"), (.yearly, "Yearly")],
            selection: $timeframe,
            selectedFill: { $0.risoColor }
        )
    }

    private var boardSizeSegmented: some View {
        RisoSegmented(
            options: [(3, "3×3"), (4, "4×4"), (5, "5×5")],
            selection: $boardSize,
            selectedFill: { _ in .risoInk }
        )
    }

    private var weekdayPicker: some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                Button { weekday = i } label: {
                    Text(weekdayLetters[i])
                        .font(.risoHead(12, .bold))
                        .foregroundStyle(weekday == i ? Color.risoPaper : Color.risoInk)
                        .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                        .background(Circle().fill(weekday == i ? Color.risoInk : Color.risoPaper2))
                        .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                }.buttonStyle(.plain)
            }
        }
    }

    private var domPicker: some View {
        RisoSegmented(
            options: [(0, domLabels[0]), (1, domLabels[1]), (2, domLabels[2])],
            selection: $monthDom,
            selectedFill: { _ in .risoInk }
        )
    }

    private var poolSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pools, id: \.id) { pool in
                    Button { selectedPoolId = pool.id } label: {
                        Text(pool.timeframe.risoDisplayName + " pool")
                            .font(.risoHead(13, .bold))
                            .foregroundStyle(selectedPoolId == pool.id ? Color.risoPaper : Color.risoInk)
                            .padding(.vertical, 10).padding(.horizontal, 14)
                            .background(RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .fill(selectedPoolId == pool.id ? Color.risoInk : Color.risoPaper2))
                            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var previewBox: some View {
        Text(previewText)
            .font(.risoBody(13, .semibold)).foregroundStyle(Color.risoMuted)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(12)
            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk.opacity(0.4),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            RisoButton(title: "Cancel", kind: .neutral, fullWidth: true) { dismiss() }
            RisoButton(
                title: isEditMode ? "Save" : "Create template",
                kind: .primary, fullWidth: true
            ) { submitForm() }
            .opacity(canSave ? 1 : 0.45).disabled(!canSave)
        }
    }

    private func seedForm() {
        guard let tpl = template else {
            name = ""; timeframe = .weekly; boardSize = 5
            weekday = 0; monthDom = 0
            selectedPoolId = pools.first?.id; isActive = true
            return
        }
        name = tpl.name; timeframe = tpl.timeframe; boardSize = tpl.boardSize
        weekday = 0; monthDom = 0
        selectedPoolId = pools.first { $0.taskIds.contains(where: { tpl.seedTaskIds.contains($0) }) }?.id
            ?? pools.first?.id
        isActive = tpl.isActive
    }

    private func submitForm() {
        guard canSave else { return }
        let now = AppDatabase.currentTimestamp()
        let seedIds = selectedPool?.taskIds ?? template?.seedTaskIds ?? []
        if let existing = template {
            var updated = existing
            updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.timeframe = timeframe; updated.boardSize = boardSize
            updated.seedTaskIds = seedIds; updated.isActive = isActive
            // `version`/`updatedAt` are bumped by `saveTemplate` (the
            // persisting function) — bumping here too double-incremented.
            onSave(updated)
        } else {
            onSave(RecurringBoardTemplate(
                id: UUID().uuidString, userId: userId,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                timeframe: timeframe, boardSize: boardSize,
                centerSquareType: .free, centerSquareCustomName: nil,
                isRandomized: true, seedTaskIds: seedIds,
                lastSpawnedWindowKey: nil, isActive: isActive,
                createdAt: now, updatedAt: now,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ))
        }
    }
}

// MARK: - Shared Riso sub-page components

/// Back square button + "PROFILE" kicker + H2 title used by all Profile sub-pages.
struct RisoSubPageHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 40, height: 40)
                    .risoCard(fill: .risoPaper2)
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small))
            VStack(alignment: .leading, spacing: 2) {
                Text("Profile").risoKicker()
                Text(title).risoH2()
            }
            Spacer()
        }
        .padding(.horizontal, Riso.gutter)
    }
}

/// Dashed "+ New ___" button matching the prototype's pp-dashedbtn style.
struct RisoDashedButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.risoHead(14, .bold)).foregroundStyle(Color.risoInk)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
                .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        }.buttonStyle(.plain)
    }
}

/// Keyline pill toggle styled to Riso green accent.
struct RisoPillSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().tint(Color.risoGreen)
    }
}

// MARK: - Timeframe helpers

extension Timeframe {
    /// Short label used in UI tags and segmented controls.
    var risoDisplayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .custom: return "Custom"
        case .indefinite: return "Ongoing"
        }
    }

    /// Riso color for timeframe tags: Daily=gold, Weekly=blue, Monthly=green, Yearly=red.
    var risoColor: Color {
        switch self {
        case .daily: return .risoGold
        case .weekly: return .risoBlue
        case .monthly: return .risoGreen
        case .yearly: return .risoRed
        case .custom: return .risoMuted
        case .indefinite: return .risoMuted
        }
    }
}
