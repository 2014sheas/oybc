import { useState, useEffect } from 'react';
import {
  CenterSquareType,
  Timeframe,
  toLocalISO,
  getTimeframeBoundaries,
} from '@oybc/shared';
import type { Board } from '@oybc/shared';
import { BoardSetupForm } from './wizard/BoardSetupForm';
import { updateBoardAndCascade, type UpdateActiveBoardPatch } from '../db/operations/boards';
import { db } from '../db/database';
import styles from './TaskDetailSheet.module.css';
import editStyles from './EditBoardSheet.module.css';

// ─── Props ────────────────────────────────────────────────────────────────────

export interface EditBoardSheetProps {
  /** The ACTIVE board to edit. When null the sheet is closed (renders nothing). */
  board: Board | null;
  /** Week-start preference for timeframe boundary computation. */
  weekStartDay: 'monday' | 'sunday';
  /** Called when the sheet should close (Cancel or after a successful save). */
  onClose: () => void;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/** Snap a YYYY-MM-DD string to local start-of-day ISO (mirrors TaskEditSheet). */
function snapStart(ymd: string): string {
  const [y, m, d] = ymd.split('-').map(Number);
  return toLocalISO(new Date(y, m - 1, d, 0, 0, 0, 0));
}

/** Snap a YYYY-MM-DD string to local end-of-day ISO (mirrors TaskEditSheet). */
function snapEnd(ymd: string): string {
  const [y, m, d] = ymd.split('-').map(Number);
  return toLocalISO(new Date(y, m - 1, d, 23, 59, 59, 999));
}

/** Extract the YYYY-MM-DD portion from an ISO date string (safe for local-ISO). */
function toYMD(isoString: string | null | undefined): string {
  if (!isoString) return '';
  return isoString.slice(0, 10);
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * EditBoardSheet — sheet for editing metadata on an ACTIVE board (M2, #89).
 *
 * Wraps `BoardSetupForm` in `edit-active` mode, which renders:
 *   - Editable: name, timeframe, custom dates, center type, custom center name.
 *   - Read-only chip: board size (immutable — changing would force re-placement).
 *   - Hidden: isCore, spawnedFromTemplateId, isRandomized.
 *
 * Center-switch semantics (enforced at save time):
 *   - FREE → CHOSEN: disabled when no candidate task in boardTasks.
 *   - CHOSEN → FREE/CUSTOM_FREE: preserves the underlying BoardTask row
 *     (the placement is retained; the cell renders as FREE on top).
 *   - Anything → NONE: same preserve-placement rule.
 *
 * Dates: snapped to local start-of-day / end-of-day via `toLocalISO` so the
 * calendar window covers the full day in the user's timezone.
 *
 * NOTE on renaming: references to this board are by id everywhere (Achievement
 * tasks, recurring-template spawn records), so renaming is safe with no
 * additional propagation.
 */
export function EditBoardSheet({
  board,
  weekStartDay,
  onClose,
}: EditBoardSheetProps): React.ReactElement | null {
  // ── Controlled form state ────────────────────────────────────────────────

  const [name, setName] = useState('');
  const [size, setSize] = useState<3 | 4 | 5>(3); // read-only in edit-active mode
  const [timeframe, setTimeframe] = useState<Timeframe>(Timeframe.MONTHLY);
  const [customStartDate, setCustomStartDate] = useState('');
  const [customEndDate, setCustomEndDate] = useState('');
  const [centerType, setCenterType] = useState<CenterSquareType>(CenterSquareType.FREE);
  const [centerCustomName, setCenterCustomName] = useState('');

  // CHOSEN guard: CHOSEN is only available when the board already has a
  // centerTaskId (i.e., it was previously created with a chosen center AND
  // the placement still exists). Merely having candidate tasks in boardTasks
  // is insufficient — the sheet has no mechanism to collect a new centerTaskId,
  // so we cannot allow FREE → CHOSEN when centerTaskId is null.
  const [hasCandidateTasks, setHasCandidateTasks] = useState(false);

  const [saving, setSaving] = useState(false);
  const [validationError, setValidationError] = useState<string | null>(null);

  // ── Seed state from the board when it opens ───────────────────────────────

  useEffect(() => {
    if (!board) return;
    setName(board.name);
    setSize(board.boardSize as 3 | 4 | 5);
    setTimeframe(board.timeframe as Timeframe);
    setCustomStartDate(toYMD(board.startDate));
    setCustomEndDate(toYMD(board.endDate));
    setCenterType(board.centerSquareType as CenterSquareType);
    setCenterCustomName(board.centerSquareCustomName ?? '');
    setValidationError(null);
    setSaving(false);

    // Load boardTasks to determine whether CHOSEN is available.
    void db.boardTasks
      .where('boardId')
      .equals(board.id)
      .count()
      .then((count) => setHasCandidateTasks(count > 0));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [board?.id]); // re-seed only when the board's id changes, not on every render

  if (!board) return null;

  // ── Auto-computed boundaries for non-custom timeframes ────────────────────

  // Custom + Indefinite have no computed window (getTimeframeBoundaries throws).
  const computedBoundaries =
    timeframe !== Timeframe.CUSTOM && timeframe !== Timeframe.INDEFINITE
      ? getTimeframeBoundaries(timeframe, new Date(), weekStartDay)
      : null;

  // ── Save handler ──────────────────────────────────────────────────────────

  const handleSave = async () => {
    setValidationError(null);

    const trimmedName = name.trim();
    if (!trimmedName) {
      setValidationError('Board name is required.');
      return;
    }

    // Validate date ordering for custom timeframes.
    if (timeframe === Timeframe.CUSTOM) {
      if (!customStartDate || !customEndDate) {
        setValidationError('Both start and end dates are required for a custom timeframe.');
        return;
      }
      if (customEndDate < customStartDate) {
        setValidationError('End date must be on or after the start date.');
        return;
      }
    }

    // Validate center-switch: CHOSEN is only valid when board already has a
    // centerTaskId. The sheet has no mechanism to select a new center task,
    // so FREE → CHOSEN with centerTaskId == null would persist invalid state.
    if (centerType === CenterSquareType.CHOSEN && (board.centerTaskId == null || !hasCandidateTasks)) {
      setValidationError(
        'CHOSEN is unavailable — this board has no existing center task to restore.',
      );
      return;
    }

    const patch: UpdateActiveBoardPatch = { name: trimmedName, centerSquareType: centerType };

    // Center-square auxiliary fields.
    if (centerType === CenterSquareType.CUSTOM_FREE) {
      patch.centerSquareCustomName = centerCustomName.trim() || null;
    }
    // centerTaskId: passed as undefined (the cascade helper will keep the
    // existing value for CHOSEN, or clear it for other types).
    // See UpdateActiveBoardPatch doc for the asymmetry note.

    // Timeframe + dates.
    patch.timeframe = timeframe;
    if (timeframe === Timeframe.INDEFINITE) {
      // Ongoing board — anchor startDate to today, clear the deadline.
      const dayStart = new Date();
      dayStart.setHours(0, 0, 0, 0);
      patch.startDate = toLocalISO(dayStart);
      patch.endDate = null; // explicit clear (updateBoardAndCascade)
    } else if (timeframe === Timeframe.CUSTOM) {
      patch.startDate = snapStart(customStartDate);
      patch.endDate = snapEnd(customEndDate);
    } else if (computedBoundaries) {
      patch.startDate = computedBoundaries.startDate;
      patch.endDate = computedBoundaries.endDate;
    }

    setSaving(true);
    try {
      await updateBoardAndCascade(board.id, patch);
      onClose();
    } catch (err) {
      console.error('EditBoardSheet: save failed', err);
      setValidationError('Save failed — please try again.');
    } finally {
      setSaving(false);
    }
  };

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div className={styles.backdrop} onClick={onClose}>
      <div
        className={styles.sheetPanel}
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label="Edit board"
      >
        {/* Toolbar */}
        <div className={editStyles.sheetHeader}>
          <button
            className={editStyles.cancelButton}
            onClick={onClose}
            disabled={saving}
          >
            Cancel
          </button>
          <span className={editStyles.sheetTitle}>Edit board</span>
          <button
            className={editStyles.saveButton}
            onClick={handleSave}
            disabled={saving}
          >
            {saving ? 'Saving…' : 'Save'}
          </button>
        </div>

        {/* Board-size read-only chip (immutable on active boards) */}
        <div className={editStyles.readOnlyChip}>
          <span className={editStyles.readOnlyLabel}>Board size</span>
          <span className={editStyles.readOnlyValue}>{size}×{size}</span>
          <span className={editStyles.readOnlyNote}>(immutable on active boards)</span>
        </div>

        {/* Validation error */}
        {validationError && (
          <p className={editStyles.validationError}>{validationError}</p>
        )}

        {/* Center-switch guard note */}
        {(board.centerTaskId == null || !hasCandidateTasks) && centerType !== CenterSquareType.CHOSEN && (
          <p className={editStyles.infoNote}>
            "Pick one of my board tasks" is unavailable — this board has no existing center task.
          </p>
        )}

        {/* BoardSetupForm in edit-active mode */}
        <div className={editStyles.formBody}>
          <BoardSetupForm
            mode="edit-active"
            name={name}
            onNameChange={setName}
            size={size}
            onSizeChange={() => { /* no-op — size is read-only in edit-active mode */ }}
            timeframe={timeframe}
            onTimeframeChange={setTimeframe}
            customStartDate={customStartDate}
            onCustomStartDateChange={setCustomStartDate}
            customEndDate={customEndDate}
            onCustomEndDateChange={setCustomEndDate}
            centerType={centerType}
            onCenterTypeChange={setCenterType}
            centerCustomName={centerCustomName}
            onCenterCustomNameChange={setCenterCustomName}
            isRecurring={false}
            isCore={false}
            weekStartDay={weekStartDay}
            chosenCenterDisabled={board.centerTaskId == null || !hasCandidateTasks}
          />
        </div>
      </div>
    </div>
  );
}
