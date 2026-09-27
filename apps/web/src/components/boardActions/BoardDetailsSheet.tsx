import { useState } from 'react';
import { Timeframe, type Board, type WeekStartDay } from '@oybc/shared';
import { BoardSetupForm } from '../wizard/BoardSetupForm';
import { RisoButton } from '../riso';
import { useModalA11y } from '../../hooks/useModalA11y';
import { saveBoardDetails, BoardNotEditableError } from '../../db/operations/boards';
import {
  buildBoardDetailsPatch,
  countBoardDetailsEdits,
  seedBoardDetailsDraft,
  validateBoardDetails,
  type BoardDetailsDraft,
} from './boardDetailsPatch';
import styles from './BoardDetailsSheet.module.css';

export interface BoardDetailsSheetProps {
  /** The ACTIVE, unsealed board being edited (the menu only offers this
   *  sheet while `editable` — plan D3). */
  board: Board;
  weekStartDay: WeekStartDay;
  /** Backdrop click / Escape / Cancel (with a dirty-discard confirm). */
  onClose: () => void;
  /** D11 — the save found the board sealed / deleted; the caller closes the
   *  sheet and shows the "Board closed" notice (`BOARD_CLOSED_MESSAGE`). */
  onBoardClosed: () => void;
  /** Fired after a successful save; the caller shows the "Board saved" toast. */
  onSaved: () => void;
}

/**
 * BoardDetailsSheet — the "Board details…" menu item's sheet (Board Edit
 * redesign slice 2, plan D4/D5). Renamed from "Board settings" to avoid the
 * `/profile/board-settings` collision. Commits independently via
 * `saveBoardDetails` (a metadata-only patch, one transaction) — NOT part of
 * the squares draft, since it only opens outside edit mode.
 *
 * Fields: the immutable size chip + `BoardSetupForm` in `edit-active` mode
 * (name, dates for custom/ongoing only — no center selector since Board Edit
 * slice 3, D6: the center changes only in the squares editor). The iOS twin is
 * `BoardDetailsSheetView.swift` over the same `BoardDetailsDraft` contract
 * (`boardDetailsPatch.ts` ↔ `BoardDetailsDraft.swift`).
 */
export function BoardDetailsSheet({
  board,
  weekStartDay,
  onClose,
  onBoardClosed,
  onSaved,
}: BoardDetailsSheetProps): React.ReactElement {
  const [draft, setDraft] = useState<BoardDetailsDraft>(() => seedBoardDetailsDraft(board));
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const editCount = countBoardDetailsEdits(board, draft);
  const dirty = editCount > 0;
  const validationError = validateBoardDetails(draft);
  const canSave = dirty && !validationError && !saving;

  const requestClose = (): void => {
    if (saving) return;
    if (dirty) {
      setConfirmDiscard(true);
    } else {
      onClose();
    }
  };

  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel: requestClose,
  });

  const handleSave = async (): Promise<void> => {
    setError(null);
    if (validationError) {
      setError(validationError);
      return;
    }
    const patch = buildBoardDetailsPatch(board, draft, weekStartDay);
    if (!patch) {
      onClose();
      return;
    }
    setSaving(true);
    try {
      await saveBoardDetails(board.id, patch);
      onSaved();
    } catch (err) {
      if (err instanceof BoardNotEditableError) {
        onBoardClosed();
        return;
      }
      console.error('BoardDetailsSheet: save failed', err);
      setError('Save failed — please try again.');
      setSaving(false);
    }
  };

  return (
    <div className={styles.backdrop} onClick={requestClose} role="presentation">
      <div
        ref={modalRef}
        className={styles.sheet}
        role="dialog"
        aria-label="Board details"
        {...modalProps}
        onClick={(e) => e.stopPropagation()}
      >
        <div className={styles.header}>
          <h2 className={styles.title}>Board details</h2>
          <span className={styles.sizeChip}>
            Board size
            <span className={styles.sizeValue}>{board.boardSize}×{board.boardSize}</span>
          </span>
        </div>

        {error && (
          <p className={styles.error} role="alert">
            {error}
          </p>
        )}

        {confirmDiscard ? (
          <div className={styles.confirmCard} role="group" aria-label="Discard changes?">
            <div className={styles.confirmTitle}>Discard changes?</div>
            <p className={styles.confirmBody}>Your unsaved changes will be lost.</p>
            <div className={styles.confirmBtns}>
              <RisoButton size="small" autoFocus onClick={() => setConfirmDiscard(false)}>
                Keep editing
              </RisoButton>
              <RisoButton kind="primary" size="small" onClick={onClose}>
                Discard
              </RisoButton>
            </div>
          </div>
        ) : (
          <>
            <BoardSetupForm
              mode="edit-active"
              name={draft.name}
              onNameChange={(name) => setDraft((d) => ({ ...d, name }))}
              size={board.boardSize as 3 | 4 | 5}
              onSizeChange={() => { /* no-op — size is immutable on active boards */ }}
              timeframe={draft.timeframe}
              onTimeframeChange={(timeframe) => setDraft((d) => ({ ...d, timeframe }))}
              customStartDate={draft.customStartDate}
              onCustomStartDateChange={(customStartDate) =>
                setDraft((d) => ({ ...d, customStartDate }))
              }
              customEndDate={draft.customEndDate}
              onCustomEndDateChange={(customEndDate) =>
                setDraft((d) => ({ ...d, customEndDate }))
              }
              // edit-active hides the center selector entirely (slice 3, D6)
              // — centerType/onCenterTypeChange are optional there, so
              // nothing is passed.
              isRecurring={false}
              isCore={false}
              weekStartDay={weekStartDay}
              storedWindow={
                board.endDate ? { startDate: board.startDate, endDate: board.endDate } : undefined
              }
            />

            {(draft.timeframe === Timeframe.CUSTOM || draft.timeframe === Timeframe.INDEFINITE) && (
              <p className={styles.hint}>
                End date offers “None — no end date” for an ongoing board.
              </p>
            )}

            <div className={styles.footer}>
              <RisoButton kind="neutral" onClick={requestClose} disabled={saving}>
                Cancel
              </RisoButton>
              <RisoButton kind="primary" disabled={!canSave} onClick={() => void handleSave()}>
                {saving ? 'Saving…' : 'Save'}
              </RisoButton>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
