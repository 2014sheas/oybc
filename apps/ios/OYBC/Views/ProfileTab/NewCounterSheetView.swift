import SwiftUI

/// NewCounterSheetView — Counters Hub "+ New counter" sheet (Shared Counters
/// P5, PR-2). iOS twin of web's `CreateCounterSheet.tsx` — copy is VERBATIM
/// per CLAUDE.md cross-platform parity rule.
///
/// Lets the user type an Action + Unit (+ optional starting count) to create
/// a new goal-less hub-born counter task via `createCounterTask`. Recomputes
/// a dedupe classification per keystroke via `classifyCounterCreateMatch`:
///
///   - `established` match → Create is disabled; a card offers "View counter"
///     (fires `onNavigateToCounter`, which the caller — `CountersHubView` —
///     uses to dismiss the sheet + push the existing counter's detail page).
///   - `standalone` match → a card offers one-tap "Promote", which flags the
///     existing standalone counting task as a counter (`promoteTaskToCounter`)
///     instead of creating a duplicate.
///   - no match → Create proceeds normally.
///
/// Unlike web (which owns its own router and can navigate directly from
/// "View counter"), this sheet has no navigation stack of its own once
/// dismissed — so BOTH the "View counter" tap and a successful create/promote
/// funnel through the single `onNavigateToCounter` callback, leaving the
/// dismiss+push choreography to the caller (mirrors web's documented
/// division of labor: the sheet owns the ops, the caller owns navigation).
struct NewCounterSheetView: View {

    let userId: String
    /// The user's live (non-deleted) task pool — used for dedupe classification.
    let tasks: [OYBC.Task]
    /// Fired when the sheet should close and the app should navigate to a
    /// counter's detail page — after a successful create, a successful
    /// promote, or a tap on an established match's "View counter" button.
    let onNavigateToCounter: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var action: String = ""
    @State private var unit: String = ""
    @State private var startingCountText: String = ""
    @State private var error: String? = nil
    @State private var busy: Bool = false

    // MARK: - Derived

    private var trimmedAction: String {
        action.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedUnit: String {
        unit.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var previewTitle: String {
        guard !trimmedAction.isEmpty, !trimmedUnit.isEmpty else { return "" }
        return TaskTitle.generateCounterTaskTitle(action: trimmedAction, maxCount: nil, unit: trimmedUnit)
    }

    private var match: CounterCreateMatch? {
        guard !trimmedAction.isEmpty, !trimmedUnit.isEmpty else { return nil }
        return classifyCounterCreateMatch(action: trimmedAction, unit: trimmedUnit, tasks: tasks)
    }

    private var canCreate: Bool {
        !trimmedAction.isEmpty && !trimmedUnit.isEmpty && match?.kind != .established && !busy
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                NewCounterSheetContentView(
                    action: $action,
                    unit: $unit,
                    startingCountText: $startingCountText,
                    error: error,
                    busy: busy,
                    previewTitle: previewTitle,
                    match: match,
                    onPromote: handlePromote,
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
    }

    // MARK: - Actions

    private func handleCreate() {
        guard canCreate else { return }
        let capturedAction = trimmedAction
        let capturedUnit = trimmedUnit
        let parsedStarting = Int(startingCountText.trimmingCharacters(in: .whitespacesAndNewlines))
        error = nil
        busy = true
        _Concurrency.Task.detached(priority: .userInitiated) {
            let now = AppDatabase.currentTimestamp()
            do {
                let task = try AppDatabase.shared.createCounterTask(
                    userId: userId,
                    action: capturedAction,
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

    private func handlePromote(taskId: String) {
        guard !busy else { return }
        error = nil
        busy = true
        _Concurrency.Task.detached(priority: .userInitiated) {
            let now = AppDatabase.currentTimestamp()
            do {
                let task = try AppDatabase.shared.promoteTaskToCounter(taskId: taskId, now: now)
                await MainActor.run {
                    busy = false
                    onNavigateToCounter(task.id)
                }
            } catch {
                await MainActor.run {
                    busy = false
                    self.error = "Could not promote to counter."
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

    @Binding var action: String
    @Binding var unit: String
    @Binding var startingCountText: String
    var error: String? = nil
    var busy: Bool = false
    var previewTitle: String = ""
    var match: CounterCreateMatch? = nil
    var onPromote: (String) -> Void = { _ in }
    var onViewCounter: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            fieldBlock(label: "Action") {
                RisoTextField(placeholder: "Push-ups", text: $action)
            }

            fieldBlock(label: "Unit") {
                RisoTextField(placeholder: "reps", text: $unit)
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldBlock(label: "Starting count (optional)") {
                    RisoNumberField(placeholder: "0", text: $startingCountText)
                }
                Text("Already partway? Seed the lifetime total.")
                    .font(.risoBody(11, .regular))
                    .foregroundStyle(Color.risoMuted)
            }

            if !previewTitle.isEmpty {
                (Text("New counter: ")
                    .font(.risoBody(12, .regular))
                    .foregroundStyle(Color.risoMuted)
                + Text(previewTitle)
                    .font(.risoBody(12, .extraBold))
                    .foregroundStyle(Color.risoInk))
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

    // MARK: - Dedupe banner

    /// Styled on `RisoSpecialTaskPanel.counterLinkBanner` — a keylined card
    /// on the paper background, colored to match web's established (gold) /
    /// standalone (green) dedupe cards.
    @ViewBuilder
    private var dedupeBanner: some View {
        if let match {
            switch match.kind {
            case .established:
                let name: String = {
                    let a = (match.task.action ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return a.isEmpty ? match.task.title : a
                }()
                VStack(alignment: .leading, spacing: 6) {
                    Text("You already have a \"\(name)\" counter")
                        .font(.risoHead(13, .bold))
                        .foregroundStyle(Color.risoInkStatic)
                    Text("\(match.lifetime) all-time · \(match.memberCount) task\(match.memberCount == 1 ? "" : "s")")
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoInkStatic.opacity(0.82))
                    RisoButton(title: "View counter", kind: .neutral, small: true) {
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

            case .standalone:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Make \"\(match.task.title)\" this counter?")
                        .font(.risoHead(13, .bold))
                        .foregroundStyle(Color.risoPaper)
                    Text("Keeps its count, goal, and boards.")
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoPaper.opacity(0.82))
                    RisoButton(title: "Promote", kind: .neutral, small: true) {
                        onPromote(match.task.id)
                    }
                    .disabled(busy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.risoGreen)
                .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInkStatic, lineWidth: Riso.Keyline.container)
                )
            }
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
                action: .constant("Push-ups"),
                unit: .constant("reps"),
                startingCountText: .constant(""),
                previewTitle: "Push-ups (reps)",
                match: CounterCreateMatch(
                    kind: .established,
                    task: Task(
                        id: "src", userId: "u1", title: "Push-ups", type: .counting,
                        action: "Push-ups", unit: "reps",
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

#Preview("New counter — standalone match") {
    NavigationStack {
        ScrollView {
            NewCounterSheetContentView(
                action: .constant("Run"),
                unit: .constant("km"),
                startingCountText: .constant(""),
                previewTitle: "Run (km)",
                match: CounterCreateMatch(
                    kind: .standalone,
                    task: Task(
                        id: "solo", userId: "u1", title: "Run 5 km", type: .counting,
                        action: "Run", unit: "km",
                        totalCompletions: 0, totalInstances: 0,
                        currentCount: 12,
                        createdAt: "2026-02-01T00:00:00.000", updatedAt: "2026-02-01T00:00:00.000",
                        version: 1, isDeleted: false
                    ),
                    lifetime: 12,
                    memberCount: 1
                )
            )
            .padding(16)
        }
        .background(Color.risoPaper.ignoresSafeArea())
    }
}
#endif
