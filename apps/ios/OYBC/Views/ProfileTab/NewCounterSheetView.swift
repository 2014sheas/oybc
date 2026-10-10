import SwiftUI

/// NewCounterSheetView — Counters Hub "+ New counter" sheet (Shared Counters
/// P5, PR-2; R1 counters refresh — "Refining counters" design handoff
/// §Creation Surfaces). iOS twin of web's `CreateCounterSheet.tsx` — copy is
/// VERBATIM per CLAUDE.md cross-platform parity rule.
///
/// Fields (shared counter settings, docs/SHARED_COUNTER_SETTINGS.md §1):
/// Name · Kind · "What are you counting?" (the noun, stored as `unit`) · "Task
/// verb" (stored as `action`) · Singular / Plural title · Defaults per core
/// timeframe · "Start from" (create only). Only the noun and the verb are
/// required; every other text field is optional — blank = unset, and the
/// derived default shows DIMMED in the field (`CounterSheetForm`). Recomputes a dedupe
/// classification per keystroke via `classifyCounterCreateMatch`:
///
///   - `established` match → Create is disabled; a gold card offers
///     "Open {CounterName}" (fires `onNavigateToCounter`, which the caller —
///     `CountersHubView` — uses to dismiss the sheet + push the existing
///     counter's detail page).
///   - `standalone` match → R1: the promote-to-counter UI entry point was
///     removed (`promoteTaskToCounter` itself is untouched — see CLAUDE.md's
///     Global Constraints). Create proceeds normally.
///   - no match → Create proceeds normally.
///
/// Unlike web (which owns its own router and can navigate directly from
/// "Open {CounterName}"), this sheet has no navigation stack of its own once
/// dismissed — so BOTH that tap and a successful create funnel through the
/// single `onNavigateToCounter` callback, leaving the dismiss+push
/// choreography to the caller (mirrors web's documented division of labor:
/// the sheet owns the ops, the caller owns navigation).
///
/// EDIT mode (`root` set — Counter Detail "Edit counter…"): a counter is
/// edited through THIS sheet, never the task editor. Same fields, prefilled
/// (`CounterEditModel`), no "Start from"; the kind picker carries the edit
/// locks and the shared Continuous → Discrete confirm (`kindSwitchConfirm`);
/// a rename checks the dedupe pool minus the counter's own family; Save →
/// `applyTaskEditPatch(CounterEditModel.patch(…))` — the Task Detail write.
struct NewCounterSheetView: View {

    let userId: String
    /// The user's live (non-deleted) task pool — used for dedupe classification.
    let tasks: [OYBC.Task]
    /// Fired when the sheet should close and the app should navigate to a
    /// counter's detail page — after a successful create, or a tap on an
    /// established match's "Open {CounterName}" button.
    let onNavigateToCounter: (String) -> Void
    /// EDIT mode: the counter's ROOT task (nil = create).
    var root: Task? = nil
    /// Injected database (ROADMAP B3 seam); defaults to the app singleton.
    var database: AppDatabase = .shared
    /// Fired after an edit-mode save succeeds.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var form = CounterSheetForm()
    @State private var touched: Set<CounterSheetField> = []
    @State private var error: String? = nil
    @State private var busy: Bool = false
    @State private var pendingSwitch: KindSwitchPreview?

    init(
        userId: String,
        tasks: [OYBC.Task],
        root: Task? = nil,
        database: AppDatabase = .shared,
        onNavigateToCounter: @escaping (String) -> Void,
        onSaved: @escaping () -> Void = {}
    ) {
        self.userId = userId
        self.tasks = tasks
        self.root = root
        self.database = database
        self.onNavigateToCounter = onNavigateToCounter
        self.onSaved = onSaved
        if let root { _form = State(initialValue: CounterSheetForm.seed(root: root)) }
    }

    // MARK: - Derived

    private var isEditing: Bool { root != nil }

    private var startFromEmpty: Bool {
        form.startText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// The parsed seed at the selected kind — the one value validation and save both use.
    private var startFromValue: CountValue? {
        parseCountInput(form.startText, kind: form.kind, allowZero: true)
    }
    private var startFromInvalid: Bool { !startFromEmpty && startFromValue == nil }

    /// Edit mode checks only a rename, against everything but the counter's family.
    /// Only computed once both the noun and the verb are filled.
    private var match: CounterCreateMatch? {
        guard !form.trimmedNoun.isEmpty, !form.trimmedVerb.isEmpty else { return nil }
        guard let root else {
            return classifyCounterCreateMatch(action: form.trimmedVerb, unit: form.trimmedNoun, tasks: tasks)
        }
        guard CounterEditModel.identityChanged(root: root, draft: form.editDraft) else { return nil }
        return classifyCounterCreateMatch(
            action: form.trimmedVerb, unit: form.trimmedNoun, tasks: CounterEditModel.dedupePool(root: root, tasks: tasks)
        )
    }

    /// Create / Save: the required fields are filled, nothing blocks (an
    /// established match, an unparseable entry), and no write is in flight.
    private var canSubmit: Bool {
        form.requiredFilled(isEditing: isEditing) && match?.kind != .established
            && !startFromInvalid && !form.goalsInvalid && !busy
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                NewCounterSheetContentView(
                    form: $form,
                    touched: $touched,
                    startFromInvalid: startFromInvalid,
                    error: error,
                    busy: busy,
                    match: match,
                    isEditing: isEditing,
                    kindLock: root.map { kindPickerLock(mode: .edit, kind: resolveCountKind($0.countKind)) } ?? .none,
                    onKindRequest: root == nil ? nil : requestKind,
                    onViewCounter: onNavigateToCounter
                )
                .padding(16)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(root == nil ? "New counter" : "Edit counter")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if root == nil {
                        RisoToolbarPill(title: "Create counter") { handleCreate() }
                            .disabled(!canSubmit)
                            .opacity(canSubmit ? 1 : 0.5)
                    } else {
                        RisoToolbarPill(title: "Save") { handleSave() }
                            .disabled(!canSubmit)
                            .opacity(canSubmit ? 1 : 0.5)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .disabled(busy)
                }
            }
        }
        // The presenting site (`CountersHubView`) has no visibility into this
        // sheet's private `busy` state, so the dismiss guard lives here,
        // keyed on this view's own `busy`.
        .interactiveDismissDisabled(busy)
        // The seed and default-goal grammar differ per kind (decimal / h:m) — a
        // stale entry would mis-parse. Edit keeps its entered goals (kind units).
        .onChange(of: form.kind) {
            form.startText = ""
            if root == nil { form.goalTexts = [:] }
        }
        .kindSwitchConfirm(pending: $pendingSwitch) { p in form.kind = p.to }
    }

    // MARK: - Edit mode

    /// Continuous → Discrete opens the shared confirm (previewing the draft);
    /// any other permitted change applies at once.
    private func requestKind(_ next: CountKind) {
        guard let root, KindSwitchCopy.needsConfirm(from: form.kind, to: next) else { form.kind = next; return }
        let linked = (try? database.previewCounterKindSwitch(rootTaskId: root.id, to: next))?.linkedCount ?? 0
        var draftTask = root
        draftTask.action = form.verb
        draftTask.unit = form.noun
        draftTask.countKind = form.kind
        pendingSwitch = KindSwitchPreview.planned(task: draftTask, to: next, linkedCount: linked)
    }

    /// Saves through `applyTaskEditPatch` — the Task Detail write.
    private func handleSave() {
        guard let root, canSubmit else { return }
        let patch = CounterEditModel.patch(root: root, draft: form.editDraft)
        let db = database
        error = nil
        busy = true
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                try db.applyTaskEditPatch(taskId: root.id, patch: patch)
                await MainActor.run {
                    busy = false
                    onSaved()
                }
            } catch {
                let message = AppDatabase.taskEditErrorMessage(error)
                await MainActor.run {
                    busy = false
                    self.error = message
                }
            }
        }
    }

    // MARK: - Actions

    private func handleCreate() {
        guard canSubmit else { return }
        let capturedVerb = form.trimmedVerb
        let capturedUnit = form.trimmedNoun
        let parsedStarting = startFromValue
        let capturedKind = form.kind
        let capturedSettings = form.storedSettings
        error = nil
        busy = true
        _Concurrency.Task.detached(priority: .userInitiated) {
            let now = AppDatabase.currentTimestamp()
            do {
                let task = try AppDatabase.shared.createCounterTask(
                    userId: userId,
                    action: capturedVerb,
                    unit: capturedUnit,
                    startingCount: parsedStarting,
                    countKind: capturedKind,
                    settings: capturedSettings,
                    now: now
                )
                await MainActor.run {
                    busy = false
                    onNavigateToCounter(task.id)
                }
            } catch {
                await MainActor.run {
                    busy = false
                    self.error = "Could not create counter."
                }
            }
        }
    }
}

// MARK: - NewCounterSheetContentView (pure-props leaf, snapshot-testable)

/// The scrollable content of `NewCounterSheetView` — fields, dedupe banner and
/// error caption — without the NavigationStack toolbar chrome. Extracted as a
/// real reusable view (mirrors `NewTaskSheetContentView`) so the sheet and the
/// snapshot tests render the SAME layout from one source of truth.
struct NewCounterSheetContentView: View {

    @Binding var form: CounterSheetForm
    /// Required fields that have been edited-then-emptied or blurred while
    /// empty — the only ones that show their inline error.
    @Binding var touched: Set<CounterSheetField>
    var startFromInvalid: Bool = false
    var error: String? = nil
    var busy: Bool = false
    var match: CounterCreateMatch? = nil
    /// Edit mode: hides "Start from" (the seed is a create-only field).
    var isEditing: Bool = false
    var kindLock: KindPickerLock = .none
    /// Edit mode routes picks through the confirm seam; nil = set directly.
    var onKindRequest: ((CountKind) -> Void)? = nil
    var onViewCounter: (String) -> Void = { _ in }

    @FocusState private var focus: CounterSheetField?

    var body: some View {
        let defaults = form.defaults
        VStack(alignment: .leading, spacing: 14) {

            // The derived name needs a noun (web parity): a verb alone shows nothing dimmed.
            TemplateFieldView(
                label: "Name", text: $form.name, derived: form.trimmedNoun.isEmpty ? "" : defaults.name, count: 1,
                kind: form.kind, showsExample: false, maxLength: 100
            )

            fieldBlock(label: "Kind") {
                KindPickerView(selection: $form.kind, lock: kindLock, onRequest: onKindRequest)
            }

            requiredField(label: "What are you counting?", placeholder: "push-ups", text: $form.noun, field: .noun)

            requiredField(label: "Task verb", placeholder: "Read", text: $form.verb, field: .verb)

            TemplateFieldView(
                label: "Singular title", text: $form.singular,
                derived: form.shownTemplateDefault(defaults.singular),
                count: TemplateFieldModel.exampleCount(plural: false, kind: form.kind), kind: form.kind
            )

            TemplateFieldView(
                label: "Plural title", text: $form.plural,
                derived: form.shownTemplateDefault(defaults.plural),
                count: TemplateFieldModel.exampleCount(plural: true, kind: form.kind), kind: form.kind
            )

            DefaultsRowView(kind: form.kind, unit: form.trimmedNoun, texts: $form.goalTexts, derived: defaults.goals)

            if !isEditing {
                fieldBlock(label: "Start from (optional)") {
                    GoalEntryView(kind: form.kind, text: $form.startText, placeholder: "0", invalid: startFromInvalid)
                }
            }

            dedupeBanner

            if let error {
                Text(error)
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoRed)
            }
        }
        .onChange(of: focus) { old, _ in
            if let old { touched.insert(old) }
        }
        .onChange(of: form.noun) { touched.insert(.noun) }
        .onChange(of: form.verb) { touched.insert(.verb) }
    }

    // MARK: - Field blocks

    private func fieldBlock<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.risoHead(11, .bold))
                .tracking(0.3)
                .foregroundStyle(Color.risoMuted)
            content()
        }
    }

    /// A required text field: red keyline + an inline error underneath once touched and empty.
    private func requiredField(
        label: String, placeholder: String, text: Binding<String>, field: CounterSheetField
    ) -> some View {
        let message = form.error(for: field, touched: touched, isEditing: isEditing)
        return fieldBlock(label: label) {
            RisoTextField(placeholder: placeholder, text: text, invalid: message != nil)
                .focused($focus, equals: field)
            if let message {
                Text(message)
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoRed)
            }
        }
    }

    // MARK: - Dedupe banner (established match only — R1 removed the
    // standalone/promote branch)

    @ViewBuilder
    private var dedupeBanner: some View {
        if let match, match.kind == .established {
            let counterName = CounterSettings.counterDisplayName(match.task)
            VStack(alignment: .leading, spacing: 6) {
                Text("You're already counting \(form.trimmedNoun)")
                    .font(.risoHead(13, .bold))
                    .foregroundStyle(Color.risoInkStatic)
                Text("\(formatCountTotal(match.lifetime, kind: resolveCountKind(match.task.countKind))) all-time · counting on \(match.memberCount) task\(match.memberCount == 1 ? "" : "s")")
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoInkStatic.opacity(0.82))
                RisoButton(title: "Open \(counterName)", kind: .neutral, small: true) {
                    onViewCounter(match.task.id)
                }
                .disabled(busy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.risoGold)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInkStatic, lineWidth: Riso.Keyline.container)
            )
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("New counter — empty") {
    NewCounterSheetView(userId: "u1", tasks: [], onNavigateToCounter: { _ in })
}

#Preview("New counter — established match") {
    NavigationStack {
        ScrollView {
            NewCounterSheetContentView(
                form: .constant(CounterSheetForm(noun: "push-ups")),
                touched: .constant([]),
                match: CounterCreateMatch(
                    kind: .established,
                    task: Task(
                        id: "src", userId: "u1", title: "Push-ups", type: .counting,
                        action: "Do", unit: "push-ups",
                        totalCompletions: 0, totalInstances: 0,
                        currentCount: 512,
                        createdAt: "2026-02-01T00:00:00.000", updatedAt: "2026-02-01T00:00:00.000",
                        version: 1, isDeleted: false, isCounter: true
                    ),
                    lifetime: 512,
                    memberCount: 2
                )
            )
            .padding(16)
        }
        .background(Color.risoPaper.ignoresSafeArea())
    }
}
#endif
