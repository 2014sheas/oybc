import { useState } from 'react';
import { createPortal } from 'react-dom';
import {
  BoardStatus,
  Timeframe,
  type Board,
  type RecurringBoardTemplate,
  type Task,
  type WeekStartDay,
} from '@oybc/shared';
import { RisoButton, RisoIcon } from '../riso';
import { archiveBoard, deleteBoard } from '../../db/operations/boards';
import { buildBoardMenuItems, type BoardMenuItemKind } from './boardMenu';
import { BoardActionsMenu } from './BoardActionsMenu';
import { BoardDetailsSheet } from './BoardDetailsSheet';
import { BoardRepeatSheet } from './BoardRepeatSheet';
import { CoreDefaultsSheetHost } from './CoreDefaultsSheetHost';
import { BoardActionConfirmDialog } from './BoardActionConfirmDialog';
import { BOARD_CLOSED_MESSAGE } from './boardDetailsPatch';
import play from '../play/Play.module.css';

/** Which sheet/dialog is currently presented from the menu. */
type BoardAction = 'details' | 'repeat' | 'coreDefaults' | 'confirmArchive' | 'confirmDelete' | null;

/** A one-button notice shown after a sheet / confirm closes (iOS `.alert` + OK). */
interface BoardActionNotice {
  title: string;
  body: string;
}

/** D11 — a board sealed / deleted while a menu sheet was open. iOS twin:
 *  `BoardActionsPresenter`'s "Board closed" alert. */
const BOARD_CLOSED_NOTICE: BoardActionNotice = { title: 'Board closed', body: BOARD_CLOSED_MESSAGE };

export interface BoardTitleActionsProps {
  board: Board;
  userId: string | undefined;
  sourceTemplate: RecurringBoardTemplate | null | undefined;
  templatesLoaded: boolean;
  weekStartDay: WeekStartDay;
  taskMap: Record<string, Task>;
  dealtTaskIds: string[];
  counterFamilyByTaskId: Record<string, string>;
  /** Enter squares-edit mode (the `Edit squares` button). */
  onEditSquares: () => void;
  /** Fired after a successful Board-details save (the caller shows the toast). */
  onDetailsSaved: () => void;
  /** Fired after a successful Archive / Delete. */
  onRemoved: () => void;
}

/**
 * BoardTitleActions — the title-row trailing cluster (Board Edit redesign
 * slice 2, plan D1/T4): `Edit squares` (or the sealed "Read-only" lock) +
 * the "…" board menu, plus every sheet/dialog the menu opens. Extracted
 * from `BoardPlaySurface` so new UI lands in a new file (D13 — the surface
 * must shrink, not grow).
 */
export function BoardTitleActions({
  board,
  userId,
  sourceTemplate,
  templatesLoaded,
  weekStartDay,
  taskMap,
  dealtTaskIds,
  counterFamilyByTaskId,
  onEditSquares,
  onDetailsSaved,
  onRemoved,
}: BoardTitleActionsProps): React.ReactElement {
  const [action, setAction] = useState<BoardAction>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<BoardActionNotice | null>(null);

  /** A menu sheet's save hit a closed board: swap the sheet for the notice. */
  const handleBoardClosed = (): void => {
    setAction(null);
    setNotice(BOARD_CLOSED_NOTICE);
  };

  const isSealed = board.sealedAt != null;
  const menuItems = buildBoardMenuItems({ board, sourceTemplate, templatesLoaded });

  const handleSelect = (kind: BoardMenuItemKind): void => {
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
    }
  };

  const handleArchive = async (): Promise<void> => {
    setBusy(true);
    try {
      await archiveBoard(board.id);
      setAction(null);
      onRemoved();
    } catch (err) {
      console.error('BoardTitleActions: archive failed', err);
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
      onRemoved();
    } catch (err) {
      console.error('BoardTitleActions: delete failed', err);
      setBusy(false);
      setAction(null);
      setNotice({ title: 'Delete failed', body: 'Delete failed — please try again.' });
    }
  };

  return (
    <>
      <span className={play.railRight}>
        {board.status === BoardStatus.ACTIVE && !isSealed && (
          <RisoButton
            kind="neutral"
            size="small"
            icon={<RisoIcon name="edit" size={16} />}
            onClick={onEditSquares}
            aria-label="Edit squares"
            title="Edit squares"
          >
            Edit squares
          </RisoButton>
        )}
        {isSealed && (
          <span className={play.readOnly}>
            <RisoIcon name="lock" size={12} />
            Read-only
          </span>
        )}
        <BoardActionsMenu items={menuItems} boardName={board.name} onSelect={handleSelect} />
      </span>

      {/* Portaled to `document.body`: every sheet/dialog here is a
          `position: fixed` full-viewport backdrop, but this component
          renders inside `.rail` (`position: sticky`), which — per the
          CSS stacking rules for sticky-positioned ancestors — traps ANY
          fixed-position descendant inside its own local stacking context.
          Without the portal, the backdrop paints BEHIND the board grid
          (`.boardWrap`, a later DOM sibling of `.rail`) at any viewport
          width where the two visually overlap (every width ≤ 1080px,
          where the two-column rail+grid layout collapses to one column —
          caught by Playwright, not by eye on a wide desktop window). */}
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
                body="It moves to Archived. Your streak and history are kept — restore it anytime."
                confirmLabel="Archive"
                busy={busy}
                onCancel={() => setAction(null)}
                onConfirm={() => void handleArchive()}
              />
            )}

            {action === 'confirmDelete' && (
              <BoardActionConfirmDialog
                title="Delete board?"
                body={`"${board.name}" will be removed. This can't be undone from the app.`}
                confirmLabel="Delete"
                destructive
                busy={busy}
                onCancel={() => setAction(null)}
                onConfirm={() => void handleDelete()}
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
