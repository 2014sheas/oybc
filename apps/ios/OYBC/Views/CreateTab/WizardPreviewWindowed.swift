import Foundation

// MARK: - Wizard preview — windowed cell state
//
// Split out of `BoardWizardPersist.swift` (file-size ceiling, 2026-10-04) —
// the two pure helpers the wizard's Preview ⇄ Rearrange grid injects so a
// prospective board's cells read the PROSPECTIVE window, never a task's
// lifetime cache: `wizardPreviewIsCompleted` (done-state) and its count twin
// `wizardPreviewCount`. Pinned by `WizardPreviewCompletionTests`.

/// Windowed "done" for a wizard-preview cell, resolved against the
/// PROSPECTIVE board's window (`[resolveWizardDates(...).start, .end]`,
/// inclusive; an indefinite board has no end — 2026-09-24 amendment) — never
/// the task's lifetime cache. A shared library task completed in a PREVIOUS
/// window must preview grey on the new board, exactly as it will render after
/// Save (the "green squares from previous windows" bug).
///
/// Branch order mirrors web `taskToSquareState` (and the play surfaces):
/// compound → windowed `CompoundEvaluation`; linked counting →
/// `resolveLinkedCounterDisplay` (window-stamped: root sum in its window;
/// hub-linked: the latch); event-owning primitives → windowed events.
/// Achievements aren't placeable via the wizard, so no kernel cell-state is
/// needed here. Pinned by `WizardPreviewCompletionTests`.
///
/// - Parameters:
///   - task: The previewed cell's task.
///   - taskById: Task lookup (children of compounds included).
///   - childrenByCompound: Compound → children links.
///   - eventsByTaskId: Non-deleted TaskEvents grouped by task id.
///   - windowStart: The prospective board's `startDate`.
///   - windowEnd: The prospective board's `endDate`, or `nil` (indefinite).
/// - Returns: Whether the cell previews as complete.
func wizardPreviewIsCompleted(
    task: Task,
    taskById: [String: Task],
    childrenByCompound: [String: [CompoundChild]],
    eventsByTaskId: [String: [TaskEvent]],
    windowStart: String,
    windowEnd: String?
) -> Bool {
    if task.type == .compound {
        return CompoundEvaluation.evaluate(
            compound: task,
            childrenByCompound: childrenByCompound,
            taskById: taskById,
            windowContext: CompoundWindowContext(
                windowStart: windowStart,
                windowEnd: windowEnd,
                eventsByTaskId: eventsByTaskId
            )
        )
    }
    if task.sharedCounterId != nil {
        return resolveLinkedCounterDisplay(
            task: task, eventsByTaskId: eventsByTaskId,
            window: LinkedCounterWindow(startDate: windowStart, endDate: windowEnd)
        ).isCompleted
    }
    guard isEventOwningTask(task) else { return task.isCompleted }
    return resolveTaskWindowState(
        task: task,
        events: eventsByTaskId[task.id] ?? [],
        windowStart: windowStart,
        windowEnd: windowEnd
    ).isCompleted
}

/// Windowed COUNT for a counting preview cell — the twin of
/// `wizardPreviewIsCompleted` for the number a counting square shows: a
/// linked counter resolves over the prospective board's window
/// (`resolveLinkedCounterDisplay`), an event-owning counter sums its own
/// in-window increments, anything else keeps its lifetime cache.
///
/// - Parameters:
///   - task: The placed task.
///   - eventsByTaskId: Non-deleted events grouped by task id.
///   - windowStart: The prospective board's `startDate`.
///   - windowEnd: The prospective board's `endDate` (nil = open-ended).
/// - Returns: The count the cell should display.
func wizardPreviewCount(
    task: Task,
    eventsByTaskId: [String: [TaskEvent]],
    windowStart: String,
    windowEnd: String?
) -> CountValue {
    guard task.type == .counting else { return task.currentCount ?? 0 }
    if task.sharedCounterId != nil {
        return resolveLinkedCounterDisplay(
            task: task, eventsByTaskId: eventsByTaskId,
            window: LinkedCounterWindow(startDate: windowStart, endDate: windowEnd)
        ).displayed
    }
    guard isEventOwningTask(task) else { return task.currentCount ?? 0 }
    return resolveTaskWindowState(
        task: task,
        events: eventsByTaskId[task.id] ?? [],
        windowStart: windowStart,
        windowEnd: windowEnd
    ).count
}
