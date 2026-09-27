import { useEffect, useState } from 'react';
import { CenterSquareType, type Board } from '@oybc/shared';
import { RisoButton, RisoSegmented, RisoSectionLabel } from '../riso';
import type { RisoSegmentedOption } from '../riso';
import { BoardNotEditableError, type UpdateActiveBoardPatch } from '../../db/operations/boards';
import { BOARD_CLOSED_MESSAGE } from '../boardActions/boardDetailsPatch';
import styles from './BoardEditPanel.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

export type SubMode = 'editTasks' | 'rearrange';

const SUB_MODE_OPTIONS: ReadonlyArray<RisoSegmentedOption<SubMode>> = [
  { value: 'editTasks', label: 'Edit tasks' },
  { value: 'rearrange', label: 'Rearrange' },
];

export interface BoardEditPanelProps {
  /** The ACTIVE board being edited. */
  board: Board;
  /**
   * Current square-editing sub-mode — lifted to BoardPlaySurface so the
   * grid can gate tap interactions. The panel renders the toggle but
   * delegates state ownership to the parent.
   */
  subMode: SubMode;
  /** Called when the user switches sub-mode via the segmented toggle. */
  onSubModeChange: (mode: SubMode) => void;
  /**
   * Number of staged square edits (Replace + Edit-task Done actions) from
   * BoardPlaySurface. Added to the center-toggle edit (if any) for the
   * combined display and dirty/canSave checks.
   */
  squareEditCount: number;
  /**
   * Commits the WHOLE Save: staged square edits (BoardTask replacements +
   * global Task field patches + reorders + removals) AND, when the center
   * type changed, a `{ centerSquareType }` metadata patch — all in one
   * atomic Dexie transaction (board-integrity PR-4, item 3,
   * docs/BOARD_INTEGRITY.md). `undefined` when the center is unchanged (no
   * metadata write). Must throw on error (the panel's catch block surfaces
   * the failure to the user) — a throw rolls back every write in the
   * transaction, so a failed Save can never leave the board half-edited.
   */
  onExtraCommit: (metadataPatch: UpdateActiveBoardPatch | undefined) => Promise<void>;
  /**
   * Called when the user cancels with no unsaved changes, or after
   * the inline "Discard changes?" confirm — and also after a Save that
   * finds the board sealed or deleted mid-session (D11: the closed-board
   * copy is shown first, then the panel exits edit mode).
   */
  onCancel: () => void;
  /**
   * Called after a successful save (both square commits and any center
   * metadata patch). The parent exits edit mode and shows the "Board
   * saved" green toast.
   */
  onSaved: () => void;
  /**
   * Phase 2b — controlled draft centerSquareType, READ-ONLY here (only used
   * to compute the edit count against `board.centerSquareType`). Lifted to
   * BoardPlaySurface, which owns the value and updates it directly from the
   * grid's Free⇄Task tap toggle (`SquareTapMenu`'s onMakeFree/onMakeTask) —
   * NOT through this panel. (The `BoardSetupForm` center selector moved to
   * the Board details sheet, Board Edit redesign slice 2; the grid tap is
   * the only way to change the center from inside the squares editor.)
   */
  centerType: CenterSquareType;
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * BoardEditPanel — left-rail edit chrome shown in place of the play stats rail
 * when the board is in edit mode. Board Edit redesign slice 2 slimmed this to
 * the SQUARES EDITOR ONLY — name / dates / Repeats / Archive moved out to the
 * title-row "…" menu's own sheets (`components/boardActions/`:
 * `BoardDetailsSheet`, `BoardRepeatSheet`; Archive is a menu confirm dialog).
 * This panel keeps only what's still staged behind ONE Save:
 *   - Cancel (confirms if dirty) + "Editing squares" gold pill with red dot.
 *   - Edit-tasks ⇄ Rearrange sub-mode toggle.
 *   - The center-square Free⇄Task toggle (the grid tap; see `centerType`).
 *   - Save row: live edit counter (square edits + a center change) + Save.
 *
 * @param board - The ACTIVE board to edit. Must be non-null.
 * @param onCancel - Called on clean cancel, after Discard confirm, or after
 *   a save that finds the board sealed/deleted (D11).
 * @param onSaved - Called after a successful save (square edits + any
 *   center metadata patch, one transaction).
 */
export function BoardEditPanel({
  board,
  subMode,
  onSubModeChange,
  squareEditCount,
  onExtraCommit,
  onCancel,
  onSaved,
  centerType,
}: BoardEditPanelProps): React.ReactElement {
  const [confirm, setConfirm] = useState<'cancel' | null>(null);
  const [saving, setSaving] = useState(false);
  const [validationError, setValidationError] = useState<string | null>(null);

  // ── Reset transient UI state on (re-)entry ───────────────────────────────

  useEffect(() => {
    setValidationError(null);
    setSaving(false);
    setConfirm(null);
  // Re-seed only when the board's id changes, not on every reactive update.
  }, [board.id]);

  // ── Edit counter + dirty detection ───────────────────────────────────────

  const centerChanged = centerType !== (board.centerSquareType as CenterSquareType);
  const editCount = squareEditCount + (centerChanged ? 1 : 0);

  const dirty = editCount > 0;
  const canSave = dirty && !saving;

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

    setSaving(true);
    try {
      await onExtraCommit(centerChanged ? { centerSquareType: centerType } : undefined);
    } catch (err) {
      if (err instanceof BoardNotEditableError) {
        setValidationError(BOARD_CLOSED_MESSAGE);
        setSaving(false);
        onCancel();
        return;
      }
      console.error('BoardEditPanel: save failed', err);
      setValidationError('Save failed — please try again.');
      setSaving(false);
      return;
    }

    onSaved();
    // Note: setSaving(false) not called on success — onSaved() exits edit mode,
    // unmounting the panel. Calling setState on an unmounted component is a no-op
    // in React 18+ but would generate a console warning; omitting it is cleaner.
  };

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div className={styles.panel}>
      {/* Header: Cancel + "Editing squares" gold pill with red dot */}
      <div className={styles.editbar}>
        <button
          type="button"
          className={styles.cancelBtn}
          onClick={requestCancel}
          disabled={saving}
          aria-label="Cancel editing"
          /* move focus into the panel on entry — the Edit button that had focus
             just unmounted, so without this keyboard focus drops to <body>. */
          autoFocus
        >
          ← Cancel
        </button>
        <span className={styles.editingPill} aria-label="Board is in edit mode">
          Editing squares
        </span>
      </div>

      {/* Validation error banner */}
      {validationError && (
        <p className={styles.validationError} role="alert">
          {validationError}
        </p>
      )}

      {/* Squares sub-mode: Edit tasks ⇄ Rearrange. */}
      <div className={styles.squaresSection}>
        <RisoSectionLabel>Squares</RisoSectionLabel>
        <div className={styles.modeSeg}>
          <RisoSegmented
            options={SUB_MODE_OPTIONS}
            value={subMode}
            onChange={onSubModeChange}
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

      {/* Inline confirm card or Save row */}
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
      ) : (
        /* Save row: N edits counter + Save button */
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
      )}
    </div>
  );
}
