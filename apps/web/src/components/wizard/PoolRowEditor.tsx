import {
  TaskType,
  countKindNeedsUnit,
  kindPickerLock,
  parseCountInput,
  resolveCountKind,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { RisoButton, RisoSectionLabel } from '../riso';
import { GoalEntry } from '../counters/GoalEntry';
import { KindPicker } from '../counters/KindPicker';
import { LinkedKindTag } from '../counters/LinkedKindTag';
import { useKindSwitchRequest } from '../counters/useKindSwitchRequest';
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
  /** The row's stored task (its id guards compound links; its kind / link drive the Kind row). */
  task: Task;
  draft: TaskEditPatch;
  onDraftChange: (next: TaskEditPatch) => void;
  onSave: () => void;
  onDiscard: () => void;
  /** Compound only — browsable library tasks the sub-task quick-add row matches against. */
  libraryTasks: Task[];
  /** Compound only — live links across all compounds (loop check). */
  allLinks: CompoundChild[];
}

/**
 * PoolRowEditor — the inline pool-row editor (Inline Task Editing, web
 * PR-2). Replaces a resting `PoolList` row in place: paper-2 fill with a
 * 4px blue left rail, a hairline header strip ("EDITING · <TYPE>" + the
 * Esc/⌘↵ hint), Title (+ Action/Goal/Unit on one line for Counting, +
 * live "Reads as" preview), the Compound sub-task editor (operator picker
 * + sub-task cards + the quick-add row), a footer staging line + validation
 * message, and Discard / Save actions.
 *
 * Edits are staged only — `onSave` hands the current `draft` up to the
 * wizard's `stagedEdits` map; nothing touches the DB until the board is
 * created (`persistWizardBoardRows` / `persistWizardPendingTasksAndStagedEdits`
 * apply it atomically — see `db/operations/wizardBoard.ts`).
 *
 * Current-iOS vocabulary throughout (NOT the handoff's retired "steps" /
 * "In order" terms): **sub-tasks**, an operator picker (All of / Any of /
 * At least N — reusing the existing `OperatorSelector`), and the wizard's
 * own quick-add row to add a sub-task ("New sub: Normal / Counting").
 */
export function PoolRowEditor({
  task,
  draft,
  onDraftChange,
  onSave,
  onDiscard,
  libraryTasks,
  allLinks,
}: PoolRowEditorProps): React.ReactElement {
  const taskId = task.id;
  const taskType = task.type;
  const stored = resolveCountKind(task);
  const kind = draft.countKind ?? stored;
  // The confirm previews the DRAFT (title / goal typed here), not the stored row.
  const { requestKind, dialog } = useKindSwitchRequest({
    subject: {
      ...task,
      title: draft.title || task.title,
      action: draft.action,
      unit: draft.unit,
      maxCount: parseCountInput(draft.goal, kind) ?? task.maxCount,
    },
    kind,
    goalText: draft.goal,
    setKind: (k) => onDraftChange({ ...draft, countKind: k }),
    onSwitched: (k, g) => onDraftChange({ ...draft, countKind: k, goal: g }),
  });
  const validationMessage = validatePatch(draft, taskType, stored);
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

  return (
    <div className={styles.editor} onKeyDown={handleKeyDown}>
      <div className={styles.header}>
        <MiniTypeBadge type={badgeTypeFor(taskType)} size="header" />
        <span className={styles.headerLabel}>Editing · {HEADER_LABEL[taskType].toUpperCase()}</span>
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
        </div>

        {taskType === TaskType.COUNTING && (
          <>
            <div className={styles.kindRow}>
              <RisoSectionLabel variant="kicker">Kind</RisoSectionLabel>
              {task.sharedCounterId ? (
                <LinkedKindTag task={task} />
              ) : (
                <KindPicker value={kind} lock={kindPickerLock('edit', stored)} onChange={requestKind} size="compact" />
              )}
            </div>
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
                <GoalEntry
                  kind={kind}
                  value={draft.goal}
                  onChange={(g) => onDraftChange({ ...draft, goal: g })}
                  aria-label="Goal"
                  dense
                  placeholder="5"
                />
              </div>
              {countKindNeedsUnit(kind) && (
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
              )}
            </div>
          </>
        )}

        {taskType === TaskType.COUNTING && countingPreview(draft, kind) && (
          <div className={styles.readsAs}>{countingPreview(draft, kind)}</div>
        )}

        {taskType === TaskType.COMPOUND && (
          <CompoundFields
            draft={draft}
            onDraftChange={onDraftChange}
            parentId={taskId}
            libraryTasks={libraryTasks}
            allLinks={allLinks}
          />
        )}

        <div className={styles.footer}>
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
      {dialog}
    </div>
  );
}

function badgeTypeFor(type: TaskType): MiniBadgeType {
  return type === TaskType.COUNTING ? 'counting' : type === TaskType.COMPOUND ? 'compound' : 'normal';
}
