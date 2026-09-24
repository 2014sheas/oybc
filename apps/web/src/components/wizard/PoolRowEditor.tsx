import { TaskType } from '@oybc/shared';
import { RisoButton, RisoIcon, RisoSectionLabel } from '../riso';
import { countingPreview, validatePatch, type TaskEditPatch } from '../../db/taskEditPatch';
import { CompoundFields } from './CompoundFields';
import { MiniTypeBadge, type MiniBadgeType } from './MiniTypeBadge';
import styles from './PoolRowEditor.module.css';

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
          <CompoundFields draft={draft} onDraftChange={onDraftChange} />
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

function badgeTypeFor(type: TaskType): MiniBadgeType {
  return type === TaskType.COUNTING ? 'counting' : type === TaskType.COMPOUND ? 'compound' : 'normal';
}
