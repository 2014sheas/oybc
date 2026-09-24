import { useState } from 'react';
import {
  OperatorType,
  TaskType,
  compoundChildPickerCandidates,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { RisoSectionLabel } from '../riso';
import { OperatorSelector } from '../OperatorSelector';
import { CounterStepper } from '../CounterStepper';
import {
  childPatchFromTask,
  clampThreshold,
  keptChildTaskIds,
  liveChildren,
  newChildPatch,
  readsAsPreview,
  type ChildPatch,
  type TaskEditPatch,
} from '../../db/taskEditPatch';
import { MiniTypeBadge, type MiniBadgeType } from './MiniTypeBadge';
import { ExistingTaskPicker, type PickerInputsState } from './ExistingTaskPicker';
import styles from './PoolRowEditor.module.css';

export interface CompoundFieldsProps {
  /** The compound's staged structure (title is not edited here). */
  draft: TaskEditPatch;
  /** Receives the whole next draft after any rule / sub-task change. */
  onDraftChange: (next: TaskEditPatch) => void;
  /** The compound being edited — the link guard's `parentId`. */
  parentId: string;
  /**
   * Browsable library tasks (`computeBrowsableTasks` output — wizard drafts
   * and deleted rows already hidden). The "+ Existing task…" picker narrows
   * them to the eligible ones via `compoundChildPickerCandidates`.
   */
  libraryTasks: Task[];
  /** Live compound links across ALL compounds (for the loop check). */
  allLinks: CompoundChild[];
  /** Whether `libraryTasks` / `allLinks` have loaded (Task Detail loads them
   *  on open; the wizard already holds them). Default `loaded`. */
  pickerInputsState?: PickerInputsState;
}

/**
 * CompoundFields — the compound rule + sub-task editor: operator picker
 * (All of / Any of / At least N, with a threshold stepper), one card per
 * sub-task (title, and Action/Goal/Unit for counting sub-tasks), a delete
 * button per card, and "+ Normal sub-task" / "+ Counting sub-task" /
 * "+ Existing task…" (opens `ExistingTaskPicker`; a pick is appended as a
 * linked sub-task via `childPatchFromTask`).
 *
 * Shared by the wizard's inline pool-row editor (`PoolRowEditor`) and the
 * Task Detail edit sheet (`TaskEditSheet`). Fully controlled: every edit is
 * a pure function of `draft` handed to `onDraftChange`. Deleting a sub-task
 * clamps an "at least N" threshold to the remaining live count.
 */
export function CompoundFields({
  draft,
  onDraftChange,
  parentId,
  libraryTasks,
  allLinks,
  pickerInputsState = 'loaded',
}: CompoundFieldsProps): React.ReactElement {
  const [pickerOpen, setPickerOpen] = useState(false);
  const subCount = liveChildren(draft).length;
  const operator = draft.operator ?? OperatorType.AND;
  const threshold = draft.threshold ?? 2;

  function handleOperatorChange(next: OperatorType): void {
    if (next === OperatorType.M_OF_N) {
      onDraftChange({ ...draft, operator: next, threshold: draft.threshold ?? clampThreshold(2, subCount) });
    } else {
      onDraftChange({ ...draft, operator: next, threshold: undefined });
    }
  }

  function updateChild(id: string, patch: Partial<ChildPatch>): void {
    onDraftChange({
      ...draft,
      children: draft.children.map((c) => (c.id === id ? { ...c, ...patch } : c)),
    });
  }

  function removeChild(id: string): void {
    const nextChildren = draft.children.filter((c) => c.id !== id);
    let nextThreshold = draft.threshold;
    if (draft.operator === OperatorType.M_OF_N) {
      const kept = nextChildren.filter((c) => !c.markedDeleted && c.title.trim().length > 0);
      nextThreshold = clampThreshold(nextThreshold ?? 2, kept.length);
    }
    onDraftChange({ ...draft, children: nextChildren, threshold: nextThreshold });
  }

  function addChild(isCounting: boolean): void {
    onDraftChange({ ...draft, children: [...draft.children, newChildPatch(isCounting)] });
  }

  function pickExisting(task: Task): void {
    setPickerOpen(false);
    onDraftChange({ ...draft, children: [...draft.children, childPatchFromTask(task)] });
  }

  return (
    <div className={styles.compoundSection}>
      <div className={styles.ruleGroup}>
        <RisoSectionLabel variant="kicker">Counts as done when…</RisoSectionLabel>
        <OperatorSelector selectedOperator={operator} onOperatorChange={handleOperatorChange} />
        {operator === OperatorType.M_OF_N && (
          <CounterStepper
            value={clampThreshold(threshold, subCount)}
            min={1}
            max={Math.max(1, subCount)}
            onChange={(v) => onDraftChange({ ...draft, threshold: v })}
            label={`of ${subCount} sub-task${subCount === 1 ? '' : 's'}`}
          />
        )}
      </div>

      <RisoSectionLabel variant="kicker">Sub-tasks</RisoSectionLabel>
      <div className={styles.subtaskList}>
        {draft.children.map((child, i) => (
          <SubtaskCardRow key={child.id} index={i + 1} child={child} onUpdate={(p) => updateChild(child.id, p)} onRemove={() => removeChild(child.id)} />
        ))}
      </div>

      <div className={styles.addRow}>
        <button type="button" className={styles.addButton} onClick={() => addChild(false)}>
          + Normal sub-task
        </button>
        <button type="button" className={styles.addButton} onClick={() => addChild(true)}>
          + Counting sub-task
        </button>
        <button type="button" className={styles.addButton} onClick={() => setPickerOpen(true)}>
          + Existing task…
        </button>
        <span className={styles.subtaskNote}>
          A sub-task&apos;s type is fixed once added. Deleting a sub-task unlinks it — if it lives on another board it stays in your library.
        </span>
      </div>

      {pickerOpen && (
        <ExistingTaskPicker
          tasks={compoundChildPickerCandidates(parentId, libraryTasks, allLinks, keptChildTaskIds(draft))}
          onPick={pickExisting}
          onCancel={() => setPickerOpen(false)}
          status={pickerInputsState}
        />
      )}
    </div>
  );
}

interface SubtaskCardRowProps {
  index: number;
  child: ChildPatch;
  onUpdate: (patch: Partial<ChildPatch>) => void;
  onRemove: () => void;
}

function SubtaskCardRow({ index, child, onUpdate, onRemove }: SubtaskCardRowProps): React.ReactElement {
  const subBadge = subtaskBadge(child);
  return (
    <div className={styles.subtaskCard}>
      <div className={styles.subtaskCardRow}>
        <span className={styles.subtaskIndex}>{index}</span>
        <input
          className={styles.subtaskTitleField}
          value={child.title}
          onChange={(e) => onUpdate({ title: e.target.value })}
          placeholder="Sub-task title"
          aria-label={`Sub-task ${index} title`}
        />
        <MiniTypeBadge type={subBadge.type} size="sub" label={subBadge.label} />
        <button type="button" className={styles.subtaskRemove} onClick={onRemove} aria-label="Delete sub-task">
          ✕
        </button>
      </div>
      {child.isCounting && (
        <div className={styles.subtaskCountingRow}>
          <input
            className={styles.subtaskField}
            style={{ flex: 1.4 }}
            value={child.action}
            onChange={(e) => onUpdate({ action: e.target.value })}
            placeholder="e.g. Run"
            aria-label={`Sub-task ${index} action`}
          />
          <input
            className={styles.subtaskField}
            style={{ flex: 0.6 }}
            type="number"
            min="1"
            value={child.goal}
            onChange={(e) => onUpdate({ goal: e.target.value })}
            placeholder="5"
            aria-label={`Sub-task ${index} goal`}
          />
          <input
            className={styles.subtaskField}
            style={{ flex: 0.8 }}
            value={child.unit}
            onChange={(e) => onUpdate({ unit: e.target.value })}
            placeholder="km"
            aria-label={`Sub-task ${index} unit`}
          />
          {readsAsPreview(child.action, child.goal, child.unit) && (
            <span className={styles.subtaskReadsAs}>{readsAsPreview(child.action, child.goal, child.unit)}</span>
          )}
        </div>
      )}
    </div>
  );
}

/**
 * The card badge for a sub-task: its own type (a picked nested compound
 * badges "C"; it edits only its title — no counting fields — and ✕ unlinks
 * it) with a matching accessible name.
 */
function subtaskBadge(child: ChildPatch): { type: MiniBadgeType; label: string } {
  if (child.childType === TaskType.COMPOUND) return { type: 'compound', label: 'Compound sub-task' };
  if (child.isCounting) return { type: 'counting', label: 'Counting sub-task' };
  return { type: 'normal', label: 'Normal sub-task' };
}
