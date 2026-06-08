import { useEffect, useState } from 'react';
import { AchievementTrigger, TaskType, Timeframe, toLocalISO, type Task } from '@oybc/shared';
import type { Board, RecurringBoardTemplate } from '@oybc/shared';
import { db } from '../../db/database';
import {
  checkAchievementRetargetCycle,
  type UpdateTaskPatch,
} from '../../db/operations/tasks';
import styles from './TaskDetailContent.module.css';

export interface TaskEditSheetProps {
  task: Task;
  onSubmit: (patch: UpdateTaskPatch) => Promise<void>;
  onCancel: () => void;
}

/**
 * TaskEditSheet — modal sheet for editing a task's editable fields.
 *
 * M1 additions:
 *   - Timeboxed fields: timeframe / startDate / endDate (all task types).
 *   - Achievement re-target: mode toggle (specific board vs recurring template)
 *     + picker. Cycle detection runs before submit.
 *
 * Shares CSS module with `TaskDetailContent` to avoid styling drift.
 */
export function TaskEditSheet({
  task,
  onSubmit,
  onCancel,
}: TaskEditSheetProps): React.ReactElement {
  const [title, setTitle] = useState(task.title);
  const [description, setDescription] = useState(task.description ?? '');

  // Counting fields
  const [action, setAction] = useState(task.action ?? '');
  const [unit, setUnit] = useState(task.unit ?? '');
  const [maxCountStr, setMaxCountStr] = useState(
    task.maxCount !== undefined ? String(task.maxCount) : '',
  );

  // Timeboxed fields (all types)
  const [timeframe, setTimeframe] = useState<Timeframe | ''>(task.timeframe ?? '');
  const [startDate, setStartDate] = useState(
    task.startDate ? task.startDate.slice(0, 10) : '',
  );
  const [endDate, setEndDate] = useState(
    task.endDate ? task.endDate.slice(0, 10) : '',
  );

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
      const boards = await db.boards
        .filter((b) => !b.isDeleted)
        .sortBy('name');
      const templates = await db.recurringBoardTemplates
        .filter((t) => !t.isDeleted)
        .sortBy('name');
      setAvailableBoards(boards);
      setAvailableTemplates(templates);
    };
    void load();
  }, [task.type]);

  const [submitting, setSubmitting] = useState(false);
  const [validationError, setValidationError] = useState<string | null>(null);

  const parsePositiveInt = (raw: string): number | null | 'empty' => {
    const trimmed = raw.trim();
    if (trimmed === '') return 'empty';
    const parsed = parseInt(trimmed, 10);
    if (!Number.isInteger(parsed) || parsed <= 0) return null;
    return parsed;
  };

  const handleSubmit = async () => {
    setValidationError(null);
    const patch: UpdateTaskPatch = {
      title: title.trim(),
      description: description.trim() || undefined,
    };

    if (task.type === TaskType.COUNTING) {
      patch.action = action.trim();
      patch.unit = unit.trim();
      const result = parsePositiveInt(maxCountStr);
      if (result === null) {
        setValidationError('Goal must be a whole number greater than 0.');
        return;
      }
      if (result !== 'empty') {
        patch.maxCount = result;
      }
    }

    // Timeboxed fields — all task types.
    // Dates come from <input type="date"> as YYYY-MM-DD strings. Snap
    // start to local 00:00:00.000 and end to local 23:59:59.999 so the
    // calendar window covers the whole day, and serialize via
    // `toLocalISO` (no timezone suffix) to match the convention used by
    // the wizard and by `calendarBoundaries`. The earlier
    // `new Date(s + 'T12:00:00').toISOString()` path produced a UTC
    // mid-day string that could shift the date in non-UTC zones and
    // didn't sit at day boundaries.
    function snapStart(ymd: string): string {
      const [y, m, d] = ymd.split('-').map(Number);
      return toLocalISO(new Date(y, m - 1, d, 0, 0, 0, 0));
    }
    function snapEnd(ymd: string): string {
      const [y, m, d] = ymd.split('-').map(Number);
      return toLocalISO(new Date(y, m - 1, d, 23, 59, 59, 999));
    }
    if (timeframe) {
      patch.timeframe = timeframe as Timeframe;
      // Validate ordering — matches the wizard's "End date must be on or
      // after the start date" check so live edits can't produce inverted
      // windows.
      if (startDate && endDate && endDate < startDate) {
        setValidationError('End date must be on or after the start date.');
        return;
      }
      patch.startDate = startDate ? snapStart(startDate) : null;
      patch.endDate = endDate ? snapEnd(endDate) : null;
    } else if (task.timeframe !== undefined) {
      // Cleared by the user — send null sentinels to wipe the fields.
      patch.timeframe = null;
      patch.startDate = null;
      patch.endDate = null;
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
          setValidationError('Please select a recurring template to watch.');
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

    setSubmitting(true);
    await onSubmit(patch);
    setSubmitting(false);
  };

  return (
    <div className={styles.sheetBackdrop} onClick={onCancel}>
      <div
        className={styles.sheet}
        role="dialog"
        aria-label="Edit task"
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

        {task.type === TaskType.COUNTING && (
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
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Goal</span>
              <input
                type="number"
                min={1}
                step={1}
                value={maxCountStr}
                onChange={(e) => setMaxCountStr(e.target.value)}
                className={styles.fieldInput}
              />
            </label>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Unit</span>
              <input
                type="text"
                value={unit}
                onChange={(e) => setUnit(e.target.value)}
                className={styles.fieldInput}
              />
            </label>
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
                <option value="template">Recurring template</option>
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
                  <span className={styles.fieldLabel}>Template</span>
                  <select
                    value={selectedTemplateId}
                    onChange={(e) => setSelectedTemplateId(e.target.value)}
                    className={styles.fieldInput}
                  >
                    <option value="">— select a template —</option>
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

        {task.type === TaskType.COMPOUND && (
          <p className={styles.compoundHint}>
            Compound subtasks are edited from the board-creation wizard. The
            title and description can still be changed here.
          </p>
        )}

        {/* Timeboxed fields — shown for all task types */}
        <fieldset className={styles.fieldset}>
          <legend className={styles.fieldsetLegend}>Time window (optional)</legend>
          <label className={styles.field}>
            <span className={styles.fieldLabel}>Timeframe</span>
            <select
              value={timeframe}
              onChange={(e) => setTimeframe(e.target.value as Timeframe | '')}
              className={styles.fieldInput}
            >
              <option value="">— none —</option>
              <option value={Timeframe.DAILY}>Daily</option>
              <option value={Timeframe.WEEKLY}>Weekly</option>
              <option value={Timeframe.MONTHLY}>Monthly</option>
              <option value={Timeframe.YEARLY}>Yearly</option>
              <option value={Timeframe.CUSTOM}>Custom</option>
            </select>
          </label>
          {timeframe && (
            <>
              <label className={styles.field}>
                <span className={styles.fieldLabel}>Start date</span>
                <input
                  type="date"
                  value={startDate}
                  onChange={(e) => setStartDate(e.target.value)}
                  className={styles.fieldInput}
                />
              </label>
              <label className={styles.field}>
                <span className={styles.fieldLabel}>End date</span>
                <input
                  type="date"
                  value={endDate}
                  onChange={(e) => setEndDate(e.target.value)}
                  className={styles.fieldInput}
                />
              </label>
            </>
          )}
        </fieldset>

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
            disabled={submitting || !title.trim()}
          >
            {submitting ? 'Saving…' : 'Save changes'}
          </button>
        </div>
      </div>
    </div>
  );
}
