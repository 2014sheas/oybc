import { useRef, useState } from 'react';
import { TaskType, type Task, type Timeframe } from '@oybc/shared';
import { createTask } from '../../db/operations/tasks';
import { generateUUID, currentTimestamp } from '../../db/utils';
import { RisoButton } from '../riso';
import type { PendingTaskPayload } from '../../pages/createPage/useCreateFormState';
import styles from './WizardQuickAddRow.module.css';

/**
 * Props for WizardQuickAddRow.
 *
 * The presence of `onPendingCreated` implicitly enables deferred-persist
 * mode (same convention as `NewTaskSheet`). When omitted, the task is
 * written to the DB immediately via `createTask`.
 */
export interface WizardQuickAddRowProps {
  /** Authenticated user id. */
  userId: string;
  /** Board timeframe — inherited by the new task so it matches the board's
   *  window. Mirrors the iOS `defaultTimeframe` param on `RisoQuickAddRowView`. */
  currentTimeframe?: Timeframe;
  /** Board start date (ISO8601, local) — inherited by the new task. */
  currentStartDate?: string;
  /** Board end date (ISO8601, local) — inherited by the new task. */
  currentEndDate?: string;
  /** Called when the new task is ready (created or deferred). The wizard
   *  auto-adds the returned task to `selectedTaskIds`. */
  onTaskCreated: (task: Task) => void;
  /**
   * Bug #85 — Deferred-persist callback. When provided, the component
   * builds the task fully in-memory (with `createdInWizard: true`) and
   * fires this alongside `onTaskCreated` without touching the DB. The
   * wizard atomically writes the pending payload when saving the board.
   * Absent for immediate-persist callers (e.g. Tasks-tab quick-add).
   */
  onPendingCreated?: (payload: PendingTaskPayload) => void;
  /**
   * Externally-driven disable (e.g. a parent sheet's save/delete in
   * flight). Defaults to `false` — existing callers are unaffected.
   * Combines with the row's own `isSubmitting` state, which already
   * disables mid-submit regardless of this prop.
   */
  disabled?: boolean;
}

/** Rotating placeholder pool — mirrors the iOS `RisoQuickAddRowView` suggestions. */
const PLACEHOLDERS = [
  'e.g. Meditate 10 min',
  'e.g. Drink water',
  'e.g. Read 30 min',
  'e.g. Walk the dog',
  'e.g. Stretch',
];

/**
 * WizardQuickAddRow — inline text input for creating a NORMAL task directly
 * from the wizard Tasks step without opening the full New Task modal.
 *
 * Web twin of the iOS `RisoQuickAddRowView`. The full `NewTaskSheet` modal
 * remains for Counting/Compound/Achievement types — this row is additive and
 * handles the common one-field NORMAL case only.
 *
 * Placement: just above the task list, below the filter chips (always visible
 * unless the "From a board…" grid is active). Creates the task and auto-
 * selects it into the pool, then resets and keeps focus so the user can
 * type the next task immediately.
 *
 * Deferred-persist is controlled by the presence of `onPendingCreated`:
 * - With `onPendingCreated` → task is built in-memory (`createdInWizard: true`),
 *   no DB write — wizard writes atomically at board-save.
 * - Without `onPendingCreated` → immediate `createTask()` DB write.
 *
 * iOS source: `Views/CreateTab/Components/RisoQuickAddRowView.swift`.
 */
export function WizardQuickAddRow({
  userId,
  currentTimeframe,
  currentStartDate,
  currentEndDate,
  onTaskCreated,
  onPendingCreated,
  disabled = false,
}: WizardQuickAddRowProps): React.ReactElement {
  const [text, setText] = useState('');
  const [placeholderIndex, setPlaceholderIndex] = useState(0);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const trimmed = text.trim();
  const canSubmit = trimmed.length > 0 && !isSubmitting && !disabled;
  const placeholder = PLACEHOLDERS[placeholderIndex % PLACEHOLDERS.length];
  const deferPersist = onPendingCreated !== undefined;

  async function handleSubmit(): Promise<void> {
    if (!canSubmit) return;
    setIsSubmitting(true);
    try {
      let newTask: Task;

      if (deferPersist) {
        // ── Deferred-persist path (Bug #85) ────────────────────────────────
        // Build the task fully in memory. The wizard writes it atomically
        // alongside the board row at final board-save. Matches the NORMAL
        // branch in useCreateFormState's deferred path.
        const now = currentTimestamp();
        newTask = {
          id: generateUUID(),
          userId,
          title: trimmed,
          type: TaskType.NORMAL,
          isCompleted: false,
          totalCompletions: 0,
          totalInstances: 0,
          createdAt: now,
          updatedAt: now,
          version: 1,
          isDeleted: false,
          timeframe: currentTimeframe,
          startDate: currentStartDate,
          endDate: currentEndDate,
          // Wizard-born: hidden from library-browse until the board goes
          // active. Mirrors iOS CreateFormViewModel deferred path.
          createdInWizard: true,
        };
        const payload: PendingTaskPayload = {
          task: newTask,
          childTasks: [],
          childLinks: [],
        };
        onTaskCreated(newTask);
        onPendingCreated!(payload);
      } else {
        // ── Immediate-persist path ──────────────────────────────────────────
        newTask = await createTask(userId, {
          title: trimmed,
          type: TaskType.NORMAL,
          timeframe: currentTimeframe,
          startDate: currentStartDate,
          endDate: currentEndDate,
        });
        onTaskCreated(newTask);
      }

      // Reset and rotate placeholder — keep focus for rapid entry.
      setText('');
      setPlaceholderIndex((i) => i + 1);
      inputRef.current?.focus();
    } catch {
      // Swallow silently — same pattern as the iOS `RisoQuickAddRowView`
      // which relies on the DB throwing only on programming errors (not
      // transient network failures, since the DB is local-first). The
      // NewTaskSheet modal can be used as a fallback if the quick-add
      // ever hits an unrecoverable error.
    } finally {
      setIsSubmitting(false);
    }
  }

  function handleKeyDown(e: React.KeyboardEvent<HTMLInputElement>): void {
    if (e.key === 'Enter') {
      e.preventDefault();
      void handleSubmit();
    }
  }

  return (
    <div className={styles.row}>
      <input
        ref={inputRef}
        type="text"
        className={styles.input}
        placeholder={placeholder}
        value={text}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={handleKeyDown}
        aria-label="New normal task title"
        autoComplete="off"
        spellCheck
        disabled={isSubmitting || disabled}
      />
      <RisoButton
        kind="primary"
        size="small"
        onClick={() => void handleSubmit()}
        disabled={!canSubmit}
        aria-label="Add task"
        style={{ opacity: canSubmit ? 1 : 0.45, pointerEvents: canSubmit ? undefined : 'none' }}
      >
        Add
      </RisoButton>
    </div>
  );
}
