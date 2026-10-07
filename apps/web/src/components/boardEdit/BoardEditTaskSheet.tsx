import { useEffect, useState } from 'react';
import {
  TaskType,
  countKindNeedsUnit,
  formatCountForInput,
  generateCounterTaskTitle,
  kindPickerLock,
  resolveCountKind,
  type CompoundChild,
  type CountKind,
  type Task,
} from '@oybc/shared';
import {
  compoundLinkProblemForPatch,
  fetchCompoundChildren,
  fetchTasksByIds,
} from '../../db/operations';
import type { TaskEditPatch } from '../../db/taskEditPatch';
import { useModalA11y } from '../../hooks/useModalA11y';
import { loadLibraryInputs } from '../../pages/tasks/loadLibraryInputs';
import { TypeBadge } from '../TypeBadge';
import { GoalEntry } from '../counters/GoalEntry';
import { KindPicker } from '../counters/KindPicker';
import { KindTag } from '../counters/KindTag';
import { useKindSwitchRequest } from '../counters/useKindSwitchRequest';
import { planKindSwitchPreview } from '../../db/operations/countKindSwitch';
import { RisoSegmented } from '../riso';
import { CompoundFields, type LibraryInputsState } from '../wizard/CompoundFields';
import {
  buildSheetOverride,
  parseGoal,
  seedCompoundDraft,
  seedSheetTitle,
  sheetValidationProblem,
  showsCompoundEditor,
  typeControlMode,
  type BoardEditTaskOverride,
} from './boardEditTaskSheetModel';
import styles from './BoardEditTaskSheet.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface BoardEditTaskSheetProps {
  /**
   * The global Task to edit. May be the live task plus any already-staged
   * overrides merged by the caller — so re-opening the sheet shows the user's
   * previously staged values, not the DB state.
   */
  task: Task;
  /**
   * The task BEFORE any staged override (stored or pending). Drives the type
   * control and lets the user switch back to the original type before Save.
   * Defaults to `task` (nothing staged).
   */
  original?: Task;
  /** The task's already-staged override, if any (carries a staged `compound`). */
  staged?: BoardEditTaskOverride;
  /**
   * Called when the user taps "Done". Receives the staged override (task
   * fields, plus `compound` for a compound). NO DB write happens here — the
   * caller stages it and commits on Save.
   *
   * @param taskId - The task being edited (same as `task.id`)
   * @param patch - Validated staged changes for this task
   */
  onDone: (taskId: string, patch: BoardEditTaskOverride) => void;
  /** Dismiss without staging any changes. */
  onCancel: () => void;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/** Type labels shared with iOS. */
const TYPE_OPTIONS = [
  { value: TaskType.NORMAL, label: 'Simple' },
  { value: TaskType.COUNTING, label: 'Counting' },
  { value: TaskType.COMPOUND, label: 'Compound' },
];

/** Human-readable type label for the fixed type indicator. */
function typeLabel(type: TaskType | string): string {
  switch (type) {
    case TaskType.NORMAL:      return 'Simple';
    case TaskType.COUNTING:    return 'Counting';
    case TaskType.COMPOUND:    return 'Compound';
    case TaskType.ACHIEVEMENT: return 'Achievement';
    default:                   return String(type);
  }
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * BoardEditTaskSheet — bottom-sheet for staged edits to a global Task in
 * Board Edit mode. Distinct from the Tasks-tab `TaskEditSheet`:
 *
 *   1. It does NOT write to the database on Done — it calls `onDone` with a
 *      validated override that the caller stages in memory.
 *   2. A Simple / Counting task gets a Simple / Counting / Compound type
 *      control (an in-place type switch applied at Save); a Compound shows its
 *      type fixed with the rule + sub-task editor always open; Achievement is
 *      title only.
 *   3. A Counting task picks its kind (Discrete / Continuous / Duration); the
 *      switch is STAGED with the override and applied inside the Save
 *      transaction. A linked counter shows its kind as a tag.
 *
 * @param task - The task (with any caller-applied overrides pre-merged)
 * @param original - The task before any staged override
 * @param staged - Its staged override, if any
 * @param onDone - Receives the staged override; caller increments squareEditCount
 * @param onCancel - Dismiss without staging
 */
export function BoardEditTaskSheet({
  task,
  original: originalProp,
  staged,
  onDone,
  onCancel,
}: BoardEditTaskSheetProps): React.ReactElement {
  // aria-modal, Escape → cancel, initial focus, Tab trap, focus restore.
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel,
  });

  // ── Seed from task (which has overrides pre-merged by caller) ────────────

  const original = originalProp ?? task;
  const [selected, setSelected] = useState<TaskType>(task.type);
  // Blank for an auto-titled Counting task so the title re-derives (see model).
  const [title, setTitle] = useState(seedSheetTitle(task));

  // Counting fields
  const [action, setAction] = useState(task.action ?? '');
  // `task` carries any staged kind; the picker's locks follow it.
  const storedKind = resolveCountKind(task);
  const [countKind, setCountKind] = useState<CountKind>(storedKind);
  const [goalStr, setGoalStr] = useState(
    task.maxCount !== undefined ? formatCountForInput(task.maxCount, storedKind) : '',
  );
  const [unit, setUnit] = useState(task.unit ?? '');

  // The confirm previews the DRAFT (title / goal typed here, not yet staged).
  const draftGoal = parseGoal(goalStr, countKind) ?? task.maxCount;
  const draftSubject = {
    ...task,
    title: title.trim() || generateCounterTaskTitle(action.trim(), draftGoal, unit.trim(), undefined, countKind),
    action,
    unit,
    countKind,
    maxCount: draftGoal,
  };
  const { requestKind, dialog: kindDialog } = useKindSwitchRequest({
    subject: draftSubject,
    kind: countKind,
    goalText: goalStr,
    setKind: setCountKind,
    onSwitched: (k, g) => {
      // A typed custom title follows the switch only if it was the auto one;
      // a blank title keeps re-deriving at the new kind.
      if (title.trim()) {
        const after = planKindSwitchPreview(draftSubject, k, 0)?.titleAfter;
        if (after) setTitle(after);
      }
      setCountKind(k);
      setGoalStr(g);
    },
  });

  // Compound editor. A staged compound is the seed on re-open; otherwise an
  // existing compound loads its sub-tasks, and a non-compound starts empty.
  const [compoundDraft, setCompoundDraft] = useState<TaskEditPatch | null>(
    staged?.compound ?? (original.type === TaskType.COMPOUND ? null : seedCompoundDraft(original, [])),
  );
  // The STORED compound's seeded structure (null for a non-compound original
  // or a re-opened staged structure) — the unedited-compound gate's baseline.
  const [compoundBaseline, setCompoundBaseline] = useState<TaskEditPatch | null>(null);
  const [compoundLoadError, setCompoundLoadError] = useState<string | null>(null);
  const [libraryTasks, setLibraryTasks] = useState<Task[]>([]);
  const [allLinks, setAllLinks] = useState<CompoundChild[]>([]);
  const [libraryInputsState, setLibraryInputsState] = useState<LibraryInputsState>('loading');
  const [doneError, setDoneError] = useState<string | null>(null);
  const [checking, setChecking] = useState(false);

  const editorOpen = showsCompoundEditor(selected);

  // Load the sub-tasks (existing compound without a staged structure) and the
  // quick-add library inputs once the compound editor first opens.
  useEffect(() => {
    if (!editorOpen) return;
    let cancelled = false;
    if (original.type === TaskType.COMPOUND && !staged?.compound) {
      void (async () => {
        try {
          const links = (await fetchCompoundChildren(task.id))
            .filter((l) => !l.isDeleted)
            .sort((a, b) => a.childIndex - b.childIndex);
          const kids = await fetchTasksByIds(links.map((l) => l.childTaskId));
          const byId = new Map(kids.map((t) => [t.id, t]));
          const ordered = links.map((l) => byId.get(l.childTaskId)).filter((t): t is Task => !!t);
          if (!cancelled) {
            const seeded = seedCompoundDraft(original, ordered);
            setCompoundBaseline(seeded);
            setCompoundDraft(seeded);
          }
        } catch (e) {
          if (!cancelled) setCompoundLoadError(`Couldn't load sub-tasks: ${(e as Error).message}`);
        }
      })();
    }
    void (async () => {
      try {
        const library = await loadLibraryInputs(task.userId);
        if (!cancelled) {
          setLibraryTasks(library.libraryTasks);
          setAllLinks(library.allLinks);
          setLibraryInputsState('loaded');
        }
      } catch (e) {
        console.error('[BoardEditTaskSheet] loading sub-task library inputs failed', e);
        if (!cancelled) setLibraryInputsState('failed');
      }
    })();
    return () => {
      cancelled = true;
    };
    // Load once per sheet (first time the editor is shown) — later task
    // refreshes must not clobber the draft.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editorOpen]);

  // ── Validation ───────────────────────────────────────────────────────────

  const input = { original, selected, title, action, goalStr, unit, countKind, compoundDraft, compoundBaseline };
  const problem = sheetValidationProblem(input);
  const canSave = problem === null && !checking;
  const goalNum = parseGoal(goalStr, countKind);
  const needsUnit = countKindNeedsUnit(countKind);

  // ── "Reads as" preview (Counting only) ──────────────────────────────────

  const readsAs: string | null =
    selected === TaskType.COUNTING && goalNum !== null && (!needsUnit || unit.trim())
      ? generateCounterTaskTitle(action.trim(), goalNum, needsUnit ? unit.trim() : '', title.trim() || undefined, countKind)
      : null;

  // ── Submit ───────────────────────────────────────────────────────────────

  const handleDone = async () => {
    if (!canSave) return;
    setDoneError(null);
    const patch = buildSheetOverride(input);
    if (patch.compound) {
      // Link eligibility (loop / achievement / goal-less counter): needs the
      // DB, so it runs here; Save re-checks inside its transaction.
      setChecking(true);
      try {
        const linkProblem = await compoundLinkProblemForPatch(task.id, patch.compound);
        if (linkProblem !== null) {
          setDoneError(linkProblem);
          return;
        }
      } finally {
        setChecking(false);
      }
    }
    onDone(task.id, patch);
  };

  const mode = typeControlMode(original.type, task.sharedCounterId != null);

  // ── Render ───────────────────────────────────────────────────────────────

  return (
    <div className={styles.backdrop} onClick={onCancel} role="presentation">
      <div
        ref={modalRef}
        className={styles.sheet}
        role="dialog"
        aria-label="Edit task"
        {...modalProps}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className={styles.sheetHeader}>
          <h2 className={styles.sheetTitle}>Edit task</h2>
        </div>

        {/* Type: a switch for Simple/Counting, fixed for Compound/Achievement */}
        <div className={styles.typeRow}>
          <span className={styles.typeLabel}>Type</span>
          {mode === 'switch' ? (
            <div className={styles.typeSwitch}>
              <RisoSegmented
                aria-label="Task type"
                size="compact"
                fullWidth
                options={TYPE_OPTIONS}
                value={selected}
                onChange={(next) => {
                  // Switching back to an originally-Counting task after a staged
                  // switch away: the merged task has no counting fields, so reseed.
                  if (next === TaskType.COUNTING && original.type === TaskType.COUNTING && !action && !goalStr && !unit) {
                    const originalKind = resolveCountKind(original);
                    setAction(original.action ?? '');
                    setCountKind(originalKind);
                    setGoalStr(original.maxCount !== undefined ? formatCountForInput(original.maxCount, originalKind) : '');
                    setUnit(original.unit ?? '');
                  }
                  setSelected(next);
                  setDoneError(null);
                }}
              />
            </div>
          ) : (
            <div className={styles.typeBadgeWrap}>
              <TypeBadge type={task.type} size="small" />
              <span className={styles.typeReadOnly}>{typeLabel(task.type)}</span>
            </div>
          )}
        </div>

        {/* Task name */}
        <label className={styles.field}>
          <span className={styles.fieldLabel}>
            Task name
            {selected === TaskType.COUNTING && (
              <span className={styles.optional}> (optional)</span>
            )}
          </span>
          <input
            type="text"
            className={styles.fieldInput}
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            autoFocus
            placeholder={
              selected === TaskType.COUNTING
                ? 'Auto-generated from goal if blank…'
                : 'Task name…'
            }
          />
        </label>

        {/* Counting-specific fields */}
        {selected === TaskType.COUNTING && (
          <>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Action</span>
              <input
                type="text"
                className={styles.fieldInput}
                value={action}
                onChange={(e) => setAction(e.target.value)}
                placeholder="e.g. Run, Read, Drink…"
              />
            </label>

            <div className={styles.field}>
              <span className={styles.fieldLabel}>Kind</span>
              {task.sharedCounterId != null ? (
                <KindTag kind={storedKind} />
              ) : (
                <KindPicker
                  value={countKind}
                  lock={kindPickerLock(original.type === TaskType.COUNTING ? 'edit' : 'create', storedKind)}
                  onChange={requestKind}
                />
              )}
            </div>

            <div className={styles.countRow}>
              <label className={`${styles.field} ${needsUnit ? styles.goalField : styles.goalFieldFull}`}>
                <span className={styles.fieldLabel}>Goal</span>
                <GoalEntry kind={countKind} value={goalStr} onChange={setGoalStr} aria-label="Goal" placeholder="e.g. 10" dense />
              </label>
              {needsUnit && (
                <label className={`${styles.field} ${styles.unitField}`}>
                  <span className={styles.fieldLabel}>Unit</span>
                  <input
                    type="text"
                    className={styles.fieldInput}
                    value={unit}
                    onChange={(e) => setUnit(e.target.value)}
                    placeholder="km, cups, pages…"
                  />
                </label>
              )}
            </div>

            {/* Live "Reads as…" preview */}
            {readsAs && (
              <p className={styles.preview} aria-live="polite">
                Reads as <strong>{readsAs}</strong>
              </p>
            )}
            {kindDialog}
          </>
        )}

        {/* Compound: rule + sub-task editor */}
        {editorOpen && (
          <div className={styles.compoundEditor}>
            {compoundDraft !== null ? (
              <CompoundFields
                draft={{ ...compoundDraft, title }}
                onDraftChange={(next) => {
                  setCompoundDraft(next);
                  setDoneError(null);
                }}
                parentId={task.id}
                libraryTasks={libraryTasks}
                allLinks={allLinks}
                libraryInputsState={libraryInputsState}
              />
            ) : compoundLoadError !== null ? (
              <p className={styles.problem} role="alert">{compoundLoadError}</p>
            ) : (
              <p className={styles.problem}>Loading sub-tasks…</p>
            )}
            {compoundDraft !== null && problem !== null && (
              <p className={styles.problem}>{problem}</p>
            )}
          </div>
        )}

        {doneError !== null && (
          <p className={styles.problem} role="alert">{doneError}</p>
        )}

        {/* Footer */}
        <div className={styles.footer}>
          <button
            type="button"
            className={styles.cancelBtn}
            onClick={onCancel}
          >
            Cancel
          </button>
          <button
            type="button"
            className={styles.doneBtn}
            disabled={!canSave}
            onClick={() => void handleDone()}
          >
            Done
          </button>
        </div>
      </div>
    </div>
  );
}
