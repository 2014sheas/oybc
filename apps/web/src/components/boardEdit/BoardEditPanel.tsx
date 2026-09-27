import { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import type { Board } from '@oybc/shared';
import { RisoButton, RisoIcon } from '../riso';
import { BoardNotEditableError } from '../../db/operations/boards';
import { BOARD_CLOSED_MESSAGE } from '../boardActions/boardDetailsPatch';
import { BoardActionConfirmDialog } from '../boardActions/BoardActionConfirmDialog';
import styles from './BoardEditPanel.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface BoardEditPanelProps {
  /** The board being edited. */
  board: Board;
  /** Edit consolidation (plan D3/D4) — whether the SQUARES section is
   *  editable this session (`canEditSquares`, captured once at Edit entry).
   *  When false: the top-left control reads `Done` (not `Cancel`) and calls
   *  `onCancel` directly, and no save row / hints / discard card render —
   *  there is nothing to save or discard. */
  squaresEditable: boolean;
  /** Number of staged square edits (D11 — replacements + adds + removals +
   *  task overrides + lock changes + a center change + position edits). */
  editCount: number;
  /** OQ8 — disabled when fewer than 2 unfixed slots hold a task. */
  canShuffle: boolean;
  onShuffle: () => void;
  /**
   * Commits the WHOLE Save: every staged squares-editor edit (D15, ONE
   * atomic transaction, `commitSquareEdits`). Must throw on error (the
   * panel's catch block surfaces the failure to the user) — a throw rolls
   * back every write in the transaction, so a failed Save can never leave
   * the board half-edited.
   */
  onSaveEdits: () => Promise<void>;
  /**
   * Called when the user cancels with no unsaved changes, or after
   * the inline "Discard changes?" confirm — and also on the OK of the "Board closed" notice after a Save that
   * finds the board sealed or deleted mid-session (D11: the closed-board
   * copy is shown first, then the panel exits edit mode).
   */
  onCancel: () => void;
  /**
   * Called after a successful save. The parent exits edit mode and shows
   * the "Board saved" green toast.
   */
  onSaved: () => void;
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * BoardEditPanel — left-rail edit chrome shown in place of the play stats
 * rail while the board is in edit mode. Board Edit redesign slice 3 (D7)
 * retired the Edit tasks ⇄ Rearrange sub-mode toggle — there is ONE grid
 * now (`SquaresEditGrid`, rendered by `BoardEditColumn`), so this panel is
 * just the Cancel/Done + Editing header + (when `squaresEditable`) the D18
 * save bar (edit count · Shuffle · responsive hint · Save changes). Edit
 * consolidation (plan D4/D5) added the non-editable variant — `squaresEditable
 * = false` on an ended/closed/archived/completed board, where the header's
 * `Done` just exits Edit; the BOARD section (rendered by `BoardEditColumn`)
 * is the only thing left to do there.
 *
 * @param board - The board being edited. Must be non-null.
 * @param squaresEditable - Whether the SQUARES section is editable this
 *   session (see the prop doc for the non-editable variant).
 * @param onCancel - Called on clean cancel, after Discard confirm, on
 *   `Done` (non-editable variant), or after a save that finds the board
 *   sealed/deleted (D11).
 * @param onSaved - Called after a successful save.
 */
export function BoardEditPanel({
  board,
  squaresEditable,
  editCount,
  canShuffle,
  onShuffle,
  onSaveEdits,
  onCancel,
  onSaved,
}: BoardEditPanelProps): React.ReactElement {
  const [confirm, setConfirm] = useState<'cancel' | null>(null);
  const [saving, setSaving] = useState(false);
  const [validationError, setValidationError] = useState<string | null>(null);
  // D11 — the Save found the board sealed / deleted mid-session. Shown as a
  // "Board closed" notice; its OK exits edit mode (iOS twin: BoardPlayView's
  // "Board closed" alert). Held HERE, not after `onCancel()`, because exiting
  // edit mode unmounts this panel and would drop any message with it.
  const [boardClosed, setBoardClosed] = useState(false);

  // ── Reset transient UI state on (re-)entry ───────────────────────────────

  useEffect(() => {
    setValidationError(null);
    setSaving(false);
    setConfirm(null);
  // Re-seed only when the board's id changes, not on every reactive update.
  }, [board.id]);

  const dirty = editCount > 0;
  const canSave = dirty && !saving && !boardClosed;

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
      await onSaveEdits();
    } catch (err) {
      if (err instanceof BoardNotEditableError) {
        setSaving(false);
        setBoardClosed(true);
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
      {/* Portaled: the panel sits in the sticky rail, whose stacking context
          would trap a fixed backdrop behind the grid (see BoardOptionsSection). */}
      {boardClosed &&
        createPortal(
          <BoardActionConfirmDialog
            title="Board closed"
            body={BOARD_CLOSED_MESSAGE}
            cancelLabel={null}
            confirmLabel="OK"
            onCancel={onCancel}
            onConfirm={onCancel}
          />,
          document.body,
        )}
      {/* Header: Cancel/Done + "Editing" gold pill with red dot (D5) */}
      <div className={styles.editbar}>
        {squaresEditable ? (
          <button
            type="button"
            className={styles.cancelBtn}
            onClick={requestCancel}
            disabled={saving || boardClosed}
            aria-label="Cancel editing"
            /* move focus into the panel on entry — the Edit button that had focus
               just unmounted, so without this keyboard focus drops to <body>. */
            autoFocus
          >
            ← Cancel
          </button>
        ) : (
          // D4 — nothing to save/discard when the squares section is hidden;
          // the top-left control just exits Edit.
          <button
            type="button"
            className={styles.cancelBtn}
            onClick={onCancel}
            aria-label="Done editing"
            autoFocus
          >
            ← Done
          </button>
        )}
        <span className={styles.editingPill} aria-label="Board is in edit mode">
          Editing
        </span>
      </div>

      {squaresEditable && (
        <>
          {/* Validation error banner */}
          {validationError && (
            <p className={styles.validationError} role="alert">
              {validationError}
            </p>
          )}

          {/* Inline confirm card or Save bar (D18) */}
          {confirm === 'cancel' ? (
            <div className={styles.confirmCard} role="group" aria-label="Discard changes?">
              <div className={styles.confirmTitle}>Discard changes?</div>
              <p className={styles.confirmBody}>
                Your unsaved changes will be lost.
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
            <>
              {/* Save row: N edits counter + Shuffle + Save button (D18) */}
              <div className={styles.saveRow}>
                <div className={styles.editCounter} aria-live="polite" aria-label={editCount === 0 ? 'No changes' : `${editCount} edit${editCount === 1 ? '' : 's'}`}>
                  <div className={styles.editCount}>{editCount}</div>
                  <div className={styles.editLabel}>{editCount === 0 ? 'no changes' : `edit${editCount === 1 ? '' : 's'}`}</div>
                </div>
                <RisoButton
                  kind="neutral"
                  size="small"
                  icon={<RisoIcon name="shuffle" size={14} />}
                  disabled={!canShuffle || saving || boardClosed}
                  onClick={onShuffle}
                >
                  Shuffle
                </RisoButton>
                <RisoButton
                  kind="primary"
                  fullWidth
                  disabled={!canSave}
                  onClick={() => void handleSave()}
                >
                  {saving ? 'Saving…' : 'Save changes'}
                </RisoButton>
              </div>

              {/* D18 — responsive hint: desktop explains Shuffle's mechanics,
                  phone keeps it to the tap/hold gesture. */}
              <p className={`${styles.hint} ${styles.hintDesktop}`}>
                Shuffle rearranges every square except locked ones. Nothing is written until you save.
              </p>
              <p className={`${styles.hint} ${styles.hintPhone}`}>
                Tap a square for options. Hold to move it.
              </p>
            </>
          )}
        </>
      )}
    </div>
  );
}
