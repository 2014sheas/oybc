import { OperatorType, TaskType } from '@oybc/shared';
import { RisoButton, RisoIcon, RisoSectionLabel } from '../riso';
import { OperatorSelector } from '../OperatorSelector';
import { CounterStepper } from '../CounterStepper';
import {
  clampThreshold,
  countingPreview,
  liveChildren,
  newChildPatch,
  readsAsPreview,
  validatePatch,
  type ChildPatch,
  type TaskEditPatch,
} from '../../db/taskEditPatch';
import styles from './PoolRowEditor.module.css';

/** Single-letter type indicator (N / C / K) — matches the design handoff's
 *  compact badge vocabulary (`BADGE` map in the prototype), distinct from
 *  `TypeBadge`'s 4-letter list-row abbreviation. Achievement never reaches
 *  here (read-only in the pool, no pencil). */
const MINI_BADGE: Record<'normal' | 'counting' | 'compound', { letter: string; className: string }> = {
  normal: { letter: 'N', className: styles.miniBadgeNormal },
  counting: { letter: 'C', className: styles.miniBadgeCounting },
  compound: { letter: 'K', className: styles.miniBadgeCompound },
};

function MiniTypeBadge({ type, size }: { type: 'normal' | 'counting' | 'compound'; size: 'header' | 'sub' }): React.ReactElement {
  const meta = MINI_BADGE[type];
  return (
    <span className={`${styles.miniBadge} ${size === 'header' ? styles.miniBadgeHeader : styles.miniBadgeSub} ${meta.className}`}>
      {meta.letter}
    </span>
  );
}

const HEADER_LABEL: Record<TaskType, string> = {
  [TaskType.NORMAL]: 'Normal task',
  [TaskType.COUNTING]: 'Counting task',
  [TaskType.COMPOUND]: 'Compound task',
  [TaskType.ACHIEVEMENT]: 'Achievement task',
};

export interface PoolRowEditorProps {
  taskType: TaskType;
  draft: TaskEditPatch;
  onDraftChange: (next: TaskEditPatch) => void;
  onSave: () => void;
  onDiscard: () => void;
  /**
   * Number of OTHER boards this task is currently placed on (library usage,
   * BEFORE the board being created exists). Drives the footer staging
   * line's "…and on N other boards" vs. "…applied everywhere this task is
   * used" copy — mirrors the design handoff's `everywhereLine`.
   */
  usedOnBoardCount: number;
}

/**
 * PoolRowEditor — the inline pool-row editor (Inline Task Editing, web
 * PR-2). Replaces a resting `PoolList` row in place: paper-2 fill with a
 * 4px blue left rail, a hairline header strip ("EDITING · <TYPE>" + the
 * Esc/⌘↵ hint), Title (+ Action/Goal/Unit on one line for Counting, +
 * live "Reads as" preview), the Compound sub-task editor (operator picker
 * + sub-task cards + add buttons), a footer staging line + validation
 * message, and Discard / Save actions.
 *
 * Edits are staged only — `onSave` hands the current `draft` up to the
 * wizard's `stagedEdits` map; nothing touches the DB until the board is
 * created (`persistWizardBoardRows` / `persistWizardPendingTasksAndStagedEdits`
 * apply it atomically — see `db/operations/wizardBoard.ts`).
 *
 * Current-iOS vocabulary throughout (NOT the handoff's retired "steps" /
 * "In order" terms): **sub-tasks**, an operator picker (All of / Any of /
 * At least N — reusing the existing `OperatorSelector`), "+ Normal
 * sub-task" / "+ Counting sub-task".
 */
export function PoolRowEditor({
  taskType,
  draft,
  onDraftChange,
  onSave,
  onDiscard,
  usedOnBoardCount,
}: PoolRowEditorProps): React.ReactElement {
  const validationMessage = validatePatch(draft, taskType);
  const isBlocked = validationMessage !== null;

  function handleKeyDown(e: React.KeyboardEvent<HTMLDivElement>): void {
    if (e.key === 'Escape') {
      e.stopPropagation();
      onDiscard();
      return;
    }
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault();
      if (!isBlocked) onSave();
    }
  }

  const everywhereLine =
    usedOnBoardCount > 0
      ? `Staged until you create the board. It then changes here and on ${usedOnBoardCount} other board${usedOnBoardCount === 1 ? '' : 's'}.`
      : 'Staged until you create the board, then applied everywhere this task is used.';

  function updateChild(id: string, patch: Partial<ChildPatch>): void {
    onDraftChange({
      ...draft,
      children: draft.children.map((c) => (c.id === id ? { ...c, ...patch } : c)),
    });
  }

  function removeChild(id: string): void {
    const nextChildren = draft.children.filter((c) => c.id !== id);
    let threshold = draft.threshold;
    if (draft.operator === OperatorType.M_OF_N) {
      const kept = nextChildren.filter((c) => !c.markedDeleted && c.title.trim().length > 0);
      threshold = clampThreshold(threshold ?? 2, kept.length);
    }
    onDraftChange({ ...draft, children: nextChildren, threshold });
  }

  function addChild(isCounting: boolean): void {
    onDraftChange({ ...draft, children: [...draft.children, newChildPatch(isCounting)] });
  }

  return (
    <div className={styles.editor} onKeyDown={handleKeyDown}>
      <div className={styles.header}>
        <MiniTypeBadge type={badgeTypeFor(taskType)} size="header" />
        <span className={styles.headerLabel}>Editing · {HEADER_LABEL[taskType].toUpperCase()}</span>
        <span className={styles.headerHint}>Esc to discard · ⌘↵ to save</span>
      </div>

      <div className={styles.body}>
        <div className={styles.titleRow}>
          <div className={styles.titleField}>
            <RisoSectionLabel variant="kicker">Title</RisoSectionLabel>
            <input
              className={styles.field}
              value={draft.title}
              onChange={(e) => onDraftChange({ ...draft, title: e.target.value })}
              autoFocus
              placeholder="Task title"
              aria-label="Task title"
            />
          </div>

          {taskType === TaskType.COUNTING && (
            <div className={styles.countingTrio}>
              <div className={styles.actionField}>
                <RisoSectionLabel variant="kicker">Action</RisoSectionLabel>
                <input
                  className={styles.field}
                  value={draft.action}
                  onChange={(e) => onDraftChange({ ...draft, action: e.target.value })}
                  placeholder="e.g. Run"
                  aria-label="Action"
                />
              </div>
              <div className={styles.goalField}>
                <RisoSectionLabel variant="kicker">Goal</RisoSectionLabel>
                <input
                  className={styles.field}
                  type="number"
                  min="1"
                  value={draft.goal}
                  onChange={(e) => onDraftChange({ ...draft, goal: e.target.value })}
                  placeholder="5"
                  aria-label="Goal"
                />
              </div>
              <div className={styles.unitField}>
                <RisoSectionLabel variant="kicker">Unit</RisoSectionLabel>
                <input
                  className={styles.field}
                  value={draft.unit}
                  onChange={(e) => onDraftChange({ ...draft, unit: e.target.value })}
                  placeholder="km"
                  aria-label="Unit"
                />
              </div>
            </div>
          )}
        </div>

        {taskType === TaskType.COUNTING && countingPreview(draft) && (
          <div className={styles.readsAs}>{countingPreview(draft)}</div>
        )}

        {taskType === TaskType.COMPOUND && (
          <CompoundFields draft={draft} onDraftChange={onDraftChange} onUpdateChild={updateChild} onRemoveChild={removeChild} onAddChild={addChild} />
        )}

        <div className={styles.footer}>
          <span className={styles.stagingLine}>
            <RisoIcon name="shield" size={14} />
            {everywhereLine}
          </span>
          {isBlocked && <span className={styles.errorText}>{validationMessage}</span>}
          <div className={styles.actions}>
            <RisoButton kind="neutral" onClick={onDiscard}>
              Discard
            </RisoButton>
            <RisoButton kind="primary" onClick={onSave} disabled={isBlocked}>
              Save task
            </RisoButton>
          </div>
        </div>
      </div>
    </div>
  );
}

function badgeTypeFor(type: TaskType): 'normal' | 'counting' | 'compound' {
  return type === TaskType.COUNTING ? 'counting' : type === TaskType.COMPOUND ? 'compound' : 'normal';
}

interface CompoundFieldsProps {
  draft: TaskEditPatch;
  onDraftChange: (next: TaskEditPatch) => void;
  onUpdateChild: (id: string, patch: Partial<ChildPatch>) => void;
  onRemoveChild: (id: string) => void;
  onAddChild: (isCounting: boolean) => void;
}

function CompoundFields({ draft, onDraftChange, onUpdateChild, onRemoveChild, onAddChild }: CompoundFieldsProps): React.ReactElement {
  const subCount = liveChildren(draft).length;
  const operator = draft.operator ?? OperatorType.AND;
  const threshold = draft.threshold ?? 2;

  function handleOperatorChange(next: OperatorType): void {
    if (next === OperatorType.M_OF_N) {
      onDraftChange({ ...draft, operator: next, threshold: draft.threshold ?? Math.max(1, Math.min(2, subCount)) });
    } else {
      onDraftChange({ ...draft, operator: next, threshold: undefined });
    }
  }

  return (
    <div className={styles.compoundSection}>
      <div className={styles.ruleGroup}>
        <RisoSectionLabel variant="kicker">Counts as done when…</RisoSectionLabel>
        <OperatorSelector selectedOperator={operator} onOperatorChange={handleOperatorChange} />
        {operator === OperatorType.M_OF_N && (
          <CounterStepper
            value={Math.min(threshold, Math.max(1, subCount))}
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
          <SubtaskCardRow key={child.id} index={i + 1} child={child} onUpdate={(p) => onUpdateChild(child.id, p)} onRemove={() => onRemoveChild(child.id)} />
        ))}
      </div>

      <div className={styles.addRow}>
        <button type="button" className={styles.addButton} onClick={() => onAddChild(false)}>
          + Normal sub-task
        </button>
        <button type="button" className={styles.addButton} onClick={() => onAddChild(true)}>
          + Counting sub-task
        </button>
        <span className={styles.subtaskNote}>
          A sub-task&apos;s type is fixed once added. Deleting a sub-task unlinks it — if it lives on another board it stays in your library.
        </span>
      </div>
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
        <MiniTypeBadge type={child.isCounting ? 'counting' : 'normal'} size="sub" />
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
