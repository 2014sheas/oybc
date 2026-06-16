import SwiftUI

/// Copy sheet for the `From a board` grid's `⎘ Add a copy of this task…`
/// action. Pre-fills every field from the source and exposes per-type
/// editable surface:
///
/// - normal:      title only
/// - counting:    title + action + maxCount + unit
/// - compound:    title only (children stay shared)
/// - achievement: title + trigger + requiredCount (template mode).
///                Reference target preserved from the source; re-target
///                is a follow-up — user can edit the new task from the
///                Tasks tab.
///
/// Presentation-only Riso reskin of the pre-Riso implementation.
/// All save logic, callbacks, and data flow are preserved unchanged.
///
/// iOS twin of web's `CopyTaskModal`.
struct CopyTaskSheet: View {
    let source: OYBC.Task
    let userId: String

    /// Called on success with the new Task. Parent marks the source as
    /// "copied this session" and auto-adds the new id to selection.
    let onCopied: (OYBC.Task) -> Void
    /// Cancel / Escape / swipe-down.
    let onCancel: () -> Void

    @State private var title: String
    @State private var action: String
    @State private var unit: String
    @State private var maxCountInput: String
    @State private var trigger: AchievementTrigger
    @State private var requiredCountInput: String
    @State private var error: String?
    @State private var saving: Bool = false

    init(
        source: OYBC.Task,
        userId: String,
        onCopied: @escaping (OYBC.Task) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.source = source
        self.userId = userId
        self.onCopied = onCopied
        self.onCancel = onCancel
        self._title = State(initialValue: source.title)
        self._action = State(initialValue: source.action ?? "")
        self._unit = State(initialValue: source.unit ?? "")
        self._maxCountInput = State(
            initialValue: source.maxCount.map(String.init) ?? ""
        )
        self._trigger = State(initialValue: source.achievementTrigger ?? .greenlog)
        self._requiredCountInput = State(
            initialValue: source.requiredCount.map(String.init) ?? ""
        )
    }

    var body: some View {
        let isCounting = source.type == .counting
        let isCompound = source.type == .compound
        let isAchievement = source.type == .achievement
        let isTemplateMode = isAchievement && source.referencedTemplateId != nil

        NavigationStack {
            ZStack {
                RisoPaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Source reference card
                        sourceCard

                        // Title field (all types)
                        fieldSection(label: "TITLE") {
                            RisoTextField(placeholder: "Title", text: $title)
                        }

                        // Counting fields
                        if isCounting {
                            fieldSection(label: "COUNTING") {
                                VStack(spacing: 8) {
                                    RisoTextField(placeholder: "Action", text: $action)
                                    RisoNumberField(placeholder: "Goal", text: $maxCountInput)
                                    RisoTextField(placeholder: "Unit", text: $unit)
                                }
                            }
                        }

                        // Achievement fields
                        if isAchievement {
                            fieldSection(label: "ACHIEVEMENT") {
                                VStack(spacing: 8) {
                                    triggerSegmented
                                    if isTemplateMode {
                                        RisoNumberField(
                                            placeholder: "Required count",
                                            text: $requiredCountInput
                                        )
                                    }
                                }
                            }
                            retargetNote
                        }

                        // Compound note
                        if isCompound {
                            sharedChildrenNote
                        }

                        // Error banner
                        if let error {
                            Text(error)
                                .font(.risoBody(11, .semibold))
                                .foregroundStyle(Color.risoRed)
                        }
                    }
                    .padding(Riso.gutter)
                }
            }
            .navigationTitle("Add a copy of this task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoInk)
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                            .tint(Color.risoBlue)
                    } else {
                        Button("Save copy") {
                            handleSave(
                                isCounting: isCounting,
                                isCompound: isCompound,
                                isAchievement: isAchievement,
                                isTemplateMode: isTemplateMode
                            )
                        }
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoBlue)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Subviews

    /// Source reference — ink-keyline card showing original task title + type badge.
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COPYING FROM")
                .font(.risoBody(11, .bold))
                .tracking(0.22 * 11)
                .foregroundStyle(Color.risoMuted)

            HStack(spacing: 10) {
                RisoTypeBadge(kind: risoKind(for: source.type), style: .letterSquare)
                Text(source.title)
                    .font(.risoHead(13.5, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.risoPaper2)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
            )
        }
    }

    /// Achievement trigger segmented control — Greenlog / Bingo.
    private var triggerSegmented: some View {
        RisoSegmented(
            options: [
                (value: AchievementTrigger.greenlog, label: "Greenlog"),
                (value: AchievementTrigger.bingo,    label: "Bingo"),
            ],
            selection: $trigger
        )
    }

    /// Informational note for achievement copies.
    private var retargetNote: some View {
        Text(
            "The copy watches the same target as the source. To re-target, edit the new task from the Tasks tab after Save."
        )
        .font(.risoBody(10.5, .semibold))
        .foregroundStyle(Color.risoMuted)
        .padding(10)
        .background(Color.risoPaper2)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
        )
    }

    /// Informational note for compound copies (shared children).
    private var sharedChildrenNote: some View {
        Text(
            "The copy reuses the source's subtasks. Completing the original subtasks still completes them on the copy and vice versa (shared children)."
        )
        .font(.risoBody(10.5, .semibold))
        .foregroundStyle(Color.risoMuted)
        .padding(10)
        .background(Color.risoPaper2)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
        )
    }

    /// Generic labeled field section — kicker label above content.
    @ViewBuilder
    private func fieldSection<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.risoBody(11, .bold))
                .tracking(0.22 * 11)
                .foregroundStyle(Color.risoMuted)
            content()
        }
    }

    // MARK: - Save (logic unchanged from pre-Riso version)

    private func handleSave(
        isCounting: Bool,
        isCompound: Bool,
        isAchievement: Bool,
        isTemplateMode: Bool
    ) {
        error = nil
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            error = "Title is required"
            return
        }

        saving = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let newTask: OYBC.Task
                if isCompound {
                    newTask = try AppDatabase.shared.copyCompound(
                        userId: userId,
                        source: source,
                        title: trimmedTitle
                    )
                } else {
                    var overrides = AppDatabase.CopyTaskOverrides(title: trimmedTitle)
                    if isCounting {
                        guard let parsedMax = Int(
                            maxCountInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        ), parsedMax > 0 else {
                            throw NSError(
                                domain: "CopyTaskSheet",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey:
                                    "Goal must be a positive integer"]
                            )
                        }
                        overrides.action = action.trimmingCharacters(in: .whitespacesAndNewlines)
                        overrides.unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
                        overrides.maxCount = parsedMax
                    }
                    if isAchievement {
                        overrides.achievementTrigger = trigger
                        if isTemplateMode {
                            guard let parsedRequired = Int(
                                requiredCountInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            ), parsedRequired > 0 else {
                                throw NSError(
                                    domain: "CopyTaskSheet",
                                    code: 2,
                                    userInfo: [NSLocalizedDescriptionKey:
                                        "Required count must be a positive integer"]
                                )
                            }
                            overrides.requiredCount = parsedRequired
                        }
                    }
                    newTask = try AppDatabase.shared.copyTask(
                        userId: userId,
                        source: source,
                        overrides: overrides
                    )
                }

                DispatchQueue.main.async {
                    saving = false
                    onCopied(newTask)
                }
            } catch {
                DispatchQueue.main.async {
                    saving = false
                    self.error = (error as NSError).localizedDescription
                }
            }
        }
    }

    // MARK: - Helpers

    private func risoKind(for type: TaskType) -> RisoTaskKind {
        switch type {
        case .normal:      return .normal
        case .counting:    return .counting
        case .compound:    return .compound
        case .achievement: return .achievement
        }
    }
}
