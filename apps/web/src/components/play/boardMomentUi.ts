import {
  resolveFamilyCountKind,
  type BoardMomentReplay,
  type BoardTask,
  type CellState,
  type CompoundChild,
  type MomentCellVisual,
  type MomentKind,
  type Task,
} from '@oybc/shared';
import { taskToSquareState, type SquareWindowContext } from '../../db/adapters';
import { freeCellModel, toBoardCellModel } from '../board/cellModel';
import type { BoardCellModel } from '../board/RisoBoardCell';

/** What opened a moment: its kind and the lines the write newly completed. */
export interface MomentTrigger {
  kind: MomentKind;
  newLineIds: string[];
}

/**
 * Whether the live data has caught up with the write that opened the moment.
 * The flash fires the instant the write resolves, but the reactive grid and the
 * board row land a render later; opening on stale data would replay a board
 * missing its last square. A bingo is ready once every new line closes in the
 * replay, a greenlog once every cell has landed; either way the rail's counter
 * must cover the ordered cells.
 */
export function isMomentReady(replay: BoardMomentReplay, trigger: MomentTrigger): boolean {
  const accounted = replay.order.length + (replay.freeIdx !== null ? 1 : 0);
  if (replay.completedTasks < accounted) return false;
  if (trigger.kind === 'greenlog') return accounted === replay.size * replay.size;
  return trigger.newLineIds.every((id) => id in replay.lineClosureBeat);
}

/** Everything {@link buildMomentCellModels} reads from the play data. */
export interface MomentCellSource {
  gridSize: number;
  freeIdx: number | null;
  btByPosition: Record<string, BoardTask>;
  taskMap: Record<string, Task>;
  compoundChildrenByCompound: Record<string, CompoundChild[]>;
  squareWindowContext: SquareWindowContext;
  cellStateByBoardTaskId: Record<string, CellState>;
}

/**
 * The END-STATE cell models, row-major, one per grid cell: the same
 * resolution the play grid draws (kernel cell state, windowed counts) without
 * its interaction chrome.
 */
export function buildMomentCellModels(src: MomentCellSource): BoardCellModel[] {
  const cells: BoardCellModel[] = [];
  for (let idx = 0; idx < src.gridSize * src.gridSize; idx++) {
    const row = Math.floor(idx / src.gridSize);
    const col = idx % src.gridSize;
    if (idx === src.freeIdx) {
      cells.push(freeCellModel(`free-${idx}`));
      continue;
    }
    const bt = src.btByPosition[`${row}-${col}`];
    const task = bt ? src.taskMap[bt.taskId] : undefined;
    if (!bt || !task) {
      cells.push({ key: `empty-${idx}`, label: '', type: 'normal', done: false, isFree: false, isLine: false });
      continue;
    }
    const state = taskToSquareState(
      task, src.compoundChildrenByCompound[task.id] ?? [], src.taskMap,
      src.compoundChildrenByCompound, src.squareWindowContext, src.cellStateByBoardTaskId[bt.id],
    );
    cells.push(toBoardCellModel({
      key: bt.id,
      task,
      done: state.isCompleted,
      currentCount: state.currentCount,
      countKind: resolveFamilyCountKind(task, (id) => src.taskMap[id]),
    }));
  }
  return cells;
}

/**
 * One cell as the moment draws it at a beat: a landed square wears its done
 * chrome in its type colour (green once a closed line / the wave reaches it),
 * a square still to land is undone with an empty counting bar, a square that
 * never completes stays as the board shows it, and the FREE centre is ink until
 * it turns green. The play grid's ring, shared marker and edit chips never show.
 */
export function momentDisplayCell(
  model: BoardCellModel,
  visual: MomentCellVisual,
  willLand: boolean,
): BoardCellModel {
  const plain: BoardCellModel = {
    ...model, isLine: false, isShared: undefined, isArrived: undefined, locked: undefined, dirty: undefined,
  };
  if (model.isFree) return { ...plain, lineGreen: visual.green };
  if (visual.landed) return { ...plain, done: true, lineGreen: visual.green };
  return {
    ...plain,
    done: false,
    count: willLand && model.count ? { ...model.count, cur: 0 } : model.count,
  };
}

/** The pop phase a cell plays at this frame: it just landed, just turned green, or is settled. */
export function momentPopPhase(visual: MomentCellVisual, animate: boolean): 'land' | 'green' | null {
  if (!animate) return null;
  if (visual.green) return 'green';
  return visual.landed ? 'land' : null;
}

/** Where the moment is in its life: nothing, waiting out the open delay, or showing. */
export type MomentPhase = 'idle' | 'pending' | 'open';

/**
 * What a new trigger does. Nothing is pending or open: schedule it. While a
 * bingo is still pending (not yet shown) a greenlog REPLACES it - the board
 * cleared inside the delay - but a bingo never replaces anything, and nothing
 * interrupts a moment that is already open.
 */
export function momentOpenDecision(
  phase: MomentPhase,
  pendingKind: MomentTrigger['kind'] | null,
  incoming: MomentTrigger['kind'],
): 'schedule' | 'ignore' {
  if (phase === 'idle') return 'schedule';
  if (phase === 'pending' && pendingKind === 'bingo' && incoming === 'greenlog') return 'schedule';
  return 'ignore';
}

/** The replay + end-state cells a moment draws from, frozen when it opens. */
export interface MomentSnapshot {
  replay: BoardMomentReplay;
  cells: BoardCellModel[];
}

/**
 * The snapshot to hold: an existing one is kept as is (a data refresh mid-replay
 * never changes it); otherwise the live one is taken once the board shows the
 * outcome (`ready`) or the wait ran out (`forced`).
 */
export function nextMomentSnapshot(
  current: MomentSnapshot | null,
  live: MomentSnapshot | null,
  ready: boolean,
  forced: boolean,
): MomentSnapshot | null {
  if (current) return current;
  return live && (ready || forced) ? live : null;
}
