import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  STREAK_TIMEFRAMES,
  compactStreakLabel,
  computeBoardMomentReplay,
  type Board,
  type BoardTask,
  type CellState,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import type { SquareWindowContext } from '../../db/adapters';
import type { FlashOutcome } from '../boardPlayFlash';
import { ShareBoardSheet } from '../share/ShareBoardSheet';
import { RisoMomentOverlay } from './RisoMomentOverlay';
import { buildMomentCellModels, isMomentReady, type MomentTrigger } from './boardMomentUi';

/** How long to wait for the live data to catch up with the write before opening anyway. */
const READY_TIMEOUT_MS = 1500;

export interface UseBoardMomentParams {
  board: Board;
  boardTasks: BoardTask[];
  taskMap: Record<string, Task>;
  compoundChildrenByCompound: Record<string, CompoundChild[]>;
  allBoards: Board[];
  cellStateByBoardTaskId: Record<string, CellState>;
  btByPosition: Record<string, BoardTask>;
  squareWindowContext: SquareWindowContext;
  gridSize: number;
  /** Timeframe greenlog streak (0 while unready). */
  greenlogStreak: number;
}

export interface UseBoardMomentResult {
  /** Open the moment for a `bingo` / `greenlog` flash outcome. */
  open: (outcome: FlashOutcome) => void;
  /** The moment overlay + its share sheet, or `null` while closed. */
  node: React.ReactElement | null;
}

/**
 * Owns the Bingo / Greenlog moment for a play surface: opens it from a flash
 * outcome once the live data reflects the write, builds the replay + end-state
 * cells from the play data, and hosts the share sheet over it.
 */
export function useBoardMoment(p: UseBoardMomentParams): UseBoardMomentResult {
  const navigate = useNavigate();
  const [trigger, setTrigger] = useState<MomentTrigger | null>(null);
  const [forced, setForced] = useState(false);
  const [shareOpen, setShareOpen] = useState(false);

  const open = useCallback((outcome: FlashOutcome): void => {
    if (outcome.kind === 'message') return;
    setForced(false);
    setTrigger({ kind: outcome.kind, newLineIds: outcome.newLineIds });
  }, []);

  const replay = useMemo(
    () => trigger
      ? computeBoardMomentReplay(
        p.board, p.boardTasks, p.compoundChildrenByCompound, p.taskMap, p.squareWindowContext.eventsByTaskId, p.allBoards,
      )
      : null,
    [trigger, p.board, p.boardTasks, p.compoundChildrenByCompound, p.taskMap, p.squareWindowContext, p.allBoards],
  );

  useEffect(() => {
    if (!trigger) return undefined;
    const t = setTimeout(() => setForced(true), READY_TIMEOUT_MS);
    return () => clearTimeout(t);
  }, [trigger]);

  // Latch: once the data has caught up the moment stays open, even if a later
  // data refresh would momentarily read as "not ready".
  const ready = trigger !== null && replay !== null && isMomentReady(replay, trigger);
  useEffect(() => {
    if (ready) setForced(true);
  }, [ready]);
  const shown = trigger !== null && replay !== null && forced;
  const cells = useMemo(
    () => shown && replay
      ? buildMomentCellModels({
        gridSize: p.gridSize, freeIdx: replay.freeIdx, btByPosition: p.btByPosition, taskMap: p.taskMap,
        compoundChildrenByCompound: p.compoundChildrenByCompound, squareWindowContext: p.squareWindowContext,
        cellStateByBoardTaskId: p.cellStateByBoardTaskId,
      })
      : [],
    [shown, replay, p.gridSize, p.btByPosition, p.taskMap, p.compoundChildrenByCompound, p.squareWindowContext, p.cellStateByBoardTaskId],
  );

  if (!trigger || !replay || !shown) return { open, node: null };

  const lineCount = Object.keys(replay.lineClosureBeat).length;
  const shareStreak = p.greenlogStreak > 0 && (STREAK_TIMEFRAMES as readonly string[]).includes(p.board.timeframe)
    ? compactStreakLabel(p.greenlogStreak, p.board.timeframe)
    : undefined;

  const node = (
    <>
      <RisoMomentOverlay
        kind={trigger.kind}
        replay={replay}
        cells={cells}
        boardName={p.board.name}
        linesCompleted={lineCount}
        streak={p.greenlogStreak}
        timeframe={p.board.timeframe}
        onShare={() => setShareOpen(true)}
        onBack={() => { setShareOpen(false); setTrigger(null); }}
        onNewBoard={() => navigate('/create')}
      />
      {shareOpen && (
        <ShareBoardSheet
          boardName={p.board.name}
          completedTasks={p.board.completedTasks}
          totalTasks={p.board.totalTasks}
          linesCompleted={lineCount}
          streak={shareStreak}
          onDismiss={() => setShareOpen(false)}
        />
      )}
    </>
  );
  return { open, node };
}
