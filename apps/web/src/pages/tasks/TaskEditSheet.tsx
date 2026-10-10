import { useEffect, useState } from 'react';
import { CountsTowardField } from '../../components/counters/CountsTowardField';
import { countsTowardProblemLabel } from '../../components/counters/countsTowardLabels';
import { countsTowardSubmitFor, showsCountsTowardRow, storedCountsToward, type CountsTowardSelection } from '../../components/counters/countsTowardFieldModel';
import { CountsTowardError } from '../../db/operations/countsToward';
import { useTasks } from '../../hooks/useTasks';
import {
  AchievementTrigger,
  TaskType,
  countKindNeedsUnit,
  formatCountForInput,
  kindPickerLock,
  parseCountInput,
  resolveCountKind,
  type CompoundChild,
  type CountKind,
  type Task,
} from '@oybc/shared';
import type { Board, RecurringBoardTemplate } from '@oybc/shared';
import {
  CompoundEditValidationError,
  fetchAllBoardsSortedByName,
  fetchCompoundChildren,
  fetchTasksByIds,
  type TaskEditSubmit,
} from '../../db/operations';
import { fetchAllTemplatesSortedByName } from '../../db/operations/recurringBoardTemplates';
import { checkAchievementRetargetCycle } from '../../db/operations/tasks';
import {
  childPatchFromTask,
  seedPatchForEditor,
  validatePatch,
  type TaskEditPatch,
} from '../../db/taskEditPatch';
import { GoalEntry } from '../../components/counters/GoalEntry';
import { KindPicker } from '../../components/counters/KindPicker';
import { LinkedKindTag } from '../../components/counters/LinkedKindTag';
import { useKindSwitchRequest } from '../../components/counters/useKindSwitchRequest';
import { planKindSwitchPreview } from '../../db/operations/countKindSwitch';
import { countingGoalError } from '../createPage/createFormCounting';
import { CompoundFields, type LibraryInputsState } from '../../components/wizard/CompoundFields';
import { loadLibraryInputs } from './loadLibraryInputs';
import { compoundStructureChanged, compoundSubmitFor } from './compoundEditGate';
import { TaskTypeControl } from '../../components/taskEdit/TaskTypeControl';
import { typeControlMode, typeLockedForEdit } from '../../components/taskEdit/taskTypeRules';
import { useHasLiveLinkedCopies } from '../../hooks/useHasLiveLinkedCopies';
import { seedCompoundDraft } from '../../components/boardEdit/boardEditTaskSheetModel';
import { useModalA11y } from '../../hooks/useModalA11y';
import styles from './TaskDetailContent.module.css';

export interface TaskEditSheetProps {
  task: Task;
  /**
   * Persists the edit (callers route it through `saveTaskEdit`). For a
   * compound the submit carries `compound` — the edited rule + sub-tasks,
   * whose `title` is the sheet's Title field. A rejection with
   * `CompoundEditValidationError` is shown inline in the sheet.
   */
  onSubmit: (submit: TaskEditSubmit) => Promise<void>;
  onCancel: () => void;
}

/**
 * TaskEditSheet — modal sheet for editing a task's editable fields.
 *
 * A task's own window (`timeframe` / `startDate` / `endDate`) is NOT
 * editable here: it is set only at creation and by member-rules stamping
 * (where it is a window-stamped derived row's completion window).
 *
 * M1 additions:
 *   - Achievement re-target: mode toggle (specific board vs recurring template)
 *     + picker. Cycle detection runs before submit.
 *
 * Type: a Simple / Counting task gets the shared Simple / Counting /
 * Compound switch (`TaskTypeControl`); the save is GLOBAL and retroactive on
 * every board placing the task (`saveTaskEdit` →
 * `applyTaskTypeSwitchInTransaction`). A compound, a linked counter and an
 * achievement keep their type.
 *
 * Compound tasks: the rule (All of / Any of / At least N) and sub-tasks are
 * edited in place via the shared `CompoundFields` editor. The current
 * sub-tasks load once on open (an effect, so a static render never touches
 * Dexie); Save stays disabled until they have loaded. The structure is
 * submitted (and must validate) only when it was edited — an unedited
 * compound saves through the basic route, so one whose stored structure is
 * already invalid can still be renamed.
 *
 * Shares CSS module with `TaskDetailContent` to avoid styling drift.
 */
export function TaskEditSheet({
  task,
  onSubmit,
  onCancel,
}: TaskEditSheetProps): React.ReactElement {
  // aria-modal, Escape → cancel, initial focus, Tab trap, focus restore.
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel,
  });
  const [title, setTitle] = useState(task.title);
  const [selected, setSelected] = useState<TaskType>(task.type);
  // Any shared counter (linked copy, hub counter, root other rows link to) keeps its type.
  const typeMode = typeControlMode(task.type, typeLockedForEdit(task, useHasLiveLinkedCopies(task.id)));
  const [description, setDescription] = useState(task.description ?? '');

  // Counting fields
  const [action, setAction] = useState(task.action ?? '');
  const [unit, setUnit] = useState(task.unit ?? '');
  const storedKind = resolveCountKind(task);
  const [countKind, setCountKind] = useState<CountKind>(storedKind);
  const [maxCountStr, setMaxCountStr] = useState(
    task.maxCount !== undefined ? formatCountForInput(task.maxCount, storedKind) : '',
  );
  // The confirm previews the DRAFT (title / goal typed here), not the stored row.
  const { requestKind, dialog: kindDialog } = useKindSwitchRequest({
    subject: {
      ...task,
      title,
      action,
      unit,
      maxCount: parseCountInput(maxCountStr, countKind) ?? task.maxCount,
    },
    kind: countKind,
    goalText: maxCountStr,
    setKind: setCountKind,
    onSwitched: (k, g) => {
      // An auto-generated title follows the rounding (the dialog's second row).
      const draft = { ...task, title, action, unit, countKind, maxCount: parseCountInput(maxCountStr, countKind) ?? task.maxCount };
      const after = planKindSwitchPreview(draft, k, 0)?.titleAfter;
      if (after) setTitle(after);
      setCountKind(k);
      setMaxCountStr(g);
    },
  });

  // Achievement fields
  const [trigger, setTrigger] = useState<AchievementTrigger>(
    task.achievementTrigger ?? AchievementTrigger.GREENLOG,
  );
  const [requiredCountStr, setRequiredCountStr] = useState(
    task.requiredCount !== undefined ? String(task.requiredCount) : '',
  );
  // Achievement reference mode: 'board' | 'template'
  const [refMode, setRefMode] = useState<'board' | 'template'>(
    task.referencedTemplateId ? 'template' : 'board',
  );
  const [selectedBoardId, setSelectedBoardId] = useState<string>(
    task.referencedBoardId ?? '',
  );
  const [selectedTemplateId, setSelectedTemplateId] = useState<string>(
    task.referencedTemplateId ?? '',
  );

  // Available boards and templates for the Achievement picker
  const [availableBoards, setAvailableBoards] = useState<Board[]>([]);
  const [availableTemplates, setAvailableTemplates] = useState<RecurringBoardTemplate[]>([]);

  useEffect(() => {
    if (task.type !== TaskType.ACHIEVEMENT) return;
    // Load boards and templates for the picker.
    const load = async () => {
      const boards = await fetchAllBoardsSortedByName();
      const templates = await fetchAllTemplatesSortedByName();
      setAvailableBoards(boards);
      setAvailableTemplates(templates);
    };
    void load();
  }, [task.type]);

  // Compound structure (rule + sub-tasks). `null` until the current
  // sub-tasks have loaded; the draft's own `title` is ignored — the sheet's
  // Title field is the single source (merged in at render + submit).
  const isCompound = selected === TaskType.COMPOUND;
  // Picked Compound on a Simple / Counting task: the structure always submits.
  const isConverting = isCompound && task.type !== TaskType.COMPOUND;
  const [compoundDraft, setCompoundDraft] = useState<TaskEditPatch | null>(null);
  // What the editor opened with — only an edited structure is submitted.
  const [compoundBaseline, setCompoundBaseline] = useState<TaskEditPatch | null>(null);
  const [compoundLoadError, setCompoundLoadError] = useState<string | null>(null);
  // Sub-task quick-add inputs: the browsable library (its matches) and every
  // live link (the loop check), loaded once with the sub-tasks.
  const [libraryTasks, setLibraryTasks] = useState<Task[]>([]);
  const [allLinks, setAllLinks] = useState<CompoundChild[]>([]);
  const [libraryInputsState, setLibraryInputsState] = useState<LibraryInputsState>('loading');

  useEffect(() => {
    if (!isCompound) return;
    let cancelled = false;
    const load = async () => {
      if (task.type !== TaskType.COMPOUND) {
        // A conversion starts from the default empty "all" rule.
        setCompoundDraft((d) => d ?? seedCompoundDraft(task, []));
        return;
      }
      try {
        const links = (await fetchCompoundChildren(task.id))
          .filter((l) => !l.isDeleted)
          .sort((a, b) => a.childIndex - b.childIndex);
        const kids = await fetchTasksByIds(links.map((l) => l.childTaskId));
        const byId = new Map(kids.map((t) => [t.id, t]));
        const seeded: TaskEditPatch = {
          ...seedPatchForEditor(task),
          children: links
            .map((l) => byId.get(l.childTaskId))
            .filter((t): t is Task => !!t && !t.isDeleted)
            .map(childPatchFromTask),
        };
        if (!cancelled) {
          setCompoundBaseline(seeded);
          setCompoundDraft(seeded);
        }
      } catch (e) {
        if (!cancelled) setCompoundLoadError(`Couldn't load sub-tasks: ${(e as Error).message}`);
      }
    };
    // The library inputs load on their own: a failure there leaves the
    // sub-task editor usable (only linking an existing task is affected).
    const loadLibrary = async () => {
      try {
        const library = await loadLibraryInputs(task.userId);
        if (!cancelled) {
          setLibraryTasks(library.libraryTasks);
          setAllLinks(library.allLinks);
          setLibraryInputsState('loaded');
        }
      } catch (e) {
        console.error('[TaskEditSheet] loading sub-task library inputs failed', e);
        if (!cancelled) setLibraryInputsState('failed');
      }
    };
    void load();
    void loadLibrary();
    return () => {
      cancelled = true;
    };
    // Seed once per task identity (and when the editor first opens) — later
    // edits to `task` (e.g. a live query refresh while the sheet is open)
    // must not clobber the draft.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [task.id, task.type, isCompound]);

  const compoundValidation =
    compoundDraft !== null ? validatePatch({ ...compoundDraft, title }, TaskType.COMPOUND) : null;
  // Save is gated on the structure only when it was edited: a compound whose
  // STORED structure is already invalid can still take a rename /
  // description edit through the basic route.
  const structureChanged = compoundStructureChanged(compoundBaseline, compoundDraft);
  const compoundBlocked =
    isCompound && (compoundDraft === null || ((structureChanged || isConverting) && compoundValidation !== null));

  const [submitting, setSubmitting] = useState(false);
  const [validationError, setValidationError] = useState<string | null>(null);

  // "Counts toward" (docs/SHARED_COUNTER_SETTINGS.md §3d) — hidden for rows that can never contribute.
  const allTasks = useTasks(task.userId) ?? [];
  const storedCounts = storedCountsToward(task);
  const [countsToward, setCountsToward] = useState<CountsTowardSelection>(storedCounts);
  const showsCountsToward = showsCountsTowardRow(task, allTasks, selected);

  const parsePositiveInt = (raw: string): number | null | 'empty' => {
    const trimmed = raw.trim();
    if (trimmed === '') return 'empty';
    const parsed = parseInt(trimmed, 10);
    if (!Number.isInteger(parsed) || parsed <= 0) return null;
    return parsed;
  };

  const handleSubmit = async () => {
    setValidationError(null);
    const patch: TaskEditSubmit = {
      title: title.trim(),
      description: description.trim() || undefined,
    };
    if (showsCountsToward) {
      const countsTowardSubmit = countsTowardSubmitFor(storedCounts, countsToward);
      if (countsTowardSubmit) patch.countsToward = countsTowardSubmit;
    }

    if (selected !== task.type) patch.type = selected;

    if (selected === TaskType.COUNTING) {
      patch.action = action.trim();
      // Duration hides Unit but keeps the row's own (a hub counter's noun names it).
      patch.unit = unit.trim();
      if (task.type !== TaskType.COUNTING && countKindNeedsUnit(countKind) && !patch.unit) {
        setValidationError('Add a unit, like km or pages.');
        return;
      }
      // A conversion into Counting needs a goal; an existing counter may stay goal-less.
      if (maxCountStr.trim() !== '' || task.type !== TaskType.COUNTING) {
        const error = countingGoalError(maxCountStr, countKind);
        if (error) {
          setValidationError(error);
          return;
        }
        patch.maxCount = parseCountInput(maxCountStr, countKind) as number;
      }
      if (!task.sharedCounterId) patch.countKind = countKind;
    }

    if (task.type === TaskType.ACHIEVEMENT) {
      patch.achievementTrigger = trigger;

      // Reference re-target
      if (refMode === 'board') {
        if (!selectedBoardId) {
          setValidationError('Please select a specific board to watch.');
          return;
        }
        // Cycle check before committing the write
        const cycleError = await checkAchievementRetargetCycle(task.id, {
          referencedBoardId: selectedBoardId,
          referencedTemplateId: undefined,
        });
        if (cycleError) {
          setValidationError(cycleError);
          return;
        }
        patch.referencedBoardId = selectedBoardId;
        patch.referencedTemplateId = null;
      } else {
        if (!selectedTemplateId) {
          setValidationError('Please select a repeating board to watch.');
          return;
        }
        const result = parsePositiveInt(requiredCountStr);
        if (result === null) {
          setValidationError('Required count must be a whole number greater than 0.');
          return;
        }
        // Cycle check before committing the write
        const cycleError = await checkAchievementRetargetCycle(task.id, {
          referencedBoardId: undefined,
          referencedTemplateId: selectedTemplateId,
        });
        if (cycleError) {
          setValidationError(cycleError);
          return;
        }
        patch.referencedTemplateId = selectedTemplateId;
        patch.referencedBoardId = null;
        if (result !== 'empty') {
          patch.requiredCount = result;
        }
      }
    }

    if (isCompound) {
      if (compoundDraft === null) return;
      const compound = isConverting
        ? { ...compoundDraft, title: title.trim() }
        : compoundSubmitFor(compoundBaseline, compoundDraft, title);
      if (compound) patch.compound = compound;
    }

    setSubmitting(true);
    try {
      await onSubmit(patch);
    } catch (e) {
      // Call sites surface other failures themselves; a structure
      // validation failure belongs next to the editor.
      if (e instanceof CompoundEditValidationError) {
        setValidationError(e.message);
      } else if (e instanceof CountsTowardError && e.code !== 'task-missing') {
        setValidationError(countsTowardProblemLabel(e.code));
      } else {
        throw e;
      }
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className={styles.sheetBackdrop} onClick={onCancel}>
      <div
        ref={modalRef}
        className={styles.sheet}
        role="dialog"
        aria-label="Edit task"
        {...modalProps}
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className={styles.sheetHeading}>Edit task</h2>

        <label className={styles.field}>
          <span className={styles.fieldLabel}>Title</span>
          <input
            type="text"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            className={styles.fieldInput}
          />
        </label>

        <label className={styles.field}>
          <span className={styles.fieldLabel}>Description</span>
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className={styles.fieldTextarea}
            rows={3}
          />
        </label>

        <TaskTypeControl
          mode={typeMode}
          selected={selected}
          storedType={task.type}
          onChange={(next) => {
            setSelected(next);
            setValidationError(null);
          }}
        />

        {selected === TaskType.COUNTING && (
          <>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Action</span>
              <input
                type="text"
                value={action}
                onChange={(e) => setAction(e.target.value)}
                className={styles.fieldInput}
              />
            </label>
            <div className={styles.field}>
              <span className={styles.fieldLabel}>Kind</span>
              {task.sharedCounterId ? (
                <LinkedKindTag task={task} />
              ) : (
                <KindPicker
                  value={countKind}
                  lock={kindPickerLock(task.type === TaskType.COUNTING ? 'edit' : 'create', storedKind)}
                  onChange={requestKind}
                />
              )}
            </div>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Goal</span>
              <GoalEntry kind={countKind} value={maxCountStr} onChange={setMaxCountStr} aria-label="Goal" dense />
            </label>
            {countKindNeedsUnit(countKind) && (
              <label className={styles.field}>
                <span className={styles.fieldLabel}>Unit</span>
                <input
                  type="text"
                  value={unit}
                  onChange={(e) => setUnit(e.target.value)}
                  className={styles.fieldInput}
                />
              </label>
            )}
            {kindDialog}
          </>
        )}

        {task.type === TaskType.ACHIEVEMENT && (
          <>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Trigger</span>
              <select
                value={trigger}
                onChange={(e) => setTrigger(e.target.value as AchievementTrigger)}
                className={styles.fieldInput}
              >
                <option value={AchievementTrigger.GREENLOG}>Greenlog</option>
                <option value={AchievementTrigger.BINGO}>Bingo</option>
              </select>
            </label>

            {/* Achievement reference re-target */}
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Watches</span>
              <select
                value={refMode}
                onChange={(e) => setRefMode(e.target.value as 'board' | 'template')}
                className={styles.fieldInput}
              >
                <option value="board">Specific board</option>
                <option value="template">Repeating board</option>
              </select>
            </label>

            {refMode === 'board' && (
              <label className={styles.field}>
                <span className={styles.fieldLabel}>Board</span>
                <select
                  value={selectedBoardId}
                  onChange={(e) => setSelectedBoardId(e.target.value)}
                  className={styles.fieldInput}
                >
                  <option value="">— select a board —</option>
                  {availableBoards.map((b) => (
                    <option key={b.id} value={b.id}>
                      {b.name}
                    </option>
                  ))}
                </select>
              </label>
            )}

            {refMode === 'template' && (
              <>
                <label className={styles.field}>
                  <span className={styles.fieldLabel}>Repeating board</span>
                  <select
                    value={selectedTemplateId}
                    onChange={(e) => setSelectedTemplateId(e.target.value)}
                    className={styles.fieldInput}
                  >
                    <option value="">— select a repeating board —</option>
                    {availableTemplates.map((t) => (
                      <option key={t.id} value={t.id}>
                        {t.name}
                      </option>
                    ))}
                  </select>
                </label>
                <label className={styles.field}>
                  <span className={styles.fieldLabel}>Required count</span>
                  <input
                    type="number"
                    min={1}
                    step={1}
                    value={requiredCountStr}
                    onChange={(e) => setRequiredCountStr(e.target.value)}
                    className={styles.fieldInput}
                  />
                </label>
              </>
            )}
          </>
        )}

        {isCompound && (
          <fieldset className={styles.fieldset}>
            <legend className={styles.fieldsetLegend}>Sub-tasks &amp; rule</legend>
            {compoundDraft !== null ? (
              <CompoundFields
                draft={{ ...compoundDraft, title }}
                onDraftChange={(next) => setCompoundDraft(next)}
                parentId={task.id}
                libraryTasks={libraryTasks}
                allLinks={allLinks}
                libraryInputsState={libraryInputsState}
              />
            ) : compoundLoadError !== null ? (
              <p className={styles.compoundStatus} role="alert">
                {compoundLoadError}
              </p>
            ) : (
              <p className={styles.compoundStatus}>Loading sub-tasks…</p>
            )}
            {compoundValidation !== null && (
              <p className={styles.compoundValidation}>{compoundValidation}</p>
            )}
          </fieldset>
        )}

        {showsCountsToward && (
          <CountsTowardField
            userId={task.userId}
            taskId={task.id}
            stored={storedCounts}
            value={countsToward}
            onChange={setCountsToward}
            labelClassName={styles.fieldLabel}
          />
        )}

        {validationError !== null && (
          <p className={styles.error} role="alert">
            {validationError}
          </p>
        )}

        <div className={styles.sheetActions}>
          <button
            type="button"
            className={styles.cancelButton}
            onClick={onCancel}
            disabled={submitting}
          >
            Cancel
          </button>
          <button
            type="button"
            className={styles.saveButton}
            onClick={handleSubmit}
            disabled={submitting || !title.trim() || compoundBlocked}
          >
            {submitting ? 'Saving…' : 'Save changes'}
          </button>
        </div>
      </div>
    </div>
  );
}
