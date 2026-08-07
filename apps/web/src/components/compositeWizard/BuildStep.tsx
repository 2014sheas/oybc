import { useEffect, useMemo, useState } from 'react';
import type { Task } from '@oybc/shared';
import { OperatorType, TaskType, generateCounterTaskTitle } from '@oybc/shared';
import { CounterStepper } from '../CounterStepper';
import { RisoChip, RisoTypeBadge } from '../riso';
import { SubtaskCard } from './SubtaskCard';
import {
  type SubtaskDraft,
  evaluateSubtaskReadiness,
} from './compositeSubtaskDraft';
import styles from './BuildStep.module.css';

/** Preview payload for a composite: first few leaf titles + total. Used
 *  to power the library row's subtitle when the row is a composite. */
export interface CompositeLeafPreview {
  titles: string[];
  totalLeaves: number;
}

type LibraryFilter = 'all' | 'normal' | 'counting' | 'compound';

const FILTER_TABS: { value: LibraryFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'normal', label: 'Normal' },
  { value: 'counting', label: 'Counting' },
  { value: 'compound', label: 'Compound' },
];

interface LibraryRow {
  id: string;
  title: string;
  type: 'normal' | 'counting' | 'compound';
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
  allCompositeTasks: Task[];
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
  /** Toggle a library item in/out of the composite. Add (not present) or
   *  remove (already an existing-mode subtask) decided by the parent. */
  onToggleLibraryItem: (id: string, kind: 'task' | 'composite') => void;
  onAddInline: () => void;
  onBack: () => void;
  onNext: () => void;
  /** Open an existing subtask's library detail (sheet over the wizard).
   *  Pulled up to the wizard root so the sheet state can live above the
   *  step-by-step navigation. */
  onOpenTask?: (taskId: string) => void;
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
  onToggleLibraryItem,
  onAddInline,
  onBack,
  onNext,
  onOpenTask,
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
      // Short usage hint — long forms ("not on any board", "on 3 boards")
      // were eating enough horizontal space on iPhone to truncate the
      // title; keep parity by trimming on web too.
      const usageHint = boards === 0 ? 'unused' : `${boards} board${boards === 1 ? '' : 's'}`;
      return {
        id: t.id,
        title: t.title,
        type: t.type as 'normal' | 'counting',
        subtitle: buildTaskSubtitle(t, taskStepCounts),
        usageHint,
        kind: 'task',
      };
    });
    const compositeRows: LibraryRow[] = allCompositeTasks.map((ct) => {
      const leaves = compositeSubtaskCounts[ct.id] ?? 0;
      return {
        id: ct.id,
        title: ct.title,
        type: 'compound',
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
  // Note: the 'compound' filter matches all compound tasks (they appear in the
  // compositeRows list with type='compound').

  const showEmptyLibrary = libraryRows.length === 0;
  const showNoMatches = !showEmptyLibrary && visibleRows.length === 0;

  return (
    <div className={styles.container}>
      {/* Prominent status banner — was a small top-right caption before,
       *  easy to miss. Now tied to canAdvance with a tinted background
       *  + icon so the gate message ("Add at least 2 subtasks") is
       *  impossible to overlook. */}
      <div
        className={canAdvance ? styles.statusBannerReady : styles.statusBannerWait}
        role="status"
      >
        <span className={styles.statusBannerIcon} aria-hidden="true">
          {canAdvance ? '✓' : 'ⓘ'}
        </span>
        <span>{statusText}</span>
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

      {/* Selections — labelled to match "PICK FROM YOUR LIBRARY" below
       *  so the two lists feel like paired zones rather than a floating
       *  row above the library. */}
      <div className={styles.selectionsSection}>
        <h3 className={styles.sectionHeading}>In this composite</h3>

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
              onOpenTask={onOpenTask}
            />
          ))}

          {subtasks.length === 0 && (
            <div className={styles.emptyState}>
              No subtasks. Tap a row below or use <strong>+ New task</strong>.
            </div>
          )}
        </div>
      </div>

      {/* ─── Always-visible library ─── */}
      <div className={styles.librarySection}>
        {/* Heading row with inline "+ New task" CTA on the right —
         *  mirrors the board wizard so "or create your own" lives
         *  with the library instead of floating between sections. */}
        <div className={styles.libraryHeaderRow}>
          <div className={styles.libraryHeader}>
            <h3 className={styles.sectionHeading}>Pick from your library</h3>
            <p className={styles.librarySubheading}>
              Tap a task to add or remove it.
            </p>
          </div>
          <button
            type="button"
            className={styles.newTaskButton}
            onClick={onAddInline}
          >
            + New task
          </button>
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

        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {FILTER_TABS.map((tab) => (
            <RisoChip
              key={tab.value}
              on={filter === tab.value}
              onClick={() => setFilter(tab.value as LibraryFilter)}
            >
              {tab.label}
            </RisoChip>
          ))}
        </div>

        <div className={styles.libraryList}>
          {showEmptyLibrary && (
            <div className={styles.libraryEmptyState}>
              Library is empty — tap <strong>+ New task</strong> to create one.
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
                      <RisoTypeBadge type={row.type} />
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
  if (task.type === TaskType.COMPOUND) {
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
