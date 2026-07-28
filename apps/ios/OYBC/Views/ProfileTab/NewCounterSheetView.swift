import SwiftUI

/// NewCounterSheetView — Counters Hub "+ New counter" sheet (Shared Counters
/// P5, PR-2; R1 counters refresh — "Refining counters" design handoff
/// §Creation Surfaces). iOS twin of web's `CreateCounterSheet.tsx` — copy is
/// VERBATIM per CLAUDE.md cross-platform parity rule.
///
/// Fields follow the (verb, noun) identity model: "What are you counting?"
/// captures the noun (stored as `unit`, autofocused), the optional "Task
/// verb" captures the verb (stored as `action`, defaulting to "Do" when left
/// blank), and "Start from" seeds the lifetime total. Recomputes a dedupe
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
struct NewCounterSheetView: View {

    let userId: String
    /// The user's live (non-deleted) task pool — used for dedupe classification.
    let tasks: [OYBC.Task]
    /// Fired when the sheet should close and the app should navigate to a
    /// counter's detail page — after a successful create, or a tap on an
    /// established match's "Open {CounterName}" button.
    let onNavigateToCounter: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Fallback verb when the "Task verb" field is left blank — per the
    /// (verb, noun) identity model, an empty verb submits as "Do".
    private static let defaultVerb = "Do"

    @State private var verb: String = ""
    @State private var unit: String = ""
    @State private var startingCountText: String = ""
    @State private var error: String? = nil
    @State private var busy: Bool = false

    // MARK: - Derived

    private var trimmedVerb: String {
        verb.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedUnit: String {
        unit.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var effectiveVerb: String {
        trimmedVerb.isEmpty ? Self.defaultVerb : trimmedVerb
    }

    private var previewName: String {
        guard !trimmedUnit.isEmpty else { return "" }
        return CounterName.formatCounterName(action: effectiveVerb, unit: trimmedUnit)
    }

    private var previewCount: Int {
        let parsed = Int(startingCountText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return parsed > 0 ? parsed : 0
    }

    private var match: CounterCreateMatch? {
        guard !trimmedUnit.isEmpty else { return nil }
        return classifyCounterCreateMatch(action: effectiveVerb, unit: trimmedUnit, tasks: tasks)
    }

    /// R1: the promote/standalone card was removed — a `standalone` match no
    /// longer blocks or offers anything; only `established` blocks create.
    private var canCreate: Bool {
        !trimmedUnit.isEmpty && match?.kind != .established && !busy
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                NewCounterSheetContentView(
                    verb: $verb,
                    unit: $unit,
                    startingCountText: $startingCountText,
                    error: error,
                    busy: busy,
                    previewName: previewName,
                    previewCount: previewCount,
                    trimmedUnit: trimmedUnit,
                    match: match,
                    onViewCounter: onNavigateToCounter
                )
                .padding(16)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("New counter")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    RisoToolbarPill(title: "Create counter") { handleCreate() }
                        .disabled(!canCreate)
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
    }

    // MARK: - Actions

    private func handleCreate() {
        guard canCreate else { return }
        let capturedVerb = effectiveVerb
        let capturedUnit = trimmedUnit
        let parsedStarting = Int(startingCountText.trimmingCharacters(in: .whitespacesAndNewlines))
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

/// The scrollable content of `NewCounterSheetView` — fields, preview, dedupe
/// banner, and error caption — without the NavigationStack toolbar chrome.
/// Extracted as a real reusable view (mirrors `NewTaskSheetContentView`) so
/// the sheet and the snapshot tests render the SAME layout from one source
/// of truth.
struct NewCounterSheetContentView: View {

    @Binding var verb: String
    @Binding var unit: String
    @Binding var startingCountText: String
    var error: String? = nil
    var busy: Bool = false
    var previewName: String = ""
    var previewCount: Int = 0
    var trimmedUnit: String = ""
    var match: CounterCreateMatch? = nil
    var onViewCounter: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            fieldBlock(label: "What are you counting?") {
                RisoTextField(placeholder: "push-ups", text: $unit)
            }
            Text("A plural noun — push-ups, pages, miles.")
                .font(.risoBody(11, .regular))
                .foregroundStyle(Color.risoMuted)

            fieldBlock(label: "Task verb (optional)") {
                RisoTextField(placeholder: "Do", text: $verb)
            }
            // Straight quotes (matches web's `&quot;` entity — verbatim
            // copy parity, not typographic curly quotes).
            Text("Used in task titles — \"Do 100 push-ups\". Try \"Read\" for pages, \"Run\" for miles.")
                .font(.risoBody(11, .regular))
                .foregroundStyle(Color.risoMuted)

            VStack(alignment: .leading, spacing: 5) {
                fieldBlock(label: "Start from (optional)") {
                    RisoNumberField(placeholder: "0", text: $startingCountText)
                }
                Text("Already partway? Seed the lifetime total.")
                    .font(.risoBody(11, .regular))
                    .foregroundStyle(Color.risoMuted)
            }

            if !previewName.isEmpty {
                previewCard
            }

            dedupeBanner

            if let error {
                Text(error)
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoRed)
            }
        }
    }

    // MARK: - Field block

    private func fieldBlock<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.risoHead(11, .bold))
                .tracking(0.3)
                .foregroundStyle(Color.risoMuted)
            content()
        }
    }

    // MARK: - Live preview card

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(previewName)
                    .font(.risoHead(15, .extraBold))
                    .foregroundStyle(Color.risoInk)
                Spacer(minLength: 8)
                Text(previewCount.formatted())
                    .font(.risoHead(15, .extraBold))
                    .foregroundStyle(Color.risoInk)
            }
            HStack {
                Text("Tasks that count \(trimmedUnit) link up automatically.")
                    .font(.risoBody(11, .regular))
                    .foregroundStyle(Color.risoMuted)
                Spacer(minLength: 8)
                Text("All-time")
                    .font(.risoBody(10, .bold))
                    .tracking(0.3)
                    .foregroundStyle(Color.risoMuted)
            }
        }
        .padding(12)
        .background(Color.risoPaper2)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
        )
    }

    // MARK: - Dedupe banner (established match only — R1 removed the
    // standalone/promote branch)

    @ViewBuilder
    private var dedupeBanner: some View {
        if let match, match.kind == .established {
            let counterName: String = {
                let derived = CounterName.formatCounterName(action: match.task.action, unit: match.task.unit)
                return derived.isEmpty ? match.task.title : derived
            }()
            VStack(alignment: .leading, spacing: 6) {
                Text("You're already counting \(trimmedUnit)")
                    .font(.risoHead(13, .bold))
                    .foregroundStyle(Color.risoInkStatic)
                Text("\(match.lifetime.formatted()) all-time · counting on \(match.memberCount) task\(match.memberCount == 1 ? "" : "s")")
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
                verb: .constant(""),
                unit: .constant("push-ups"),
                startingCountText: .constant(""),
                previewName: "Push-ups",
                previewCount: 0,
                trimmedUnit: "push-ups",
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
