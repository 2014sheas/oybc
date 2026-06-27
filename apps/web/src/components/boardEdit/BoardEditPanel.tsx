import { useEffect, useState } from 'react';
import {
  CenterSquareType,
  Timeframe,
  toLocalISO,
  getTimeframeBoundaries,
  type WeekStartDay,
  type Board,
} from '@oybc/shared';
import { BoardSetupForm } from '../wizard/BoardSetupForm';
import { RisoButton, RisoSegmented, RisoSectionLabel } from '../riso';
import type { RisoSegmentedOption } from '../riso';
import {
  updateBoardAndCascade,
  archiveBoard,
  type UpdateActiveBoardPatch,
} from '../../db/operations/boards';
import { db } from '../../db/database';
import styles from './BoardEditPanel.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

type SubMode = 'editTasks' | 'rearrange';

const SUB_MODE_OPTIONS: ReadonlyArray<RisoSegmentedOption<SubMode>> = [
  { value: 'editTasks', label: 'Edit tasks' },
  { value: 'rearrange', label: 'Rearrange' },
];

export interface BoardEditPanelProps {
  /** The ACTIVE board being edited. */
  board: Board;
  /** Week-start preference for timeframe boundary computation. */
  weekStartDay: WeekStartDay;
  /**
   * Called when the user cancels with no unsaved changes, or after
   * the inline "Discard changes?" confirm. The parent exits edit mode.
   */
  onCancel: () => void;
  /**
   * Called after a successful metadata save. The parent exits edit mode
   * and shows the "Board saved" green toast.
   */
  onSaved: () => void;
  /**
   * Called after the board is successfully archived. The parent
   * should navigate away (e.g., to /boards).
   */
  onArchived: () => void;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/** Extract YYYY-MM-DD from an ISO date string (safe for local-ISO). */
function toYMD(isoString: string | null | undefined): string {
  if (!isoString) return '';
  return isoString.slice(0, 10);
}

/** Snap a YYYY-MM-DD string to local start-of-day ISO. */
function snapStart(ymd: string): string {
  const [y, m, d] = ymd.split('-').map(Number);
  return toLocalISO(new Date(y, m - 1, d, 0, 0, 0, 0));
}

/** Snap a YYYY-MM-DD string to local end-of-day ISO. */
function snapEnd(ymd: string): string {
  const [y, m, d] = ymd.split('-').map(Number);
  return toLocalISO(new Date(y, m - 1, d, 23, 59, 59, 999));
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * BoardEditPanel — left-rail edit chrome shown in place of the play stats rail
 * when the board is in edit mode (Phase 1).
 *
 * Carries all form state previously held by EditBoardSheet, with the same
 * validation and save path (`updateBoardAndCascade`). Phase 1 scope:
 *   - Cancel (confirms if dirty) + "Editing" gold pill with red dot.
 *   - Board metadata fields via `BoardSetupForm` (name, timeframe, dates, center).
 *   - Immutable board-size chip (active boards cannot be resized).
 *   - Edit-tasks ⇄ Rearrange sub-mode toggle — switches hint text only; neither
 *     sub-mode is interactive until Phases 2–3.
 *   - Save row: live edit counter (count of changed metadata fields) + Save button.
 *   - Archive this board ghost button + inline confirm cards for Cancel/Archive.
 *
 * @param board - The ACTIVE board to edit. Must be non-null.
 * @param weekStartDay - Drives timeframe boundary computation.
 * @param onCancel - Called on clean cancel or after Discard confirm.
 * @param onSaved - Called after a successful `updateBoardAndCascade` write.
 * @param onArchived - Called after a successful `archiveBoard` write.
 */
export function BoardEditPanel({
  board,
  weekStartDay,
  onCancel,
  onSaved,
  onArchived,
}: BoardEditPanelProps): React.ReactElement {
  // ── Controlled form state ────────────────────────────────────────────────

  const [name, setName] = useState('');
  const [timeframe, setTimeframe] = useState<Timeframe>(Timeframe.MONTHLY);
  const [customStartDate, setCustomStartDate] = useState('');
  const [customEndDate, setCustomEndDate] = useState('');
  const [centerType, setCenterType] = useState<CenterSquareType>(CenterSquareType.FREE);
  const [centerCustomName, setCenterCustomName] = useState('');

  const [subMode, setSubMode] = useState<SubMode>('editTasks');
  const [confirm, setConfirm] = useState<'cancel' | 'archive' | null>(null);
  const [saving, setSaving] = useState(false);
  const [validationError, setValidationError] = useState<string | null>(null);

  // CHOSEN guard: only available when the board already has a centerTaskId
  // AND at least one placed BoardTask exists (same rule as EditBoardSheet).
  const [hasCandidateTasks, setHasCandidateTasks] = useState(false);

  // Board size is immutable on active boards — read directly from the prop.
  const size = board.boardSize as 3 | 4 | 5;

  // ── Seed state from the board ─────────────────────────────────────────────

  useEffect(() => {
    setName(board.name);
    setTimeframe(board.timeframe as Timeframe);
    setCustomStartDate(toYMD(board.startDate));
    setCustomEndDate(toYMD(board.endDate));
    setCenterType(board.centerSquareType as CenterSquareType);
    setCenterCustomName(board.centerSquareCustomName ?? '');
    setValidationError(null);
    setSaving(false);
    setConfirm(null);

    void db.boardTasks
      .where('boardId')
      .equals(board.id)
      .count()
      .then((count) => setHasCandidateTasks(count > 0));
  // Re-seed only when the board's id changes, not on every reactive update
  // (mirrors EditBoardSheet's seeding strategy to avoid disrupting edits).
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [board.id]);

  // ── Computed boundaries for non-custom timeframes ────────────────────────

  // Custom + Indefinite have no computed window (getTimeframeBoundaries throws).
  const computedBoundaries =
    timeframe !== Timeframe.CUSTOM && timeframe !== Timeframe.INDEFINITE
      ? getTimeframeBoundaries(timeframe, new Date(), weekStartDay)
      : null;

  // ── Edit counter + dirty detection ───────────────────────────────────────

  // Count the number of metadata field-groups that differ from the stored board.
  // Each group counts as 1 edit so the counter reflects meaningful changes,
  // not raw keystrokes. Square edits (Phases 2–3) will increment the same counter.
  const origStart = toYMD(board.startDate);
  const origEnd = toYMD(board.endDate);
  const origCenterCustomName = board.centerSquareCustomName ?? '';

  let editCount = 0;
  if (name !== board.name) editCount++;
  if (timeframe !== (board.timeframe as Timeframe)) editCount++;
  // Dates: count as one group (start + end together reflect one timeframe window).
  if (customStartDate !== origStart || customEndDate !== origEnd) editCount++;
  // Center: count as one group (type + custom name are one logical change).
  if (
    centerType !== (board.centerSquareType as CenterSquareType) ||
    centerCustomName !== origCenterCustomName
  )
    editCount++;

  const dirty = editCount > 0;
  const canSave = dirty && name.trim().length > 0 && !saving;

  // ── Handlers ─────────────────────────────────────────────────────────────

  const requestCancel = () => {
    if (dirty) {
      setConfirm('cancel');
    } else {
      onCancel();
    }
  };

  const handleSave = async () => {
    setValidationError(null);

    const trimmedName = name.trim();
    if (!trimmedName) {
      setValidationError('Board name is required.');
      return;
    }

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

    if (
      centerType === CenterSquareType.CHOSEN &&
      (board.centerTaskId == null || !hasCandidateTasks)
    ) {
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

    // Timeframe + dates.
    patch.timeframe = timeframe;
    if (timeframe === Timeframe.INDEFINITE) {
      // Ongoing board — anchor startDate to today, clear the deadline.
      const dayStart = new Date();
      dayStart.setHours(0, 0, 0, 0);
      patch.startDate = toLocalISO(dayStart);
      patch.endDate = null;
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
      onSaved();
    } catch (err) {
      console.error('BoardEditPanel: save failed', err);
      setValidationError('Save failed — please try again.');
      setSaving(false);
    }
    // Note: setSaving(false) not called on success — onSaved() exits edit mode,
    // unmounting the panel. Calling setState on an unmounted component is a no-op
    // in React 18+ but would generate a console warning; omitting it is cleaner.
  };

  const handleArchive = async () => {
    setSaving(true);
    try {
      await archiveBoard(board.id);
      onArchived();
      // Same as handleSave: onArchived() navigates away, unmounting the panel.
    } catch (err) {
      console.error('BoardEditPanel: archive failed', err);
      setValidationError('Archive failed — please try again.');
      setConfirm(null);
      setSaving(false);
    }
  };

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div className={styles.panel}>
      {/* Header: Cancel + "Editing" gold pill with red dot */}
      <div className={styles.editbar}>
        <button
          type="button"
          className={styles.cancelBtn}
          onClick={requestCancel}
          disabled={saving}
          aria-label="Cancel editing"
        >
          ← Cancel
        </button>
        <span className={styles.editingPill} aria-label="Board is in edit mode">
          Editing
        </span>
      </div>

      {/* Read-only board-size chip (immutable on active boards) */}
      <div className={styles.sizeChip}>
        <span className={styles.sizeLabel}>Board size</span>
        <span className={styles.sizeValue}>{board.boardSize}×{board.boardSize}</span>
        <span className={styles.sizeNote}>(immutable on active boards)</span>
      </div>

      {/* Validation error banner */}
      {validationError && (
        <p className={styles.validationError} role="alert">
          {validationError}
        </p>
      )}

      {/* Metadata fields: name, timeframe, custom dates, center type.
          BoardSetupForm in edit-active mode hides the size segmented (sizeBlock
          returns null) — the read-only sizeChip above replaces it. */}
      <BoardSetupForm
        mode="edit-active"
        name={name}
        onNameChange={setName}
        size={size}
        onSizeChange={() => { /* no-op — size is immutable on active boards */ }}
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

      {/* Squares sub-mode: Edit tasks ⇄ Rearrange.
          Phase 1: toggle renders and switches the hint text only.
          Neither sub-mode is interactive until Phases 2–3. */}
      <div className={styles.squaresSection}>
        <RisoSectionLabel>Squares</RisoSectionLabel>
        <div className={styles.modeSeg}>
          <RisoSegmented
            options={SUB_MODE_OPTIONS}
            value={subMode}
            onChange={setSubMode}
            variant="pill"
            aria-label="Square edit mode"
          />
        </div>
        <p className={styles.hint}>
          {subMode === 'editTasks' ? (
            <><b>Tap a square</b> to replace or edit its task.</>
          ) : (
            <><b>Drag a square</b> to drop it in — the rest shift to make room.</>
          )}
        </p>
      </div>

      {/* Inline confirm cards or Save row + Archive button */}
      {confirm === 'cancel' ? (
        <div className={styles.confirmCard} role="group" aria-label="Discard changes?">
          <div className={styles.confirmTitle}>Discard changes?</div>
          <p className={styles.confirmBody}>
            You have {editCount} unsaved edit{editCount === 1 ? '' : 's'}.
          </p>
          <div className={styles.confirmBtns}>
            <RisoButton size="small" autoFocus onClick={() => setConfirm(null)}>
              Keep editing
            </RisoButton>
            <RisoButton kind="primary" size="small" onClick={onCancel}>
              Discard
            </RisoButton>
          </div>
        </div>
      ) : confirm === 'archive' ? (
        <div
          className={styles.confirmCard}
          role="group"
          aria-label="Archive this board?"
        >
          <div className={styles.confirmTitle}>Archive this board?</div>
          <p className={styles.confirmBody}>
            It moves to Archived. Your streak and history are kept — restore it anytime.
          </p>
          <div className={styles.confirmBtns}>
            <RisoButton
              size="small"
              autoFocus
              onClick={() => setConfirm(null)}
              disabled={saving}
            >
              Keep editing
            </RisoButton>
            <RisoButton
              kind="primary"
              size="small"
              onClick={() => void handleArchive()}
              disabled={saving}
            >
              Archive
            </RisoButton>
          </div>
        </div>
      ) : (
        <>
          {/* Save row: N edits counter + Save button */}
          <div className={styles.saveRow}>
            <div className={styles.editCounter} aria-live="polite" aria-label={`${editCount} edit${editCount === 1 ? '' : 's'}`}>
              <div className={styles.editCount}>{editCount}</div>
              <div className={styles.editLabel}>edit{editCount === 1 ? '' : 's'}</div>
            </div>
            <RisoButton
              kind="primary"
              fullWidth
              disabled={!canSave}
              onClick={() => void handleSave()}
            >
              {saving ? 'Saving…' : 'Save changes'}
            </RisoButton>
          </div>

          {/* Archive ghost button */}
          <button
            type="button"
            className={styles.archiveBtn}
            onClick={() => setConfirm('archive')}
            disabled={saving}
          >
            Archive this board
          </button>
        </>
      )}
    </div>
  );
}
