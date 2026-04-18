import { useMemo } from 'react';
import type { CompositeTask, Task } from '@oybc/shared';
import { SubtaskCard } from './SubtaskCard';
import type { CompositeLeafPreview } from './ExistingTaskPicker';
import {
  type SubtaskDraft,
  evaluateSubtaskReadiness,
} from './compositeSubtaskDraft';
import type { StepFormState } from '../progressStepUtils';
import styles from './BuildStep.module.css';

export interface BuildStepProps {
  subtasks: SubtaskDraft[];
  allTasks: Task[];
  allCompositeTasks: CompositeTask[];
  /** taskId → count of distinct boards the task is placed on. Surfaces
   *  in the existing-task picker as "on N boards" so users can spot
   *  high-usage tasks without leaving the wizard. */
  taskBoardCounts: Record<string, number>;
  /** taskId → number of non-deleted steps (progress tasks only). */
  taskStepCounts: Record<string, number>;
  /** compositeTaskId → number of leaf subtasks. */
  compositeSubtaskCounts: Record<string, number>;
  /** compositeTaskId → first few leaf titles for the picker subtitle. */
  compositeLeafPreviews: Record<string, CompositeLeafPreview>;
  onUpdateSubtask: (id: string, updates: Partial<SubtaskDraft>) => void;
  onRemoveSubtask: (id: string) => void;
  onStepFieldChange: (subtaskId: string, stepId: string, field: keyof StepFormState, value: string) => void;
  onAddStep: (subtaskId: string) => void;
  onRemoveStep: (subtaskId: string, stepId: string) => void;
  onAddExisting: () => void;
  onAddInline: () => void;
  onBack: () => void;
  onNext: () => void;
}

/**
 * Step 2 of the composite mini-wizard. Subtask card list plus two
 * primary "add" buttons; Next is blocked until ≥2 cards are ready and
 * no dup existing-task selections are detected.
 */
export function BuildStep({
  subtasks,
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
  onAddExisting,
  onAddInline,
  onBack,
  onNext,
}: BuildStepProps): React.ReactElement {
  // Collect picked ids once; each card receives a set excluding its own
  // selection so the picker doesn't drop the user's current choice.
  const allSelectedIds = useMemo(() => {
    const ids = new Set<string>();
    for (const s of subtasks) {
      if (s.mode === 'existing' && s.selectedId) ids.add(s.selectedId);
    }
    return ids;
  }, [subtasks]);

  const { readyCount, hasDuplicate } = useMemo(() => {
    let ready = 0;
    const seen = new Set<string>();
    let dup = false;
    for (const s of subtasks) {
      const others = new Set(allSelectedIds);
      if (s.mode === 'existing' && s.selectedId) others.delete(s.selectedId);
      const r = evaluateSubtaskReadiness(s, others);
      if (r.ready) ready++;
      if (s.mode === 'existing' && s.selectedId) {
        if (seen.has(s.selectedId)) dup = true;
        seen.add(s.selectedId);
      }
    }
    return { readyCount: ready, hasDuplicate: dup };
  }, [subtasks, allSelectedIds]);

  const hasMinimum = subtasks.length >= 2;
  const allReady = readyCount === subtasks.length && readyCount >= 2;
  const canAdvance = hasMinimum && allReady && !hasDuplicate;

  const statusText: string = !hasMinimum
    ? `Add at least 2 subtasks (${subtasks.length} so far).`
    : hasDuplicate
      ? 'Remove the duplicate selection to continue.'
      : !allReady
        ? `${subtasks.length - readyCount} card${subtasks.length - readyCount === 1 ? '' : 's'} still need attention.`
        : `${readyCount} subtask${readyCount === 1 ? '' : 's'} ready.`;

  return (
    <div className={styles.container}>
      <div className={styles.statusRow}>
        <span className={canAdvance ? styles.statusReady : styles.statusWait}>
          {statusText}
        </span>
      </div>

      <div className={styles.subtaskList}>
        {subtasks.map((s) => {
          const excluded = new Set(allSelectedIds);
          if (s.mode === 'existing' && s.selectedId) excluded.delete(s.selectedId);
          return (
            <SubtaskCard
              key={s.id}
              draft={s}
              allTasks={allTasks}
              allCompositeTasks={allCompositeTasks}
              taskBoardCounts={taskBoardCounts}
              taskStepCounts={taskStepCounts}
              compositeSubtaskCounts={compositeSubtaskCounts}
              compositeLeafPreviews={compositeLeafPreviews}
              excludedIds={excluded}
              onUpdate={(updates) => onUpdateSubtask(s.id, updates)}
              onRemove={() => onRemoveSubtask(s.id)}
              onStepFieldChange={(stepId, field, value) => onStepFieldChange(s.id, stepId, field, value)}
              onAddStep={() => onAddStep(s.id)}
              onRemoveStep={(stepId) => onRemoveStep(s.id, stepId)}
            />
          );
        })}

        {subtasks.length === 0 && (
          <div className={styles.emptyState}>
            No subtasks yet. Add at least two from your library or create them inline below.
          </div>
        )}
      </div>

      <div className={styles.addRow}>
        <button type="button" className={styles.addButton} onClick={onAddExisting}>
          + Add existing task
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
    </div>
  );
}
