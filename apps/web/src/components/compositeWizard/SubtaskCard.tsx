import { useMemo } from 'react';
import type { Task } from '@oybc/shared';
import { TaskType, generateCounterTaskTitle, findLinkableCounter } from '@oybc/shared';
import { RisoTypeBadge, type RisoTaskType } from '../riso';
import { CountingStepFields } from '../CountingStepFields';
import { CounterLinkHint } from '../counters';
import type { CompositeLeafPreview } from './BuildStep';
import {
  type SubtaskDraft,
  type ExistingSubtaskDraft,
  type InlineSubtaskDraft,
  type InlineSubtaskType,
  evaluateSubtaskReadiness,
  hasInlineDirtyFields,
  switchInlineType,
} from './compositeSubtaskDraft';
import styles from './SubtaskCard.module.css';

/** Max title length — matches the shared CreateForm limits. */
const TITLE_MAX_LENGTH = 200;

const INLINE_TYPES: readonly InlineSubtaskType[] = ['normal', 'counting'] as const;

export interface SubtaskCardProps {
  /** The draft this card displays and mutates. */
  draft: SubtaskDraft;
  /** Library feeds — needed by existing-mode rows to look up their title + meta. */
  allTasks: Task[];
  allCompositeTasks: Task[];
  /** taskId → count of distinct boards the task is placed on. */
  taskBoardCounts: Record<string, number>;
  /** taskId → number of non-deleted steps (progress tasks only). */
  taskStepCounts: Record<string, number>;
  /** compositeTaskId → leaf (subtask) count. */
  compositeSubtaskCounts: Record<string, number>;
  /** compositeTaskId → first few leaf titles for the existing-row subtitle. */
  compositeLeafPreviews: Record<string, CompositeLeafPreview>;
  /** Called with a partial update to merge into the draft. */
  onUpdate: (updates: Partial<SubtaskDraft>) => void;
  /** Called when the user clicks remove. */
  onRemove: () => void;
  /** Called when the user wants to open the existing-mode task's library
   *  detail. Inline-mode subtasks ignore this — they're not yet saved
   *  Tasks. When omitted, the row's center area is non-interactive. */
  onOpenTask?: (taskId: string) => void;
}

/**
 * SubtaskCard — renders a single subtask of a composite. Existing-mode
 * selections render as a flat borderless row (no frame, no readiness
 * footer — they're ready by construction). Inline-created subtasks keep
 * their full card frame and the live readiness check that drives the
 * green/red border.
 */
export function SubtaskCard(props: SubtaskCardProps): React.ReactElement {
  if (props.draft.mode === 'existing') {
    return <ExistingFlatRow {...props} draft={props.draft} />;
  }
  return <InlineCard {...props} draft={props.draft} />;
}

// ─── Existing-mode: flat borderless row ──────────────────────────────────────

interface ExistingFlatRowProps extends SubtaskCardProps {
  draft: ExistingSubtaskDraft;
}

function ExistingFlatRow({
  draft,
  allTasks,
  allCompositeTasks,
  taskBoardCounts,
  taskStepCounts,
  compositeSubtaskCounts,
  compositeLeafPreviews,
  onRemove,
  onOpenTask,
}: ExistingFlatRowProps): React.ReactElement {
  const row = useMemo(() => {
    if (draft.selectionType === 'task') {
      const task = allTasks.find((t) => t.id === draft.selectedId);
      if (!task) return null;
      const boards = taskBoardCounts[task.id] ?? 0;
      // Compound tasks show the 'compound' badge.
      const badgeType = task.type === 'compound' ? 'compound' : task.type as 'normal' | 'counting';
      return {
        type: badgeType,
        title: task.title,
        subtitle: buildTaskSubtitle(task, taskStepCounts),
        usageHint: boards === 0 ? 'unused' : `${boards} board${boards === 1 ? '' : 's'}`,
      };
    }
    const ct = allCompositeTasks.find((c) => c.id === draft.selectedId);
    if (!ct) return null;
    const leaves = compositeSubtaskCounts[ct.id] ?? 0;
    return {
      type: 'compound' as const,
      title: ct.title,
      subtitle: buildCompositeSubtitle(ct.id, compositeLeafPreviews),
      usageHint: `${leaves} subtask${leaves === 1 ? '' : 's'}`,
    };
  }, [
    draft,
    allTasks,
    allCompositeTasks,
    taskBoardCounts,
    taskStepCounts,
    compositeSubtaskCounts,
    compositeLeafPreviews,
  ]);

  if (!row) {
    // Library row went missing (rare — e.g. the target task was deleted
    // from another tab while the composite wizard was open). Fall back
    // to a minimal remove-only row so the user can clean it up.
    return (
      <div className={styles.flatRow}>
        <div className={styles.flatCenter}>
          <span className={styles.flatTitle}>Unknown task</span>
          <span className={styles.flatSubtitle}>
            The selected library item is no longer available. Remove this row.
          </span>
        </div>
        <button type="button" className={styles.flatRemoveButton} onClick={onRemove} aria-label="Remove subtask">
          ×
        </button>
      </div>
    );
  }

  return (
    <div className={styles.flatRow}>
      <RisoTypeBadge type={row.type as RisoTaskType} />
      {onOpenTask ? (
        <button
          type="button"
          className={styles.flatCenterButton}
          onClick={() => onOpenTask(draft.selectedId)}
          aria-label={`Open ${row.title} in library`}
        >
          <span className={styles.flatTitle}>{row.title}</span>
          {row.subtitle && <span className={styles.flatSubtitle}>{row.subtitle}</span>}
        </button>
      ) : (
        <div className={styles.flatCenter}>
          <span className={styles.flatTitle}>{row.title}</span>
          {row.subtitle && <span className={styles.flatSubtitle}>{row.subtitle}</span>}
        </div>
      )}
      <span className={styles.flatUsage}>{row.usageHint}</span>
      <button
        type="button"
        className={styles.flatRemoveButton}
        onClick={onRemove}
        aria-label={`Remove ${row.title}`}
      >
        ×
      </button>
    </div>
  );
}

// ─── Inline-mode: full card frame (unchanged) ────────────────────────────────

interface InlineCardProps extends SubtaskCardProps {
  draft: InlineSubtaskDraft;
}

function InlineCard({
  draft,
  allTasks,
  onUpdate,
  onRemove,
}: InlineCardProps): React.ReactElement {
  const readiness = useMemo(
    () => evaluateSubtaskReadiness(draft, new Set()),
    [draft],
  );

  const cardClassName = [
    styles.card,
    readiness.ready ? styles.cardReady : styles.cardIncomplete,
  ].join(' ');

  return (
    <div className={cardClassName}>
      <div className={styles.header}>
        <span className={styles.modeLabel}>New task (inline)</span>
        <button type="button" className={styles.removeButton} onClick={onRemove}>
          Remove
        </button>
      </div>

      <InlineFields
        draft={draft}
        allTasks={allTasks}
        onUpdate={onUpdate}
      />

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
  allTasks: Task[];
  onUpdate: (updates: Partial<SubtaskDraft>) => void;
}

function InlineFields({
  draft,
  allTasks,
  onUpdate,
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
              const next = switchInlineType(draft, draft.pendingTypeSwitch!);
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
    const next = switchInlineType(draft, nextType);
    onUpdate(next);
  };

  return (
    <div className={styles.inlineFields}>
      <div
        className={styles.typePicker}
        role="group"
        aria-label="Task type"
      >
        {INLINE_TYPES.map((type) => (
          <button
            key={type}
            type="button"
            aria-pressed={draft.inlineType === type}
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
        <>
          <CountingStepFields
            idPrefix={`subtask-${draft.id}`}
            action={draft.action}
            maxCount={draft.maxCountStr}
            unit={draft.unit}
            onChange={(field, value) => {
              // Verb/Counting changes reset the auto-link opt-out — a fresh
              // pair should always start linked (mirrors CountingTemplatePicker).
              if (field === 'action') {
                onUpdate({ action: value, linkDisabled: false } as Partial<InlineSubtaskDraft>);
              } else if (field === 'unit') {
                onUpdate({ unit: value, linkDisabled: false } as Partial<InlineSubtaskDraft>);
              } else if (field === 'maxCount') {
                onUpdate({ maxCountStr: value } as Partial<InlineSubtaskDraft>);
              }
            }}
          />
          <InlineCounterLinkHint draft={draft} allTasks={allTasks} onUpdate={onUpdate} />
        </>
      )}

    </div>
  );
}

/**
 * R1 counters refresh — auto-link hint for the compound builder's inline
 * counting subtask. Computes the (verb, noun) match against the library
 * (`allTasks`, already loaded by `CompositeTaskWizard`) and renders
 * `CounterLinkHint` once a match + a valid goal exist. `CompositeTaskWizard.
 * handleCreate` re-derives the same match at submit time (guarded by
 * `draft.linkDisabled`) to set `sharedCounterId`/`baseline` on the inline-
 * created child — see `AutoCreateCompoundChildTask`.
 */
function InlineCounterLinkHint({
  draft,
  allTasks,
  onUpdate,
}: {
  draft: InlineSubtaskDraft;
  allTasks: Task[];
  onUpdate: (updates: Partial<SubtaskDraft>) => void;
}): React.ReactElement | null {
  const trimmedAction = draft.action.trim();
  const trimmedUnit = draft.unit.trim();
  const parsedGoal = parseInt(draft.maxCountStr, 10);
  const goalValid = Number.isInteger(parsedGoal) && parsedGoal > 0;

  const match = useMemo(
    () =>
      trimmedAction && trimmedUnit
        ? findLinkableCounter({ action: trimmedAction, unit: trimmedUnit }, allTasks)
        : null,
    [trimmedAction, trimmedUnit, allTasks],
  );

  if (!match || !goalValid) return null;

  const linked = !draft.linkDisabled;
  return (
    <CounterLinkHint
      counterName={match.name}
      lifetime={match.lifetime}
      goal={parsedGoal}
      linked={linked}
      onToggle={() => onUpdate({ linkDisabled: linked } as Partial<InlineSubtaskDraft>)}
    />
  );
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

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

function capitalize(value: string): string {
  if (value.length === 0) return value;
  return value.charAt(0).toUpperCase() + value.slice(1);
}
