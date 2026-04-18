import { useMemo } from 'react';
import type { CompositeTask, Task } from '@oybc/shared';
import { CountingStepFields } from '../CountingStepFields';
import { ProgressStepRow } from '../ProgressStepRow';
import { type StepFormState, createEmptyStep } from '../progressStepUtils';
import { ExistingTaskPicker, type CompositeLeafPreview } from './ExistingTaskPicker';
import {
  type SubtaskDraft,
  type InlineSubtaskDraft,
  type InlineSubtaskType,
  evaluateSubtaskReadiness,
  hasInlineDirtyFields,
  switchInlineType,
} from './compositeSubtaskDraft';
import styles from './SubtaskCard.module.css';

/** Max title length — matches the shared CreateForm limits. */
const TITLE_MAX_LENGTH = 200;

const INLINE_TYPES: readonly InlineSubtaskType[] = ['normal', 'counting', 'progress'] as const;

export interface SubtaskCardProps {
  /** The draft this card displays and mutates. */
  draft: SubtaskDraft;
  /** Full library — filtered at render time to exclude already-picked ids. */
  allTasks: Task[];
  allCompositeTasks: CompositeTask[];
  /** taskId → count of distinct boards the task is placed on. */
  taskBoardCounts: Record<string, number>;
  /** taskId → number of non-deleted steps (progress tasks only). */
  taskStepCounts: Record<string, number>;
  /** compositeTaskId → leaf (subtask) count. */
  compositeSubtaskCounts: Record<string, number>;
  /** compositeTaskId → first few leaf titles for the picker subtitle. */
  compositeLeafPreviews: Record<string, CompositeLeafPreview>;
  /** Ids already picked by OTHER cards in the same composite. Used to
   *  filter this card's existing-mode dropdown so duplicates are blocked
   *  at selection time, not at submit time. */
  excludedIds: Set<string>;
  /** Called with a partial update to merge into the draft. */
  onUpdate: (updates: Partial<SubtaskDraft>) => void;
  /** Called when the user clicks remove. */
  onRemove: () => void;
  /** Progress-subtask step mutators — hoisted to the parent so the
   *  composite form's single `subtasks` state stays canonical. */
  onStepFieldChange: (stepId: string, field: keyof StepFormState, value: string) => void;
  onAddStep: () => void;
  onRemoveStep: (stepId: string) => void;
}

/**
 * SubtaskCard — Persistent edit surface for one subtask of a composite.
 *
 * Replaces the legacy "fill fields → click Done → collapse to chip"
 * dance with a card that is always in its editable form. A live
 * readiness check drives both a green-border success state and a plain-
 * English "what's missing" message, so users don't need to submit to
 * discover problems.
 *
 * When a user clicks a different inline type while their current fields
 * are dirty, the card swaps into a small inline confirmation panel
 * instead of silently wiping the fields — accepting the switch clears
 * the old type's values, cancelling leaves them intact.
 */
export function SubtaskCard({
  draft,
  allTasks,
  allCompositeTasks,
  taskBoardCounts,
  taskStepCounts,
  compositeSubtaskCounts,
  compositeLeafPreviews,
  excludedIds,
  onUpdate,
  onRemove,
  onStepFieldChange,
  onAddStep,
  onRemoveStep,
}: SubtaskCardProps): React.ReactElement {
  const readiness = useMemo(
    () => evaluateSubtaskReadiness(draft, excludedIds),
    [draft, excludedIds],
  );

  const cardClassName = [
    styles.card,
    readiness.ready ? styles.cardReady : styles.cardIncomplete,
  ].join(' ');

  return (
    <div className={cardClassName}>
      <div className={styles.header}>
        <span className={styles.modeLabel}>
          {draft.mode === 'existing' ? 'Existing task' : 'New task (inline)'}
        </span>
        <button type="button" className={styles.removeButton} onClick={onRemove}>
          Remove
        </button>
      </div>

      {draft.mode === 'existing' ? (
        <ExistingTaskPicker
          selectedId={draft.selectedId}
          allTasks={allTasks}
          allCompositeTasks={allCompositeTasks}
          excludedIds={excludedIds}
          taskBoardCounts={taskBoardCounts}
          taskStepCounts={taskStepCounts}
          compositeSubtaskCounts={compositeSubtaskCounts}
          compositeLeafPreviews={compositeLeafPreviews}
          onSelect={(selectedId, kind) => {
            onUpdate({
              selectedId,
              selectionType: kind === 'composite' ? 'composite' : 'task',
            });
          }}
        />
      ) : (
        <InlineFields
          draft={draft}
          onUpdate={onUpdate}
          onStepFieldChange={onStepFieldChange}
          onAddStep={onAddStep}
          onRemoveStep={onRemoveStep}
        />
      )}

      <div
        className={
          readiness.ready ? styles.readinessReady : styles.readinessIncomplete
        }
      >
        <span className={styles.readinessIcon} aria-hidden="true">
          {readiness.ready ? '✓' : '•'}
        </span>
        <span>{readiness.ready ? 'Ready' : readiness.message}</span>
      </div>
    </div>
  );
}

// ─── Inline-mode fields ──────────────────────────────────────────────────────

interface InlineFieldsProps {
  draft: InlineSubtaskDraft;
  onUpdate: (updates: Partial<SubtaskDraft>) => void;
  onStepFieldChange: (stepId: string, field: keyof StepFormState, value: string) => void;
  onAddStep: () => void;
  onRemoveStep: (stepId: string) => void;
}

function InlineFields({
  draft,
  onUpdate,
  onStepFieldChange,
  onAddStep,
  onRemoveStep,
}: InlineFieldsProps): React.ReactElement {
  // Type-switch confirm panel takes over when a pending switch is set.
  if (draft.pendingTypeSwitch) {
    const targetLabel = capitalize(draft.pendingTypeSwitch);
    const currentLabel = capitalize(draft.inlineType);
    return (
      <div className={styles.switchConfirmPanel}>
        <p className={styles.switchConfirmText}>
          Switching to <strong>{targetLabel}</strong> will clear the fields
          you've filled for <strong>{currentLabel}</strong>.
        </p>
        <div className={styles.switchConfirmActions}>
          <button
            type="button"
            className={styles.switchCancelButton}
            onClick={() => onUpdate({ pendingTypeSwitch: undefined } as Partial<InlineSubtaskDraft>)}
          >
            Keep {currentLabel}
          </button>
          <button
            type="button"
            className={styles.switchConfirmButton}
            onClick={() => {
              const next = switchInlineType(draft, draft.pendingTypeSwitch!, () => [createEmptyStep()]);
              onUpdate(next);
            }}
          >
            Switch to {targetLabel}
          </button>
        </div>
      </div>
    );
  }

  const handleTypeClick = (nextType: InlineSubtaskType): void => {
    if (nextType === draft.inlineType) return;
    if (hasInlineDirtyFields(draft)) {
      onUpdate({ pendingTypeSwitch: nextType } as Partial<InlineSubtaskDraft>);
      return;
    }
    const next = switchInlineType(draft, nextType, () => [createEmptyStep()]);
    onUpdate(next);
  };

  return (
    <div className={styles.inlineFields}>
      <div className={styles.typePicker} role="tablist" aria-label="Task type">
        {INLINE_TYPES.map((type) => (
          <button
            key={type}
            type="button"
            role="tab"
            aria-selected={draft.inlineType === type}
            className={
              draft.inlineType === type ? styles.typeButtonActive : styles.typeButton
            }
            onClick={() => handleTypeClick(type)}
          >
            {capitalize(type)}
          </button>
        ))}
      </div>

      <div className={styles.fieldGroup}>
        <label className={styles.label} htmlFor={`subtask-title-${draft.id}`}>
          Title
          {draft.inlineType === 'counting' && (
            <span className={styles.optionalHint}> (auto-generated from action + count + unit if blank)</span>
          )}
        </label>
        <input
          id={`subtask-title-${draft.id}`}
          type="text"
          className={styles.titleInput}
          value={draft.title}
          onChange={(e) => onUpdate({ title: e.target.value } as Partial<InlineSubtaskDraft>)}
          placeholder={
            draft.inlineType === 'counting'
              ? 'Optional — leave blank to auto-name'
              : 'Enter task title'
          }
          maxLength={TITLE_MAX_LENGTH}
        />
      </div>

      {draft.inlineType === 'counting' && (
        <CountingStepFields
          idPrefix={`subtask-${draft.id}`}
          action={draft.action}
          maxCount={draft.maxCountStr}
          unit={draft.unit}
          onChange={(field, value) => {
            if (field === 'action') onUpdate({ action: value } as Partial<InlineSubtaskDraft>);
            else if (field === 'unit') onUpdate({ unit: value } as Partial<InlineSubtaskDraft>);
            else if (field === 'maxCount') onUpdate({ maxCountStr: value } as Partial<InlineSubtaskDraft>);
          }}
        />
      )}

      {draft.inlineType === 'progress' && (
        <div className={styles.stepsContainer}>
          <span className={styles.stepsLabel}>Steps</span>
          {draft.steps.map((step, idx) => (
            <ProgressStepRow
              key={step.id}
              index={idx}
              idPrefix={`subtask-${draft.id}-step-${step.id}`}
              step={step}
              canRemove={draft.steps.length > 1}
              onFieldChange={(field, value) => onStepFieldChange(step.id, field, value)}
              onRemove={() => onRemoveStep(step.id)}
            />
          ))}
          <button type="button" className={styles.addStepButton} onClick={onAddStep}>
            + Add step
          </button>
        </div>
      )}
    </div>
  );
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function capitalize(value: string): string {
  if (value.length === 0) return value;
  return value.charAt(0).toUpperCase() + value.slice(1);
}
