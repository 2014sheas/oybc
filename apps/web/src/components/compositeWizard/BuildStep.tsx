import { useEffect, useMemo, useState } from 'react';
import type { CompositeTask, Task } from '@oybc/shared';
import { OperatorType, TaskType, generateCounterTaskTitle } from '@oybc/shared';
import { CounterStepper } from '../CounterStepper';
import { TypeBadge } from '../TypeBadge';
import { FilterTabs } from '../FilterTabs';
import { SubtaskCard } from './SubtaskCard';
import {
  type SubtaskDraft,
  evaluateSubtaskReadiness,
} from './compositeSubtaskDraft';
import type { StepFormState } from '../progressStepUtils';
import styles from './BuildStep.module.css';

/** Preview payload for a composite: first few leaf titles + total. Used
 *  to power the library row's subtitle when the row is a composite. */
export interface CompositeLeafPreview {
  titles: string[];
  totalLeaves: number;
}

type LibraryFilter = 'all' | 'normal' | 'counting' | 'progress' | 'composite';

const FILTER_TABS: { value: LibraryFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'normal', label: 'Normal' },
  { value: 'counting', label: 'Counting' },
  { value: 'progress', label: 'Progress' },
  { value: 'composite', label: 'Composite' },
];

interface LibraryRow {
  id: string;
  title: string;
  type: 'normal' | 'counting' | 'progress' | 'composite';
  subtitle: string;
  usageHint: string;
  kind: 'task' | 'composite';
}

export interface BuildStepProps {
  subtasks: SubtaskDraft[];
  /** Operator chosen on Setup. Threshold is only meaningful for M_OF_N. */
  operator: OperatorType;
  /** Required-N target. Picked on this step so the user can see the
   *  subtask list while choosing. */
  threshold: number;
  onThresholdChange: (next: number) => void;
  allTasks: Task[];
  allCompositeTasks: CompositeTask[];
  /** taskId → count of distinct boards the task is placed on. */
  taskBoardCounts: Record<string, number>;
  /** taskId → number of non-deleted steps (progress tasks only). */
  taskStepCounts: Record<string, number>;
  /** compositeTaskId → number of leaf subtasks. */
  compositeSubtaskCounts: Record<string, number>;
  /** compositeTaskId → first few leaf titles for library row subtitles. */
  compositeLeafPreviews: Record<string, CompositeLeafPreview>;
  onUpdateSubtask: (id: string, updates: Partial<SubtaskDraft>) => void;
  onRemoveSubtask: (id: string) => void;
  onStepFieldChange: (subtaskId: string, stepId: string, field: keyof StepFormState, value: string) => void;
  onAddStep: (subtaskId: string) => void;
  onRemoveStep: (subtaskId: string, stepId: string) => void;
  /** Toggle a library item in/out of the composite. Add (not present) or
   *  remove (already an existing-mode subtask) decided by the parent. */
  onToggleLibraryItem: (id: string, kind: 'task' | 'composite') => void;
  onAddInline: () => void;
  onBack: () => void;
  onNext: () => void;
}

/**
 * Step 2 of the composite mini-wizard. Existing-task selections render
 * as flat rows (no card frame); inline-created subtasks keep their
 * card frame. The task library is rendered always-visible below the
 * selections — tapping a row toggles membership immediately, matching
 * the board wizard's Tasks-step pattern. No modal picker.
 */
export function BuildStep({
  subtasks,
  operator,
  threshold,
  onThresholdChange,
  allTasks,
  allCompositeTasks,
  taskBoardCounts,
  taskStepCounts,
  compositeSubtaskCounts,
  compositeLeafPreviews,
  onUpdateSubtask,
  onRemoveSubtask,
  onStepFieldChange,
  onAddStep,
  onRemoveStep,
  onToggleLibraryItem,
  onAddInline,
  onBack,
  onNext,
}: BuildStepProps): React.ReactElement {
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState<LibraryFilter>('all');

  /** Ids already included as existing-mode subtasks. Drives the row's
   *  checked state and the toggle semantics (click an already-checked
   *  row and it removes the matching subtask draft). */
  const checkedIds = useMemo(() => {
    const ids = new Set<string>();
    for (const s of subtasks) {
      if (s.mode === 'existing' && s.selectedId) ids.add(s.selectedId);
    }
    return ids;
  }, [subtasks]);

  const { readyCount } = useMemo(() => {
    let ready = 0;
    for (const s of subtasks) {
      // Existing-mode rows are ready by construction — they can only
      // exist when a concrete library id is attached. Inline-mode rows
      // still run the live readiness check.
      const r = evaluateSubtaskReadiness(s, new Set());
      if (r.ready) ready++;
    }
    return { readyCount: ready };
  }, [subtasks]);

  const hasMinimum = subtasks.length >= 2;
  const allReady = readyCount === subtasks.length && readyCount >= 2;
  const canAdvance = hasMinimum && allReady;

  const statusText: string = !hasMinimum
    ? `Add at least 2 subtasks (${subtasks.length} so far).`
    : !allReady
      ? `${subtasks.length - readyCount} card${subtasks.length - readyCount === 1 ? '' : 's'} still need attention.`
      : `${readyCount} subtask${readyCount === 1 ? '' : 's'} ready.`;

  // Stepper bounds track the actual subtask count. When the list
  // shrinks below the current threshold (e.g. user removes a subtask),
  // clamp silently — stepper + list are both on-screen so no toast.
  const stepperMax = Math.max(1, subtasks.length);
  useEffect(() => {
    if (operator !== OperatorType.M_OF_N) return;
    const target = Math.min(Math.max(1, threshold), stepperMax);
    if (target !== threshold) onThresholdChange(target);
  }, [operator, threshold, stepperMax, onThresholdChange]);

  // ─── Library rows ─────────────────────────────────────────────────────────

  const libraryRows = useMemo<LibraryRow[]>(() => {
    const taskRows: LibraryRow[] = allTasks.map((t) => {
      const boards = taskBoardCounts[t.id] ?? 0;
      return {
        id: t.id,
        title: t.title,
        type: t.type as 'normal' | 'counting' | 'progress',
        subtitle: buildTaskSubtitle(t, taskStepCounts),
        usageHint: boards === 0 ? 'not on any board' : `on ${boards} board${boards === 1 ? '' : 's'}`,
        kind: 'task',
      };
    });
    const compositeRows: LibraryRow[] = allCompositeTasks.map((ct) => {
      const leaves = compositeSubtaskCounts[ct.id] ?? 0;
      return {
        id: ct.id,
        title: ct.title,
        type: 'composite',
        subtitle: buildCompositeSubtitle(ct.id, compositeLeafPreviews),
        usageHint: `${leaves} subtask${leaves === 1 ? '' : 's'}`,
        kind: 'composite',
      };
    });
    return [...taskRows, ...compositeRows].sort((a, b) => a.title.localeCompare(b.title));
  }, [
    allTasks,
    allCompositeTasks,
    taskBoardCounts,
    taskStepCounts,
    compositeSubtaskCounts,
    compositeLeafPreviews,
  ]);

  const q = query.trim().toLowerCase();
  const visibleRows = libraryRows.filter((row) => {
    if (filter !== 'all' && row.type !== filter) return false;
    if (q.length === 0) return true;
    return row.title.toLowerCase().includes(q) || row.subtitle.toLowerCase().includes(q);
  });

  const showEmptyLibrary = libraryRows.length === 0;
  const showNoMatches = !showEmptyLibrary && visibleRows.length === 0;

  return (
    <div className={styles.container}>
      <div className={styles.statusRow}>
        <span className={canAdvance ? styles.statusReady : styles.statusWait}>
          {statusText}
        </span>
      </div>

      {operator === OperatorType.M_OF_N && (
        <div className={styles.thresholdRow}>
          <span className={styles.thresholdLabel}>Required to complete:</span>
          <CounterStepper
            value={threshold}
            min={1}
            max={stepperMax}
            onChange={onThresholdChange}
            label={subtasks.length > 0 ? `of ${subtasks.length}` : 'of your subtasks'}
          />
        </div>
      )}

      <div className={styles.subtaskList}>
        {subtasks.map((s) => (
          <SubtaskCard
            key={s.id}
            draft={s}
            allTasks={allTasks}
            allCompositeTasks={allCompositeTasks}
            taskBoardCounts={taskBoardCounts}
            taskStepCounts={taskStepCounts}
            compositeSubtaskCounts={compositeSubtaskCounts}
            compositeLeafPreviews={compositeLeafPreviews}
            onUpdate={(updates) => onUpdateSubtask(s.id, updates)}
            onRemove={() => onRemoveSubtask(s.id)}
            onStepFieldChange={(stepId, field, value) => onStepFieldChange(s.id, stepId, field, value)}
            onAddStep={() => onAddStep(s.id)}
            onRemoveStep={(stepId) => onRemoveStep(s.id, stepId)}
          />
        ))}

        {subtasks.length === 0 && (
          <div className={styles.emptyState}>
            No subtasks yet. Tap a row from your library below, or create one inline.
          </div>
        )}
      </div>

      <div className={styles.addRow}>
        <button type="button" className={styles.addButtonPrimary} onClick={onAddInline}>
          + Create new task
        </button>
      </div>

      {/* ─── Always-visible library ─── */}
      <div className={styles.librarySection}>
        <div className={styles.libraryHeader}>
          <h3 className={styles.libraryHeading}>Pick from your library</h3>
          <p className={styles.librarySubheading}>
            Tap a task to add or remove it from this composite.
          </p>
        </div>

        <div className={styles.searchRow}>
          <input
            type="search"
            className={styles.searchInput}
            placeholder="Search your tasks…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            aria-label="Search tasks"
          />
        </div>

        <FilterTabs
          tabs={FILTER_TABS}
          activeTab={filter}
          onTabChange={(v) => setFilter(v as LibraryFilter)}
        />

        <div className={styles.libraryList}>
          {showEmptyLibrary && (
            <div className={styles.libraryEmptyState}>
              Your library is empty — tap <strong>+ Create new task</strong> above to make one.
            </div>
          )}
          {showNoMatches && (
            <div className={styles.libraryEmptyState}>
              {q.length > 0
                ? `No matches for "${query.trim()}" in ${filter === 'all' ? 'All' : filter}.`
                : `No ${filter} tasks in your library — try a different filter.`}
            </div>
          )}
          {!showEmptyLibrary && !showNoMatches && (
            <ul className={styles.rowList}>
              {visibleRows.map((row) => {
                const checked = checkedIds.has(row.id);
                return (
                  <li key={row.id}>
                    <button
                      type="button"
                      className={checked ? styles.libraryRowChecked : styles.libraryRow}
                      onClick={() => onToggleLibraryItem(row.id, row.kind)}
                      aria-pressed={checked}
                    >
                      <span
                        className={checked ? styles.checkboxChecked : styles.checkbox}
                        aria-hidden="true"
                      >
                        {checked ? '✓' : ''}
                      </span>
                      <TypeBadge type={row.type} size="small" letterOnly />
                      <div className={styles.libraryRowCenter}>
                        <span className={styles.libraryRowTitle}>{row.title}</span>
                        {row.subtitle && (
                          <span className={styles.libraryRowSubtitle}>{row.subtitle}</span>
                        )}
                      </div>
                      <span className={styles.libraryRowUsage}>{row.usageHint}</span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </div>

      <div className={styles.footer}>
        <button type="button" className={styles.backButton} onClick={onBack}>
          ‹ Back
        </button>
        <button
          type="button"
          className={styles.nextButton}
          onClick={onNext}
          disabled={!canAdvance}
          title={canAdvance ? undefined : statusText}
        >
          Next ›
        </button>
      </div>
    </div>
  );
}

// ─── Helpers (ported from the retired LibraryPickerSheet) ─────────────────────

function buildTaskSubtitle(task: Task, taskStepCounts: Record<string, number>): string {
  if (task.type === TaskType.COUNTING) {
    const { action, maxCount, unit } = task;
    if (!action || !unit || maxCount === undefined) return '';
    const derived = generateCounterTaskTitle(action, maxCount, unit);
    return derived.toLowerCase() === task.title.trim().toLowerCase() ? '' : derived;
  }
  if (task.type === TaskType.PROGRESS) {
    const n = taskStepCounts[task.id] ?? 0;
    if (n === 0) return '';
    return `${n} step${n === 1 ? '' : 's'}`;
  }
  return '';
}

function buildCompositeSubtitle(
  compositeId: string,
  previews: Record<string, CompositeLeafPreview>,
): string {
  const preview = previews[compositeId];
  if (!preview) return '';
  const { titles, totalLeaves } = preview;
  if (titles.length === 0) return '';
  const visible = titles.join(', ');
  const hidden = totalLeaves - titles.length;
  return hidden > 0 ? `${visible}, +${hidden} more` : visible;
}
