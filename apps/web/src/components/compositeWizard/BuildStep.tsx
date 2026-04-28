import { useEffect, useMemo, useState } from 'react';
import type { Task } from '@oybc/shared';
import { OperatorType } from '@oybc/shared';
import { CounterStepper } from '../CounterStepper';
import { SubtaskCard } from './SubtaskCard';
import {
  LibraryPickerSheet,
  type CompositeLeafPreview,
  type LibraryDiff,
} from './LibraryPickerSheet';
import {
  type SubtaskDraft,
  evaluateSubtaskReadiness,
} from './compositeSubtaskDraft';
import type { StepFormState } from '../progressStepUtils';
import styles from './BuildStep.module.css';

export interface BuildStepProps {
  subtasks: SubtaskDraft[];
  /** Operator chosen on Setup. Threshold is only meaningful for M_OF_N. */
  operator: OperatorType;
  /** Required-N target. Now picked ON this step (not Setup) so the user
   *  can see the subtask list while choosing. */
  threshold: number;
  /** Threshold setter (lifted to the wizard so it persists across steps
   *  and survives operator toggles). */
  onThresholdChange: (next: number) => void;
  allTasks: Task[];
  allCompositeTasks: Task[];
  /** taskId → count of distinct boards the task is placed on. */
  taskBoardCounts: Record<string, number>;
  /** taskId → number of non-deleted steps (progress tasks only). */
  taskStepCounts: Record<string, number>;
  /** compositeTaskId → number of leaf subtasks. */
  compositeSubtaskCounts: Record<string, number>;
  /** compositeTaskId → first few leaf titles for sheet subtitles. */
  compositeLeafPreviews: Record<string, CompositeLeafPreview>;
  onUpdateSubtask: (id: string, updates: Partial<SubtaskDraft>) => void;
  onRemoveSubtask: (id: string) => void;
  onStepFieldChange: (subtaskId: string, stepId: string, field: keyof StepFormState, value: string) => void;
  onAddStep: (subtaskId: string) => void;
  onRemoveStep: (subtaskId: string, stepId: string) => void;
  /** Commit a library sheet diff: add new existing-mode drafts for each
   *  add, drop existing-mode drafts whose selectedId is in the remove set. */
  onCommitLibraryDiff: (diff: LibraryDiff) => void;
  onAddInline: () => void;
  onBack: () => void;
  onNext: () => void;
}

/**
 * Step 2 of the composite mini-wizard. Existing-task selections render
 * as flat rows (no card frame); a single `+ Add existing tasks` button
 * opens a sheet/modal for multi-check picking. Inline-created subtasks
 * keep their full card frame. Next is blocked until ≥2 cards are ready.
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
  onCommitLibraryDiff,
  onAddInline,
  onBack,
  onNext,
}: BuildStepProps): React.ReactElement {
  const [libraryOpen, setLibraryOpen] = useState(false);

  /** Ids already included as existing-mode subtasks. Drives the sheet's
   *  initial checkbox state and also dedup (a library item can't appear
   *  twice because the sheet's state is canonical). */
  const initialCheckedIds = useMemo(() => {
    const ids = new Set<string>();
    for (const s of subtasks) {
      if (s.mode === 'existing' && s.selectedId) ids.add(s.selectedId);
    }
    return ids;
  }, [subtasks]);

  const { readyCount } = useMemo(() => {
    let ready = 0;
    for (const s of subtasks) {
      // Existing-mode rows are ready by construction — they can only exist
      // when a concrete library id is attached. Inline-mode rows still use
      // the live readiness check.
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
  // clamp silently — the stepper and the list are both visible on the
  // same screen so no toast is needed. Min of 1 keeps the stepper
  // renderable even with a single subtask.
  const stepperMax = Math.max(1, subtasks.length);
  useEffect(() => {
    if (operator !== OperatorType.M_OF_N) return;
    const target = Math.min(Math.max(1, threshold), stepperMax);
    if (target !== threshold) onThresholdChange(target);
  }, [operator, threshold, stepperMax, onThresholdChange]);

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
            No subtasks yet. Add at least two from your library or create them inline below.
          </div>
        )}
      </div>

      <div className={styles.addRow}>
        <button
          type="button"
          className={styles.addButton}
          onClick={() => setLibraryOpen(true)}
        >
          + Add existing tasks
        </button>
        <button type="button" className={styles.addButtonPrimary} onClick={onAddInline}>
          + Create new task
        </button>
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

      {libraryOpen && (
        <LibraryPickerSheet
          allTasks={allTasks}
          allCompositeTasks={allCompositeTasks}
          initialCheckedIds={initialCheckedIds}
          taskBoardCounts={taskBoardCounts}
          taskStepCounts={taskStepCounts}
          compositeSubtaskCounts={compositeSubtaskCounts}
          compositeLeafPreviews={compositeLeafPreviews}
          onCommit={(diff) => {
            onCommitLibraryDiff(diff);
            setLibraryOpen(false);
          }}
          onCancel={() => setLibraryOpen(false)}
        />
      )}
    </div>
  );
}
