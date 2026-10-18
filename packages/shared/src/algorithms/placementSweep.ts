import { detectBingos, type BoardSize } from '@oybc/bingo-core';
import { TaskType } from '../constants/enums';
import type { Board } from '../types/board';
import type { BoardTask } from '../types/boardTask';
import type { CompoundChild } from '../types/compoundChild';
import type { Task } from '../types/task';
import type { TaskEvent } from '../types/taskEvent';
import type { CountKind } from './countValue';
import { isWholeCountKind, quantizeCount, resolveCountKind } from './countValue';
import { computeBoardGrid } from './derivationPass';
import { derivedCompoundId, derivedTaskId, isWindowStampedDerived } from './memberRules';
import type { PlacementChildTarget } from '../types/boardTask';
import { boundWindowContextAtSeal, type WindowEvaluationContext } from './taskEvents';
import { isAutoCounterTitle } from './taskTitle';

/**
 * placementSweep.ts — the migration sweep (docs/TASK_WINDOW_REWORK.md
 * §Migration sweep; slice 4a: derived COUNTERS, slice 4b: derived COMPOUNDS).
 *
 * A state-based, deterministic, equivalence-gated plan: every live placement
 * that still points at a legacy window-stamped derived counter is repointed
 * at the row's ROOT with the row's frozen target as `targetOverride` (and a
 * custom title as `titleOverride`) — but ONLY when the kernel, run over the
 * same event union before and after the repoint, agrees on every cell's
 * completion, the completed count and the bingo lines (bounded at `sealedAt`
 * for a sealed board). A board the gate refuses gets a terminal outcome in
 * the same run: its marked rows have their window marks stripped and stay as
 * plain linked tasks, which the kernel reads over the host window.
 *
 * The sweep never tombstones a row another board may still place: an
 * orphan is a marked row with no live placement and no live parent link
 * BEFORE this run's repoints — a row this run repoints away from retires on
 * the NEXT run, after the pull has converged every device's placements.
 *
 * Pure: no clock beyond `now`, no rng, every tie broken by id. The platform
 * appliers (web `db/operations/placementSweep.ts` ↔ iOS
 * `AppDatabase+PlacementSweep.swift`) write the plan as authored rows and
 * re-derive the touched boards. Swift twin: `Helpers/PlacementSweep.swift`,
 * pinned by `placementSweepVectors.json`.
 */

/** The rows the planner reads — any superset; deleted rows are filtered here. */
export interface SweepWorkspace {
  tasks: readonly Task[];
  boards: readonly Board[];
  boardTasks: readonly BoardTask[];
  compoundChildren: readonly CompoundChild[];
  /** Task events (deleted rows are filtered here). */
  events: readonly TaskEvent[];
}

/** One placement repoint: the row `boardTaskId` now points at `toTaskId` with these parameters. */
export interface SweepRepoint {
  boardId: string;
  boardTaskId: string;
  fromTaskId: string;
  toTaskId: string;
  targetOverride?: number;
  targetKind?: CountKind;
  /** Slice 4b — a derived compound's forward-mapped per-child targets, keyed by the SOURCE child id. */
  childTargets?: PlacementChildTarget[];
  titleOverride?: string;
  /** The board is sealed — the applier takes the named `repointSealedPlacement` path. */
  sealed: boolean;
}

export type SweepBoardOutcomeKind = 'repointed' | 'refused';

/** Why a board was refused; `null` when it was repointed. */
export type SweepRefusalReason = 'rootMissing' | 'duplicateRoot' | 'derivationChanged' | 'compoundMismatch';

export interface SweepBoardOutcome {
  boardId: string;
  outcome: SweepBoardOutcomeKind;
  reason: SweepRefusalReason | null;
  /** A sealed board whose stored snapshot already differs from the kernel's re-derivation (reported, never blocking). */
  sealedSnapshotDrift: boolean;
}

export interface PlacementSweepPlan {
  repoints: SweepRepoint[];
  /** Marked rows whose window marks are stripped (`timeframe` / `startDate` / `endDate` cleared). */
  strips: string[];
  /** Marked rows with no live placement and no live parent link anywhere — tombstoned (authored). */
  orphanTombstones: string[];
  /** derived row id → root id, for re-keying stored rules ({@link rekeyIds} & co.). */
  rekey: Record<string, string>;
  /** Boards with at least one repoint — the applier re-derives them. */
  touchedBoardIds: string[];
  outcomes: SweepBoardOutcome[];
}

const EMPTY_PLAN: PlacementSweepPlan = {
  repoints: [],
  strips: [],
  orphanTombstones: [],
  rekey: {},
  touchedBoardIds: [],
  outcomes: [],
};

function byId<T extends { id: string }>(a: T, b: T): number {
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

function byPosition(a: BoardTask, b: BoardTask): number {
  return a.row - b.row || a.col - b.col || byId(a, b);
}

/** What the gate compares: cell completion, the completed count and the bingo lines. */
function derivationSignature(
  board: Board,
  placements: BoardTask[],
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
  allBoards: Board[],
  ctx: WindowEvaluationContext,
): { grid: boolean[]; completedTasks: number; lines: string[] } {
  const { grid, completedTasks } = computeBoardGrid(board, placements, childrenByCompound, taskById, allBoards, ctx);
  const lines = [...detectBingos(grid, board.boardSize as BoardSize).completedLines].sort();
  return { grid, completedTasks, lines };
}

function sameSignature(
  a: { grid: boolean[]; completedTasks: number; lines: string[] },
  b: { grid: boolean[]; completedTasks: number; lines: string[] },
): boolean {
  if (a.completedTasks !== b.completedTasks || a.grid.length !== b.grid.length) return false;
  for (let i = 0; i < a.grid.length; i++) if (a.grid[i] !== b.grid[i]) return false;
  if (a.lines.length !== b.lines.length) return false;
  for (let i = 0; i < a.lines.length; i++) if (a.lines[i] !== b.lines[i]) return false;
  return true;
}

/**
 * The repoint a legacy derived counter's placement gets: its root, the row's
 * frozen goal as the override (an existing `targetOverride` on the placement
 * — a slice-3a edit — wins), the row's kind, and a custom title carried over.
 */
function repointFor(bt: BoardTask, row: Task, root: Task, sealed: boolean): SweepRepoint {
  const kind = resolveCountKind(row);
  const custom = !isAutoCounterTitle(row.title, row.action ?? '', row.maxCount, row.unit ?? '', kind, root);
  const out: SweepRepoint = { boardId: bt.boardId, boardTaskId: bt.id, fromTaskId: row.id, toTaskId: root.id, sealed };
  const target = bt.targetOverride ?? row.maxCount;
  if (typeof target === 'number' && target > 0) {
    out.targetOverride = target;
    out.targetKind = bt.targetOverride != null && bt.targetKind ? bt.targetKind : kind;
  }
  const title = bt.titleOverride?.trim() || (custom ? row.title.trim() : '');
  if (title) out.titleOverride = title;
  return out;
}

/** The placement row as the repoint would write it. */
function applyRepoint(bt: BoardTask, r: SweepRepoint): BoardTask {
  const next: BoardTask = { ...bt, taskId: r.toTaskId };
  delete next.targetOverride;
  delete next.targetKind;
  delete next.titleOverride;
  delete next.childTargets;
  if (r.targetOverride !== undefined) {
    next.targetOverride = r.targetOverride;
    next.targetKind = r.targetKind;
  }
  if (r.childTargets !== undefined) next.childTargets = r.childTargets;
  if (r.titleOverride !== undefined) next.titleOverride = r.titleOverride;
  return next;
}

/**
 * A legacy per-window derived COMPOUND (B2): a compound carrying a window
 * stamp and the wizard provenance mark. The web / iOS `isWindowStampedDerivedCompound`
 * twins read the same two marks.
 */
export function isWindowStampedDerivedCompound(
  t: Pick<Task, 'type' | 'startDate' | 'createdInWizard'>,
): boolean {
  return t.type === TaskType.COMPOUND && !!t.startDate && t.createdInWizard === true;
}

/** A counting task's own goal in its kind (whole kinds floor, `≥ 1`; continuous quantizes), or `null`. */
function ownGoalOf(t: Pick<Task, 'maxCount' | 'countKind'>): number | null {
  if (typeof t.maxCount !== 'number') return null;
  if (isWholeCountKind(resolveCountKind(t))) return t.maxCount >= 1 ? Math.floor(t.maxCount) : null;
  return t.maxCount > 0 ? quantizeCount(t.maxCount) : null;
}

interface CompoundMatch {
  source: Task;
  childTargets: PlacementChildTarget[];
  /** derived child id → its root, for the rule re-key map. */
  childRekey: Record<string, string>;
}

/**
 * Slice 4b — find a derived compound's SOURCE by forward uuidv5 match and
 * map its children forward (docs §Migration sweep step 3). Candidates are
 * live, un-marked compounds with the same operator and threshold; the mint
 * board is tried as the placing board first, then every board by id
 * (deleted ones included — the id is all the match needs). The source's
 * live children map forward: a counting child `c` whose
 * `derivedTaskId(mint, c.sharedCounterId ?? c.id)` is a live child of the
 * derived compound maps to that derived part (collapsed siblings allowed),
 * any other child maps to itself. The forward-mapped set must equal the
 * derived compound's live child set; a derived part's frozen goal becomes a
 * `childTargets` entry keyed by the SOURCE child id when it differs from the
 * child's own goal (an existing entry on the placement keyed by the source
 * child wins; one keyed by the derived child is re-keyed).
 *
 * @returns The match, or `null` (the board is refused with `compoundMismatch`).
 */
function matchDerivedCompound(
  derived: Task,
  placingBoardId: string,
  bt: BoardTask,
  liveTasks: readonly Task[],
  taskById: Record<string, Task>,
  allBoardIds: readonly string[],
  childrenByCompound: Record<string, CompoundChild[]>,
): CompoundMatch | null {
  const derivedKids = (childrenByCompound[derived.id] ?? []).map((k) => k.childTaskId);
  const derivedKidSet = new Set(derivedKids);
  const sources = liveTasks
    .filter(
      (t) =>
        t.type === TaskType.COMPOUND &&
        !isWindowStampedDerivedCompound(t) &&
        (t.operator ?? null) === (derived.operator ?? null) &&
        (t.threshold ?? null) === (derived.threshold ?? null),
    )
    .sort(byId);
  const mintBoards = [placingBoardId, ...allBoardIds.filter((id) => id !== placingBoardId)];
  for (const mint of mintBoards) {
    for (const source of sources) {
      if (derivedCompoundId(mint, source.id) !== derived.id) continue;
      const sourceKids = [...(childrenByCompound[source.id] ?? [])].sort(
        (a, b) => a.childIndex - b.childIndex || (a.childTaskId < b.childTaskId ? -1 : a.childTaskId > b.childTaskId ? 1 : 0),
      );
      const mapped = new Set<string>();
      const childTargets: PlacementChildTarget[] = [];
      const childRekey: Record<string, string> = {};
      let ok = sourceKids.length > 0;
      for (const k of sourceKids) {
        const c = taskById[k.childTaskId];
        if (!c || c.isDeleted) {
          ok = false;
          break;
        }
        let target: string = c.id;
        if (c.type === TaskType.COUNTING) {
          const root = c.sharedCounterId ?? c.id;
          const part = derivedTaskId(mint, root);
          const partRow = taskById[part];
          if (derivedKidSet.has(part) && partRow && !partRow.isDeleted) {
            target = part;
            childRekey[part] = root;
            const existing =
              bt.childTargets?.find((e) => e.childId === c.id) ?? bt.childTargets?.find((e) => e.childId === part);
            const goal = existing?.target ?? partRow.maxCount;
            if (typeof goal === 'number' && goal > 0 && goal !== ownGoalOf(c) && !childTargets.some((e) => e.childId === c.id)) {
              childTargets.push({ childId: c.id, target: goal });
            }
          }
        }
        mapped.add(target);
      }
      if (!ok) continue;
      if (mapped.size !== derivedKidSet.size || [...mapped].some((id) => !derivedKidSet.has(id))) continue;
      return { source, childTargets, childRekey };
    }
  }
  return null;
}

/**
 * Plan the sweep over a workspace (slice 4a — derived counters).
 *
 * @param ws  The workspace rows (any superset; deleted rows filtered here).
 * @param now ISO8601 — reserved for the applier's stamps; the plan itself is clock-free.
 * @returns The plan; {@link EMPTY_PLAN}-shaped when no marked row exists.
 */
export function planPlacementSweep(ws: SweepWorkspace, now: string): PlacementSweepPlan {
  void now;
  const liveTasks = ws.tasks.filter((t) => !t.isDeleted);
  const marked = liveTasks.filter(
    (t) => (t.type === TaskType.COUNTING && isWindowStampedDerived(t)) || isWindowStampedDerivedCompound(t),
  );
  if (marked.length === 0) return { ...EMPTY_PLAN, rekey: {} };

  const taskById: Record<string, Task> = {};
  for (const t of ws.tasks) taskById[t.id] = t;
  const markedById = new Map(marked.map((t) => [t.id, t]));
  const allBoards = ws.boards.filter((b) => !b.isDeleted);
  const boardById = new Map(allBoards.map((b) => [b.id, b]));
  const allBoardIds = [...ws.boards].map((b) => b.id).sort();
  const livePlacements = ws.boardTasks.filter((bt) => !bt.isDeleted && boardById.has(bt.boardId));
  const liveLinks = ws.compoundChildren.filter((c) => !c.isDeleted);
  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of liveLinks) (childrenByCompound[c.compoundTaskId] ??= []).push(c);
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of ws.events) {
    if (e.isDeleted) continue;
    (eventsByTaskId[e.taskId] ??= []).push(e);
  }

  // Boards holding at least one live placement of a marked row, by id.
  const placementsByBoard = new Map<string, BoardTask[]>();
  for (const bt of livePlacements) (placementsByBoard.get(bt.boardId) ?? placementsByBoard.set(bt.boardId, []).get(bt.boardId)!).push(bt);
  const candidateBoardIds = [...placementsByBoard.entries()]
    .filter(([, bts]) => bts.some((bt) => markedById.has(bt.taskId)))
    .map(([id]) => id)
    .sort();

  const repoints: SweepRepoint[] = [];
  const strips = new Set<string>();
  const rekey: Record<string, string> = {};
  const touched: string[] = [];
  const outcomes: SweepBoardOutcome[] = [];

  for (const boardId of candidateBoardIds) {
    const board = boardById.get(boardId)!;
    const sealed = board.sealedAt != null;
    const placements = [...placementsByBoard.get(boardId)!].sort(byPosition);
    const markedHere = placements.filter((bt) => markedById.has(bt.taskId));
    const refuse = (reason: SweepRefusalReason, drift: boolean): void => {
      for (const bt of markedHere) strips.add(bt.taskId);
      outcomes.push({ boardId, outcome: 'refused', reason, sealedSnapshotDrift: drift });
    };

    // Window context: a sealed board's events are bounded at `sealedAt`
    // (an unparseable `sealedAt` applies no bound, as in the re-derive).
    const sealedAtMs = sealed ? new Date(board.sealedAt as string).getTime() : NaN;
    const ctx: WindowEvaluationContext = Number.isNaN(sealedAtMs)
      ? { eventsByTaskId }
      : boundWindowContextAtSeal(eventsByTaskId, sealedAtMs);

    const before = derivationSignature(board, placements, childrenByCompound, taskById, allBoards, ctx);
    const drift = sealed ? !sameGridAsSnapshot(before.grid, board.sealedCompletedCells) : false;

    // Build the proposed placements; refuse on a missing root or a duplicate.
    const proposed: BoardTask[] = [];
    const boardRepoints: SweepRepoint[] = [];
    const childRekeys: Record<string, string> = {};
    const placedTaskIds = new Set(placements.filter((bt) => !markedById.has(bt.taskId)).map((bt) => bt.taskId));
    let reason: SweepRefusalReason | null = null;
    for (const bt of placements) {
      const row = markedById.get(bt.taskId);
      if (!row) {
        proposed.push(bt);
        continue;
      }
      if (row.type === TaskType.COMPOUND) {
        // Slice 4b — a derived compound → its source with forward-mapped child targets.
        const match = matchDerivedCompound(row, boardId, bt, liveTasks, taskById, allBoardIds, childrenByCompound);
        if (!match) {
          reason = 'compoundMismatch';
          break;
        }
        if (placedTaskIds.has(match.source.id)) {
          reason = 'duplicateRoot';
          break;
        }
        placedTaskIds.add(match.source.id);
        const r: SweepRepoint = { boardId, boardTaskId: bt.id, fromTaskId: row.id, toTaskId: match.source.id, sealed };
        if (match.childTargets.length > 0) r.childTargets = match.childTargets;
        const title = bt.titleOverride?.trim() || (row.title.trim() !== match.source.title.trim() ? row.title.trim() : '');
        if (title) r.titleOverride = title;
        for (const [part, root] of Object.entries(match.childRekey)) childRekeys[part] = root;
        boardRepoints.push(r);
        proposed.push(applyRepoint(bt, r));
        continue;
      }
      const root = row.sharedCounterId ? taskById[row.sharedCounterId] : undefined;
      if (!root || root.isDeleted) {
        reason = 'rootMissing';
        break;
      }
      if (placedTaskIds.has(root.id)) {
        reason = 'duplicateRoot';
        break;
      }
      placedTaskIds.add(root.id);
      const r = repointFor(bt, row, root, sealed);
      boardRepoints.push(r);
      proposed.push(applyRepoint(bt, r));
    }
    if (reason !== null) {
      refuse(reason, drift);
      continue;
    }

    const after = derivationSignature(board, proposed, childrenByCompound, taskById, allBoards, ctx);
    if (!sameSignature(before, after)) {
      refuse('derivationChanged', drift);
      continue;
    }
    repoints.push(...boardRepoints);
    for (const r of boardRepoints) rekey[r.fromTaskId] = r.toTaskId;
    // A derived compound's derived parts re-key to their roots too (rules keyed by part ids).
    for (const [part, root] of Object.entries(childRekeys)) rekey[part] = root;
    touched.push(boardId);
    outcomes.push({ boardId, outcome: 'repointed', reason: null, sealedSnapshotDrift: drift });
  }

  // A row repointed on one board and refused on another is NOT stripped: the
  // refused board keeps pointing at it as a plain linked row only if nothing
  // repoints it; otherwise the next run (after the repoint) decides.
  for (const r of repoints) strips.delete(r.fromTaskId);

  // Orphans: marked rows that had no live placement and no live parent link
  // before this run (a row this run repoints away from retires next run).
  const placedBefore = new Set(livePlacements.map((bt) => bt.taskId));
  const childOfLive = new Set(liveLinks.filter((c) => taskById[c.compoundTaskId] && !taskById[c.compoundTaskId].isDeleted).map((c) => c.childTaskId));
  const orphanTombstones = marked
    .filter((t) => !placedBefore.has(t.id) && !childOfLive.has(t.id))
    .map((t) => t.id)
    .sort();

  return {
    repoints,
    strips: [...strips].sort(),
    orphanTombstones,
    rekey,
    touchedBoardIds: touched,
    outcomes,
  };
}

/** `sealedCompletedCells` holds the completed cell indexes; compare with the grid. */
function sameGridAsSnapshot(grid: boolean[], sealedCompletedCells: number[] | undefined): boolean {
  const snap = new Set(sealedCompletedCells ?? []);
  for (let i = 0; i < grid.length; i++) if (grid[i] !== snap.has(i)) return false;
  return true;
}

// ── Rule re-keying ───────────────────────────────────────────────────────────

/**
 * Re-key an id list through `map` (derived id → root id): order preserved,
 * duplicates collapsed (first wins). Returns the SAME array when nothing
 * changes, so callers can test identity for "dirty".
 */
export function rekeyIds(ids: readonly string[], map: Record<string, string>): readonly string[] {
  if (!ids.some((id) => id in map)) return ids;
  const out: string[] = [];
  const seen = new Set<string>();
  for (const id of ids) {
    const next = map[id] ?? id;
    if (seen.has(next)) continue;
    seen.add(next);
    out.push(next);
  }
  return out;
}

/**
 * Re-key a record's keys through `map`: keys are visited in ascending order
 * and the FIRST key that lands on a target wins (a later collapse is dropped),
 * so two devices re-key identically. Returns the SAME object when nothing
 * changes.
 */
export function rekeyRecordKeys<V>(record: Record<string, V>, map: Record<string, string>): Record<string, V> {
  const keys = Object.keys(record);
  if (!keys.some((k) => k in map)) return record;
  const out: Record<string, V> = {};
  for (const k of [...keys].sort()) {
    const next = map[k] ?? k;
    if (next in out) continue;
    out[next] = record[k];
  }
  return out;
}
