import { useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import { Timeframe, type Board, type RecurringBoardTemplate, type Task, type WeekStartDay } from '@oybc/shared';
import { RisoCard, RisoIcon, RisoSectionLabel } from '../riso';
import { archiveBoard, deleteBoard } from '../../db/operations/boards';
import { closeBoard, reopenBoard } from '../../db/operations/boardLifecycle';
import { boardItemDraftPolicy, buildBoardMenuItems, DISCARD_SQUARES_SUFFIX, type BoardMenuItemKind } from './boardMenu';
import { BoardDetailsSheet } from './BoardDetailsSheet';
import { BoardRepeatSheet } from './BoardRepeatSheet';
import { CoreDefaultsSheetHost } from './CoreDefaultsSheetHost';
import { BoardActionConfirmDialog } from './BoardActionConfirmDialog';
import { BOARD_CLOSED_MESSAGE } from './boardDetailsPatch';
import styles from './BoardOptionsSection.module.css';

/** Which sheet/dialog is currently presented from the BOARD section. */
type BoardAction =
  | 'details'
  | 'repeat'
  | 'coreDefaults'
  | 'confirmArchive'
  | 'confirmDelete'
  | 'confirmReopen'
  | 'confirmDiscard'
  | null;

/** A one-button notice shown after a sheet / confirm closes (iOS `.alert` + OK). */
interface BoardActionNotice {
  title: string;
  body: string;
}

/** D11 — a board sealed / deleted while a menu sheet was open. iOS twin:
 *  `BoardActionsPresenter`'s "Board closed" alert. */
const BOARD_CLOSED_NOTICE: BoardActionNotice = { title: 'Board closed', body: BOARD_CLOSED_MESSAGE };

export interface BoardOptionsSectionProps {
  board: Board;
  userId: string | undefined;
  sourceTemplate: RecurringBoardTemplate | null | undefined;
  templatesLoaded: boolean;
  weekStartDay: WeekStartDay;
  taskMap: Record<string, Task>;
  dealtTaskIds: string[];
  counterFamilyByTaskId: Record<string, string>;
  /** Whether the squares-editor draft has unsaved edits (plan D8) — drives
   *  the discard suffix/confirm on Archive/Delete/Close/Reopen. */
  squaresDirty: boolean;
  /** Fired after a successful Board-details/Repeat/Core-defaults save (the
   *  caller shows the "Board saved" toast; Edit itself is NOT exited — D9). */
  onDetailsSaved: () => void;
  /** Fired on a successful Close/Reopen (D9: exits Edit — the pill flip IS
   *  the feedback), and before `onRemoved` on a successful Archive/Delete. */
  onExitEdit: () => void;
  /** Fired after a successful Archive / Delete, after `onExitEdit`. */
  onRemoved: () => void;
}

/**
 * BoardOptionsSection — the Edit screen's **BOARD** section (Edit
 * consolidation, plan D6): a `RisoSectionLabel "BOARD"` + `RisoCard` of rows
 * from `buildBoardMenuItems`, plus every sheet/dialog a row opens. Retired
 * the title-row "…" `BoardActionsMenu` trigger entirely — this is now the
 * ONLY entry point to Board details / Repeat / Core defaults / Close /
 * Reopen / Archive / Delete. Rendered by `BoardEditColumn`, below the
 * squares editor (or its `squaresLockedReason` line).
 */
export function BoardOptionsSection({
  board,
  userId,
  sourceTemplate,
  templatesLoaded,
  weekStartDay,
  taskMap,
  dealtTaskIds,
  counterFamilyByTaskId,
  squaresDirty,
  onDetailsSaved,
  onExitEdit,
  onRemoved,
}: BoardOptionsSectionProps): React.ReactElement {
  const [action, setAction] = useState<BoardAction>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<BoardActionNotice | null>(null);
  // D8 discardFirst — which row the "Discard changes?" confirm is gating.
  const [discardTarget, setDiscardTarget] = useState<'close' | 'reopen' | null>(null);

  /** A menu sheet's save hit a closed board: swap the sheet for the notice. */
  const handleBoardClosed = (): void => {
    setAction(null);
    setNotice(BOARD_CLOSED_NOTICE);
  };

  // Pinned per-render instant (react-hooks/purity — mirrors BoardPlaySurface's
  // `nowPinned`), captured once when this section mounts (Edit entry) since
  // this component's lifetime IS an Edit session. `Date.now()` itself is
  // flagged as an impure call by the react-compiler lint rule, so go through
  // `new Date()` like that surface does.
  const nowPinned = useMemo(() => new Date(), []);
  const now = nowPinned.getTime();
  const menuItems = buildBoardMenuItems({ board, sourceTemplate, templatesLoaded, now });

  const handleSelect = (kind: BoardMenuItemKind): void => {
    const policy = boardItemDraftPolicy(kind);
    if (policy === 'discardFirst' && squaresDirty) {
      setDiscardTarget(kind === 'close' || kind === 'reopen' ? kind : null);
      setAction('confirmDiscard');
      return;
    }
    switch (kind) {
      case 'details':
        setAction('details');
        break;
      case 'coreDefaults':
        setAction('coreDefaults');
        break;
      case 'repeat':
        setAction('repeat');
        break;
      case 'archive':
        setAction('confirmArchive');
        break;
      case 'delete':
        setAction('confirmDelete');
        break;
      case 'close':
        void handleClose();
        break;
      case 'reopen':
        setAction('confirmReopen');
        break;
    }
  };

  /** D8 discardFirst confirmed — proceed to the gated row's own action. */
  const handleDiscardConfirmed = (): void => {
    const target = discardTarget;
    setDiscardTarget(null);
    if (target === 'close') {
      setAction(null);
      void handleClose();
    } else if (target === 'reopen') {
      setAction('confirmReopen');
    } else {
      setAction(null);
    }
  };

  // Close / Reopen give no toast — the CLOSED / ENDED pill flipping IS the
  // feedback (iOS parity: `BoardActionsPresenter` shows nothing on success).
  // "Board saved" is edit-save copy and would be wrong here.
  const handleClose = async (): Promise<void> => {
    setBusy(true);
    try {
      await closeBoard(board.id);
      setBusy(false);
      onExitEdit();
    } catch (err) {
      console.error('BoardOptionsSection: close failed', err);
      setBusy(false);
      // One generic failure for every error (iOS parity). BOARD_CLOSED_NOTICE
      // ("…your changes weren't saved") is for a board sealed under an open
      // edit sheet — wrong for a Close that failed because the board vanished.
      setNotice({ title: 'Close failed', body: 'Close failed — please try again.' });
    }
  };

  const handleReopen = async (): Promise<void> => {
    setBusy(true);
    try {
      await reopenBoard(board.id);
      setAction(null);
      setBusy(false);
      onExitEdit();
    } catch (err) {
      console.error('BoardOptionsSection: reopen failed', err);
      setBusy(false);
      setAction(null);
      setNotice({ title: 'Reopen failed', body: 'Reopen failed — please try again.' });
    }
  };

  const handleArchive = async (): Promise<void> => {
    setBusy(true);
    try {
      await archiveBoard(board.id);
      setAction(null);
      onExitEdit();
      onRemoved();
    } catch (err) {
      console.error('BoardOptionsSection: archive failed', err);
      setBusy(false);
      setAction(null);
      setNotice({ title: 'Archive failed', body: 'Archive failed — please try again.' });
    }
  };

  const handleDelete = async (): Promise<void> => {
    setBusy(true);
    try {
      await deleteBoard(board.id);
      setAction(null);
      onExitEdit();
      onRemoved();
    } catch (err) {
      console.error('BoardOptionsSection: delete failed', err);
      setBusy(false);
      setAction(null);
      setNotice({ title: 'Delete failed', body: 'Delete failed — please try again.' });
    }
  };

  const archiveBody = `It moves to Archived. Your streak and history are kept — restore it anytime.${
    squaresDirty ? DISCARD_SQUARES_SUFFIX : ''
  }`;
  const deleteBody = `"${board.name}" will be removed. This can't be undone from the app.${
    squaresDirty ? DISCARD_SQUARES_SUFFIX : ''
  }`;

  return (
    <>
      {/* One wrapping element (not a bare Fragment) so a flex-`gap` ancestor
          (BoardEditColumn's column stack) only puts space BEFORE this whole
          section, never between the label and its card. */}
      <div className={styles.section}>
        <RisoSectionLabel>BOARD</RisoSectionLabel>
        <RisoCard role="group" aria-label="Board options" className={styles.card}>
          {menuItems.map((item) => (
            <button
              key={item.kind}
              type="button"
              className={`${styles.row} ${item.danger ? styles.danger : ''}`}
              onClick={() => handleSelect(item.kind)}
            >
              <RisoIcon name={item.icon} size={18} />
              {item.label}
            </button>
          ))}
        </RisoCard>
      </div>

      {/* Portaled to `document.body`: every sheet/dialog here is a
          `position: fixed` full-viewport backdrop, which a sticky/relative
          ancestor's local stacking context would trap behind a later DOM
          sibling — see the CSS stacking-context note this section carries
          forward from its `BoardTitleActions` predecessor. */}
      {(action != null || notice != null) &&
        createPortal(
          <>
            {action === 'details' && (
              <BoardDetailsSheet
                board={board}
                weekStartDay={weekStartDay}
                onClose={() => setAction(null)}
                onBoardClosed={handleBoardClosed}
                onSaved={() => {
                  setAction(null);
                  onDetailsSaved();
                }}
              />
            )}

            {action === 'repeat' && (
              <BoardRepeatSheet
                board={board}
                sourceTemplate={sourceTemplate}
                userId={userId}
                weekStartDay={weekStartDay}
                taskMap={taskMap}
                dealtTaskIds={dealtTaskIds}
                counterFamilyByTaskId={counterFamilyByTaskId}
                onClose={() => setAction(null)}
                onBoardClosed={handleBoardClosed}
                onSaved={() => {
                  setAction(null);
                  onDetailsSaved();
                }}
              />
            )}

            {action === 'coreDefaults' && userId && (
              <CoreDefaultsSheetHost
                userId={userId}
                timeframe={board.timeframe as Timeframe}
                onClose={() => setAction(null)}
                onSaved={() => setAction(null)}
              />
            )}

            {action === 'confirmArchive' && (
              <BoardActionConfirmDialog
                title="Archive this board?"
                body={archiveBody}
                confirmLabel="Archive"
                busy={busy}
                onCancel={() => setAction(null)}
                onConfirm={() => void handleArchive()}
              />
            )}

            {action === 'confirmDelete' && (
              <BoardActionConfirmDialog
                title="Delete board?"
                body={deleteBody}
                confirmLabel="Delete"
                destructive
                busy={busy}
                onCancel={() => setAction(null)}
                onConfirm={() => void handleDelete()}
              />
            )}

            {action === 'confirmReopen' && (
              <BoardActionConfirmDialog
                title="Reopen this board?"
                body="It accepts logs again until you close it. Streaks and achievements that watch it will recompute."
                confirmLabel="Reopen"
                busy={busy}
                onCancel={() => setAction(null)}
                onConfirm={() => void handleReopen()}
              />
            )}

            {action === 'confirmDiscard' && (
              <BoardActionConfirmDialog
                title="Discard changes?"
                body="Your unsaved changes will be lost."
                cancelLabel="Keep editing"
                confirmLabel="Discard"
                onCancel={() => {
                  setDiscardTarget(null);
                  setAction(null);
                }}
                onConfirm={handleDiscardConfirmed}
              />
            )}

            {notice != null && (
              <BoardActionConfirmDialog
                title={notice.title}
                body={notice.body}
                cancelLabel={null}
                confirmLabel="OK"
                onCancel={() => setNotice(null)}
                onConfirm={() => setNotice(null)}
              />
            )}
          </>,
          document.body,
        )}
    </>
  );
}
