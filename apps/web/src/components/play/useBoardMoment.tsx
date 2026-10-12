import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
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
import { buildMomentCellModels, isMomentReady, momentOpenDecision, nextMomentSnapshot, type MomentPhase, type MomentSnapshot, type MomentTrigger } from './boardMomentUi';

/** Delay before the moment opens, so the cell pop finishes first (iOS uses the same 0.52 s for both kinds). */
const OPEN_DELAY_MS = 520;

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
  const [snapshot, setSnapshot] = useState<MomentSnapshot | null>(null);

  const phaseRef = useRef<MomentPhase>('idle');
  const pendingKindRef = useRef<MomentTrigger['kind'] | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => { if (timerRef.current) clearTimeout(timerRef.current); }, []);

  // A new trigger replaces a pending bingo only when it is a greenlog; it is
  // ignored while a moment is open.
  const open = useCallback((outcome: FlashOutcome): void => {
    if (outcome.kind === 'message') return;
    const kind = outcome.kind;
    if (momentOpenDecision(phaseRef.current, pendingKindRef.current, kind) === 'ignore') return;
    if (timerRef.current) clearTimeout(timerRef.current);
    phaseRef.current = 'pending';
    pendingKindRef.current = kind;
    timerRef.current = setTimeout(() => {
      phaseRef.current = 'open';
      setForced(false);
      setSnapshot(null);
      setTrigger({ kind, newLineIds: outcome.newLineIds });
    }, OPEN_DELAY_MS);
  }, []);

  // While pending, the replay + end-state cells track the live data (the ready
  // gate waits for the write to show). Once opened they are FROZEN: a sync
  // landing mid-replay must not mutate the frames.
  const live = useMemo<MomentSnapshot | null>(() => {
    if (!trigger || snapshot) return null;
    const replay = computeBoardMomentReplay(
      p.board, p.boardTasks, p.compoundChildrenByCompound, p.taskMap, p.squareWindowContext.eventsByTaskId, p.allBoards,
    );
    const cells = buildMomentCellModels({
      gridSize: p.gridSize, freeIdx: replay.freeIdx, btByPosition: p.btByPosition, taskMap: p.taskMap,
      compoundChildrenByCompound: p.compoundChildrenByCompound, squareWindowContext: p.squareWindowContext,
      cellStateByBoardTaskId: p.cellStateByBoardTaskId,
    });
    return { replay, cells };
  }, [trigger, snapshot, p.board, p.boardTasks, p.compoundChildrenByCompound, p.taskMap, p.squareWindowContext,
    p.allBoards, p.gridSize, p.btByPosition, p.cellStateByBoardTaskId]);

  useEffect(() => {
    if (!trigger) return undefined;
    const t = setTimeout(() => setForced(true), READY_TIMEOUT_MS);
    return () => clearTimeout(t);
  }, [trigger]);

  const ready = trigger !== null && live !== null && isMomentReady(live.replay, trigger);
  useEffect(() => {
    const next = nextMomentSnapshot(snapshot, live, ready, forced);
    if (next !== snapshot) setSnapshot(next);
  }, [snapshot, live, ready, forced]);

  if (!trigger || !snapshot) return { open, node: null };
  const { replay, cells } = snapshot;

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
        onBack={() => { setShareOpen(false); setTrigger(null); setSnapshot(null); setForced(false); phaseRef.current = 'idle'; }}
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
  return { open, node: createPortal(node, document.body) };
}
