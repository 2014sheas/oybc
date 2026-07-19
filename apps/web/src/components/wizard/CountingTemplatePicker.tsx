import { useRef, useState } from 'react';
import { TaskType, type Task, type LinkableCounter } from '@oybc/shared';
import { useTaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { CounterLinkHint } from '../counters';
import styles from './CountingTemplatePicker.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

/** Baseline mode for a linked counting task. R1: only `startFromZero`
 *  ("start fresh") is ever produced by the auto-link flow — the manual
 *  Inherit/Start-from-zero radio choice was retired along with the manual
 *  "Link to existing counter" mode. The type stays (rather than collapsing
 *  to a boolean) because `LinkedCounterInput` is a stable cross-file
 *  contract (`NewTaskSheet`, `useCreateFormState`). */
export type BaselineMode = 'inherit' | 'startFromZero';

/**
 * Result emitted by the auto-link create flow — built by the host
 * (`CreateNewTaskForm`) when a counting-task submit auto-links to a matched
 * counter, and consumed by `NewTaskSheet`'s `handleCreateLinked`.
 */
export interface LinkedCounterInput {
  /** The source counting task the new task will derive from. */
  source: Task;
  /**
   * The user-supplied threshold for the new linked task.
   * Validated: integer >= 1.
   */
  maxCount: number;
  /** Title for the new task. Auto-generated via generateCounterTaskTitle() but editable. */
  title: string;
  /** Baseline mode. R1 auto-link always uses `startFromZero`. */
  baselineMode: BaselineMode;
  /**
   * Computed baseline value — for `startFromZero`, the source's
   * `currentCount` at link time (the new task's own window then starts
   * counting from 0 forward).
   */
  baseline: number;
}

/** Auto-link hint state, computed + owned by the host form (which already
 *  loads the task library for submission) and passed down purely for
 *  rendering. `null` when there's no match, no valid goal yet, or the host
 *  isn't tracking the auto-link decision for this context. */
export interface CounterLinkHintState {
  match: LinkableCounter;
  /** The new task's own goal (`maxCount`) — the hint's "0–{goal} window". */
  goal: number;
  /** Whether this create currently links to `match`. */
  linked: boolean;
  /** Toggles `linked` — the "Don't link" / "Link" pill. */
  onToggle: () => void;
}

export interface CountingTemplatePickerProps {
  /** Authenticated user id — used to load the task library. */
  userId: string | undefined;
  /** The task currently used as a template, or null if none. */
  selectedTemplate: Task | null;
  /** Called when the user picks a source counting task as a template. */
  onSelect: (task: Task) => void;
  /** Called when the user clears the current template selection. */
  onClear: () => void;
  /**
   * R1 counters refresh — the auto-link hint to render above the template
   * affordance, or `null` to render nothing. See `CounterLinkHintState`.
   */
  linkHint?: CounterLinkHintState | null;
}

/**
 * CountingTemplatePicker — Compact "derive from existing" affordance for
 * the counting-type variant of CreateNewTaskForm / NewTaskSheet.
 *
 * R1 counters refresh ("Refining counters" design handoff §Creation
 * Surfaces) retired the manual "Link to existing counter" mode (source
 * dropdown + threshold + baseline radios + `DerivedCounterRow` preview +
 * "Create linked task" button) — linking is now automatic (see
 * `CounterLinkHint`) whenever the typed (verb, noun) pair exactly matches
 * an existing counter, with a "Don't link" opt-out. This component now
 * does exactly one thing: the template-prefill affordance ("Use as
 * template"), plus rendering the auto-link hint the host computed.
 *
 * When no template is selected: renders a dashed "Use existing counting
 * task as template..." button. Clicking opens an inline dropdown listing
 * counting tasks. When a template is selected: renders a compact banner
 * "Template: <title>" with a clear (×) button.
 */
export function CountingTemplatePicker({
  userId,
  selectedTemplate,
  onSelect,
  onClear,
  linkHint,
}: CountingTemplatePickerProps): React.ReactElement {
  const [open, setOpen] = useState(false);
  const buttonRef = useRef<HTMLButtonElement>(null);

  const library = useTaskLibrary(userId);
  const countingTasks = library.allTasks.filter(
    (t) => t.type === TaskType.COUNTING && !t.isDeleted,
  );

  function handleTemplateSelect(task: Task): void {
    onSelect(task);
    setOpen(false);
  }

  return (
    <div className={styles.pickerRoot}>
      {linkHint && (
        <CounterLinkHint
          counterName={linkHint.match.name}
          lifetime={linkHint.match.lifetime}
          goal={linkHint.goal}
          linked={linkHint.linked}
          onToggle={linkHint.onToggle}
        />
      )}

      {selectedTemplate !== null ? (
        <div className={styles.selectedBanner}>
          <span className={styles.selectedLabel}>Template:</span>
          <span className={styles.selectedTitle}>{selectedTemplate.title}</span>
          <button
            type="button"
            className={styles.clearButton}
            onClick={onClear}
            aria-label="Clear template"
          >
            ✕
          </button>
        </div>
      ) : (
        <div className={styles.dropdownWrapper}>
          <button
            ref={buttonRef}
            type="button"
            className={styles.affordance}
            onClick={() => setOpen((prev) => !prev)}
            aria-expanded={open}
            aria-haspopup="listbox"
          >
            Use existing counting task as template...
          </button>
          {open && (
            <div className={styles.dropdown} role="listbox" aria-label="Counting task templates">
              {countingTasks.length === 0 ? (
                <p className={styles.dropdownEmpty}>No counting tasks in your library yet.</p>
              ) : (
                countingTasks.map((task) => (
                  <button
                    key={task.id}
                    type="button"
                    className={styles.dropdownItem}
                    role="option"
                    aria-selected={false}
                    onClick={() => handleTemplateSelect(task)}
                  >
                    {task.title}
                    {task.action && task.unit ? (
                      <span className={styles.dropdownMeta}>
                        {task.action} · {task.unit}
                      </span>
                    ) : null}
                  </button>
                ))
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
