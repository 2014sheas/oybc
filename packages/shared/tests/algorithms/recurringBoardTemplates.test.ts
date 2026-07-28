import {
  findTemplatesPendingSpawn,
  validateSpawnPool,
  buildSpawnPlacement,
  deriveSpawnedBoardName,
} from '../../src/algorithms/recurringBoardTemplates';
import { getTimeframeBoundaries } from '../../src/algorithms/calendarBoundaries';
import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
  TaskType,
} from '../../src/constants/enums';
import type { Board } from '../../src/types/board';
import type { Task } from '../../src/types/task';
import type { RecurringBoardTemplate } from '../../src/types/recurringBoardTemplate';

// ─── Fixtures ─────────────────────────────────────────────────────────────────

function buildTemplate(overrides: Partial<RecurringBoardTemplate> = {}): RecurringBoardTemplate {
  return {
    id: 'template-1',
    userId: 'u1',
    name: 'Daily Workout',
    timeframe: Timeframe.DAILY,
    boardSize: 5,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: false,
    seedTaskIds: Array.from({ length: 24 }, (_, i) => `task-${i}`),
    lastSpawnedWindowKey: null,
    isActive: true,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function buildTask(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'u1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function buildPool(template: RecurringBoardTemplate): Task[] {
  return template.seedTaskIds.map((id) => buildTask(id));
}

function buildBoard(overrides: Partial<Board> = {}): Board {
  return {
    id: 'board-1',
    userId: 'u1',
    name: 'Some board',
    status: BoardStatus.ACTIVE,
    boardSize: 5,
    timeframe: Timeframe.DAILY,
    startDate: '2026-05-07T00:00:00.000',
    endDate: '2026-05-07T23:59:59.999',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    totalTasks: 25,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: '2026-05-07T00:00:00.000Z',
    updatedAt: '2026-05-07T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

/** Deterministic "RNG" that returns 0 each call → fisher-yates collapses to
 *  reverse-then-front-load behavior. Sufficient for asserting "shuffled with
 *  this RNG yields THIS order". */
function constantRng(value: number): () => number {
  return () => value;
}

const NOW = new Date('2026-05-07T15:00:00');
const WEEK_START_DAY = 'monday' as const;

// ─── findTemplatesPendingSpawn ────────────────────────────────────────────────

describe('findTemplatesPendingSpawn', () => {
  it('emits a pending spawn for a fresh template (lastSpawnedWindowKey=null)', () => {
    const tpl = buildTemplate();
    const result = findTemplatesPendingSpawn([tpl], [], WEEK_START_DAY, NOW);
    expect(result).toHaveLength(1);
    const { startDate, endDate } = getTimeframeBoundaries(
      Timeframe.DAILY,
      NOW,
      WEEK_START_DAY,
    );
    expect(result[0].windowStart).toBe(startDate);
    expect(result[0].windowEnd).toBe(endDate);
    expect(result[0].template).toBe(tpl);
  });

  it('skips a template whose lastSpawnedWindowKey matches the current window', () => {
    const { startDate } = getTimeframeBoundaries(Timeframe.DAILY, NOW, WEEK_START_DAY);
    const tpl = buildTemplate({ lastSpawnedWindowKey: startDate });
    expect(findTemplatesPendingSpawn([tpl], [], WEEK_START_DAY, NOW)).toEqual([]);
  });

  it('emits a pending spawn when lastSpawnedWindowKey is for a previous window', () => {
    const tpl = buildTemplate({ lastSpawnedWindowKey: '2026-05-06T00:00:00.000' });
    const result = findTemplatesPendingSpawn([tpl], [], WEEK_START_DAY, NOW);
    expect(result).toHaveLength(1);
  });

  it('skips inactive templates', () => {
    expect(
      findTemplatesPendingSpawn([buildTemplate({ isActive: false })], [], WEEK_START_DAY, NOW),
    ).toEqual([]);
  });

  it('skips soft-deleted templates', () => {
    expect(
      findTemplatesPendingSpawn([buildTemplate({ isDeleted: true })], [], WEEK_START_DAY, NOW),
    ).toEqual([]);
  });

  it('skips Timeframe.CUSTOM templates (forward-compat against malformed data)', () => {
    expect(
      findTemplatesPendingSpawn(
        [buildTemplate({ timeframe: Timeframe.CUSTOM })],
        [],
        WEEK_START_DAY,
        NOW,
      ),
    ).toEqual([]);
  });

  it('uses the idempotency belt: existing board with matching provenance + startDate skips', () => {
    const tpl = buildTemplate({ lastSpawnedWindowKey: null });
    const { startDate } = getTimeframeBoundaries(Timeframe.DAILY, NOW, WEEK_START_DAY);
    const board = buildBoard({
      spawnedFromTemplateId: tpl.id,
      startDate,
    });
    expect(findTemplatesPendingSpawn([tpl], [board], WEEK_START_DAY, NOW)).toEqual([]);
  });

  it('idempotency belt ignores soft-deleted boards (so they do not block re-spawn)', () => {
    const tpl = buildTemplate({ lastSpawnedWindowKey: null });
    const { startDate } = getTimeframeBoundaries(Timeframe.DAILY, NOW, WEEK_START_DAY);
    const board = buildBoard({
      spawnedFromTemplateId: tpl.id,
      startDate,
      isDeleted: true,
    });
    expect(findTemplatesPendingSpawn([tpl], [board], WEEK_START_DAY, NOW)).toHaveLength(1);
  });

  it('idempotency belt ignores boards from a different template', () => {
    const tpl = buildTemplate({ id: 'template-1', lastSpawnedWindowKey: null });
    const { startDate } = getTimeframeBoundaries(Timeframe.DAILY, NOW, WEEK_START_DAY);
    const otherBoard = buildBoard({
      spawnedFromTemplateId: 'template-OTHER',
      startDate,
    });
    expect(findTemplatesPendingSpawn([tpl], [otherBoard], WEEK_START_DAY, NOW)).toHaveLength(1);
  });

  it('preserves the input order of templates in the output', () => {
    const tplA = buildTemplate({ id: 'A', name: 'Alpha' });
    const tplB = buildTemplate({ id: 'B', name: 'Beta' });
    const result = findTemplatesPendingSpawn([tplA, tplB], [], WEEK_START_DAY, NOW);
    expect(result.map((p) => p.template.id)).toEqual(['A', 'B']);
  });
});

// ─── deriveSpawnedBoardName ───────────────────────────────────────────────────

describe('deriveSpawnedBoardName', () => {
  it('joins template name + window label with an em-dash', () => {
    const { startDate } = getTimeframeBoundaries(Timeframe.MONTHLY, NOW, WEEK_START_DAY);
    const tpl = buildTemplate({ timeframe: Timeframe.MONTHLY, name: 'Reading Goals' });
    const name = deriveSpawnedBoardName(tpl, startDate);
    expect(name).toMatch(/^Reading Goals\s—\s.+/);
  });

  it('falls back to the window label when template name is empty/whitespace', () => {
    const { startDate } = getTimeframeBoundaries(Timeframe.MONTHLY, NOW, WEEK_START_DAY);
    const tpl = buildTemplate({ timeframe: Timeframe.MONTHLY, name: '  ' });
    const name = deriveSpawnedBoardName(tpl, startDate);
    expect(name).not.toContain('—');
    expect(name.length).toBeGreaterThan(0);
  });
});

// ─── validateSpawnPool ────────────────────────────────────────────────────────

describe('validateSpawnPool', () => {
  it('exact-fit pool (24 tasks, 5x5 with FREE center) → ok', () => {
    const tpl = buildTemplate({
      seedTaskIds: Array.from({ length: 24 }, (_, i) => `t${i}`),
    });
    expect(validateSpawnPool(tpl, buildPool(tpl))).toEqual({ ok: true });
  });

  it('undersized pool → pool_too_small', () => {
    const tpl = buildTemplate({
      seedTaskIds: Array.from({ length: 23 }, (_, i) => `t${i}`),
    });
    expect(validateSpawnPool(tpl, buildPool(tpl))).toEqual({
      ok: false,
      reason: 'pool_too_small',
    });
  });

  it('oversized pool → ok (extras become the random subset; the whole point of loose-fit)', () => {
    const tpl = buildTemplate({
      seedTaskIds: Array.from({ length: 50 }, (_, i) => `t${i}`),
    });
    expect(validateSpawnPool(tpl, buildPool(tpl))).toEqual({ ok: true });
  });

  it('soft-deleted task in the pool → has_deleted_tasks', () => {
    const tpl = buildTemplate({
      boardSize: 3,
      seedTaskIds: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j'],
    });
    const pool = tpl.seedTaskIds.map((id) =>
      id === 'c' ? buildTask(id, { isDeleted: true }) : buildTask(id),
    );
    expect(validateSpawnPool(tpl, pool)).toEqual({
      ok: false,
      reason: 'has_deleted_tasks',
    });
  });

  it('duplicate task ids in the resolved pool → pool_too_small (defense for malformed remote payload)', () => {
    // Even if a peer somehow lands a template with duplicate seedTaskIds
    // (the create-input schema rejects them, but assume), the resolved
    // pool would have <unique-count> items at <total-count> positions —
    // buildSpawnPlacement would place the same Task on multiple cells.
    // validateSpawnPool short-circuits to pool_too_small (semantically
    // closer to the actionable user story than a separate reason).
    const tpl = buildTemplate({
      seedTaskIds: ['a', 'a', 'b', 'c'],
      boardSize: 3,
    });
    // Resolve to four Tasks where two reference the same id ('a')
    const pool: Task[] = [
      buildTask('a'),
      buildTask('a'),
      buildTask('b'),
      buildTask('c'),
    ];
    expect(validateSpawnPool(tpl, pool)).toEqual({
      ok: false,
      reason: 'pool_too_small',
    });
  });

  it('has_deleted_tasks takes precedence over pool_too_small (catch-soft-delete-first ordering)', () => {
    // 3 tasks total on a 3x3 (8 fillable cells) — pool is too small AND
    // has a deleted task. The validator should surface the deleted-task
    // reason because it's the more actionable failure (user can resurrect
    // the task / replace the seed); a pure size mismatch is a harder fix.
    const tpl = buildTemplate({
      boardSize: 3,
      seedTaskIds: ['a', 'b', 'c'],
    });
    const pool = tpl.seedTaskIds.map((id) =>
      id === 'b' ? buildTask(id, { isDeleted: true }) : buildTask(id),
    );
    expect(validateSpawnPool(tpl, pool)).toEqual({
      ok: false,
      reason: 'has_deleted_tasks',
    });
  });

  it('Timeframe.CUSTOM → unsupported_timeframe', () => {
    const tpl = buildTemplate({ timeframe: Timeframe.CUSTOM });
    expect(validateSpawnPool(tpl, buildPool(tpl))).toEqual({
      ok: false,
      reason: 'unsupported_timeframe',
    });
  });

  it('CenterSquareType.CHOSEN → unsupported_center (MVP excludes it)', () => {
    const tpl = buildTemplate({ centerSquareType: CenterSquareType.CHOSEN });
    expect(validateSpawnPool(tpl, buildPool(tpl))).toEqual({
      ok: false,
      reason: 'unsupported_center',
    });
  });

  it('NONE center on 5x5 → fillable count is 25 (no free space exclusion)', () => {
    const tpl = buildTemplate({
      centerSquareType: CenterSquareType.NONE,
      seedTaskIds: Array.from({ length: 25 }, (_, i) => `t${i}`),
    });
    expect(validateSpawnPool(tpl, buildPool(tpl))).toEqual({ ok: true });
  });

  it('CUSTOM_FREE center on 5x5 → fillable count is 24 (same as FREE)', () => {
    const tpl = buildTemplate({
      centerSquareType: CenterSquareType.CUSTOM_FREE,
      centerSquareCustomName: 'Win!',
      seedTaskIds: Array.from({ length: 24 }, (_, i) => `t${i}`),
    });
    expect(validateSpawnPool(tpl, buildPool(tpl))).toEqual({ ok: true });
  });

  it('4x4 even board has no center → fillable count is 16 regardless of centerSquareType', () => {
    const tpl = buildTemplate({
      boardSize: 4,
      centerSquareType: CenterSquareType.FREE,
      seedTaskIds: Array.from({ length: 16 }, (_, i) => `t${i}`),
    });
    expect(validateSpawnPool(tpl, buildPool(tpl))).toEqual({ ok: true });
  });
});

// ─── buildSpawnPlacement ──────────────────────────────────────────────────────

describe('buildSpawnPlacement', () => {
  it('non-randomized exact-fit: order preserved, FREE center is null', () => {
    const tpl = buildTemplate({
      isRandomized: false,
      seedTaskIds: Array.from({ length: 24 }, (_, i) => `t${i}`),
    });
    const placement = buildSpawnPlacement({ template: tpl, poolTasks: buildPool(tpl) });
    expect(placement).toHaveLength(25);
    expect(placement[12]).toBeNull(); // 5x5 center index = 12
    expect(placement[0]?.id).toBe('t0');
    expect(placement[11]?.id).toBe('t11');
    expect(placement[13]?.id).toBe('t12'); // skipped center
  });

  it('randomized + injected RNG: deterministic shuffle', () => {
    const tpl = buildTemplate({
      isRandomized: true,
      seedTaskIds: Array.from({ length: 24 }, (_, i) => `t${i}`),
    });
    const a = buildSpawnPlacement({
      template: tpl,
      poolTasks: buildPool(tpl),
      rng: constantRng(0),
    });
    const b = buildSpawnPlacement({
      template: tpl,
      poolTasks: buildPool(tpl),
      rng: constantRng(0),
    });
    expect(a.map((t) => t?.id ?? '_')).toEqual(b.map((t) => t?.id ?? '_'));
  });

  it('oversized pool slices to fillable cell count (extras dropped)', () => {
    const tpl = buildTemplate({
      isRandomized: true,
      seedTaskIds: Array.from({ length: 50 }, (_, i) => `t${i}`),
    });
    const placement = buildSpawnPlacement({
      template: tpl,
      poolTasks: buildPool(tpl),
      rng: constantRng(0.5),
    });
    expect(placement).toHaveLength(25);
    expect(placement[12]).toBeNull();
    const placedIds = placement.flatMap((t) => (t ? [t.id] : []));
    expect(placedIds).toHaveLength(24);
    expect(new Set(placedIds).size).toBe(24);
  });

  it('NONE center on 5x5: center cell receives a regular task', () => {
    const tpl = buildTemplate({
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      seedTaskIds: Array.from({ length: 25 }, (_, i) => `t${i}`),
    });
    const placement = buildSpawnPlacement({ template: tpl, poolTasks: buildPool(tpl) });
    expect(placement[12]?.id).toBe('t12');
  });

  it('4x4 even board: no center exclusion, all 16 cells filled', () => {
    const tpl = buildTemplate({
      boardSize: 4,
      isRandomized: false,
      seedTaskIds: Array.from({ length: 16 }, (_, i) => `t${i}`),
    });
    const placement = buildSpawnPlacement({ template: tpl, poolTasks: buildPool(tpl) });
    expect(placement).toHaveLength(16);
    expect(placement.every((t) => t !== null)).toBe(true);
  });

  it('CUSTOM_FREE center: cell 12 is null (same shape as FREE)', () => {
    const tpl = buildTemplate({
      centerSquareType: CenterSquareType.CUSTOM_FREE,
      centerSquareCustomName: 'My center',
      isRandomized: false,
      seedTaskIds: Array.from({ length: 24 }, (_, i) => `t${i}`),
    });
    const placement = buildSpawnPlacement({ template: tpl, poolTasks: buildPool(tpl) });
    expect(placement[12]).toBeNull();
  });
});

// ─── Multi-window spawn simulation ───────────────────────────────────────────
//
// Walks the spawn-update-respawn loop across multiple windows for both daily
// and weekly templates. The platform spawn driver wraps Board insert + template
// `lastSpawnedWindowKey` update + sync queue items in one transaction; we
// simulate that here by manually appending the spawned Board and updating the
// template after each "spawn", then re-invoking `findTemplatesPendingSpawn`.
// This exercises BOTH suppression checks (lastSpawnedWindowKey match AND the
// idempotency belt over existing boards), not just the algorithm in isolation.

describe('multi-window spawn simulation', () => {
  /// Helper — apply the same writes the platform spawn driver makes inside
  /// its txn (insert spawned board + advance template's lastSpawnedWindowKey).
  /// Returns the new board + template snapshot for the next iteration.
  function simulateSpawn(
    template: RecurringBoardTemplate,
    windowStart: string,
    windowEnd: string,
    boardSeq: number,
  ): { board: Board; template: RecurringBoardTemplate } {
    const board = buildBoard({
      id: `board-spawn-${boardSeq}`,
      timeframe: template.timeframe,
      startDate: windowStart,
      endDate: windowEnd,
      spawnedFromTemplateId: template.id,
    });
    const advanced: RecurringBoardTemplate = {
      ...template,
      lastSpawnedWindowKey: windowStart,
    };
    return { board, template: advanced };
  }

  it('daily template: pending → spawn → quiet same day → pending again next day', () => {
    let tpl = buildTemplate({ timeframe: Timeframe.DAILY });
    const day1 = new Date(2026, 4, 7, 9, 0, 0); // Thu May 7, 2026
    const day1Window = getTimeframeBoundaries(Timeframe.DAILY, day1, 'monday');

    // Initial: nothing spawned, nothing in board list → pending.
    const before = findTemplatesPendingSpawn([tpl], [], 'monday', day1);
    expect(before).toHaveLength(1);
    expect(before[0].windowStart).toBe(day1Window.startDate);

    // Simulate the spawn — append board + advance lastSpawnedWindowKey.
    const spawn1 = simulateSpawn(tpl, day1Window.startDate, day1Window.endDate, 1);
    tpl = spawn1.template;
    const boards: Board[] = [spawn1.board];

    // Same day, after spawn: both suppressors fire. The lastSpawnedWindowKey
    // alone would block; the idempotency belt is the secondary safety net.
    expect(findTemplatesPendingSpawn([tpl], boards, 'monday', day1)).toHaveLength(0);

    // Next day → new window → pending again.
    const day2 = new Date(2026, 4, 8, 9, 0, 0); // Fri May 8, 2026
    const day2Window = getTimeframeBoundaries(Timeframe.DAILY, day2, 'monday');
    expect(day2Window.startDate).not.toBe(day1Window.startDate);

    const day2Pending = findTemplatesPendingSpawn([tpl], boards, 'monday', day2);
    expect(day2Pending).toHaveLength(1);
    expect(day2Pending[0].windowStart).toBe(day2Window.startDate);

    // Spawn day 2 → both day-1 and day-2 boards in list, both suppressors
    // pin to the day-2 window so a third re-check doesn't double-spawn.
    const spawn2 = simulateSpawn(tpl, day2Window.startDate, day2Window.endDate, 2);
    tpl = spawn2.template;
    boards.push(spawn2.board);
    expect(findTemplatesPendingSpawn([tpl], boards, 'monday', day2)).toHaveLength(0);
  });

  it('weekly template: pending → spawn → quiet within week → pending again next week', () => {
    let tpl = buildTemplate({
      timeframe: Timeframe.WEEKLY,
      seedTaskIds: Array.from({ length: 24 }, (_, i) => `wk-${i}`),
    });
    // Wed in week of May 4-10, 2026 (Mon-Sun start).
    const wk1Mid = new Date(2026, 4, 6, 9, 0, 0);
    const wk1Window = getTimeframeBoundaries(Timeframe.WEEKLY, wk1Mid, 'monday');

    expect(findTemplatesPendingSpawn([tpl], [], 'monday', wk1Mid)).toHaveLength(1);
    const spawn1 = simulateSpawn(tpl, wk1Window.startDate, wk1Window.endDate, 1);
    tpl = spawn1.template;
    const boards: Board[] = [spawn1.board];

    // Mid-week and end-of-week, after spawn → still suppressed.
    expect(findTemplatesPendingSpawn([tpl], boards, 'monday', wk1Mid)).toHaveLength(0);
    const wk1End = new Date(2026, 4, 10, 22, 0, 0); // Sun May 10
    expect(findTemplatesPendingSpawn([tpl], boards, 'monday', wk1End)).toHaveLength(0);

    // Cross into the next week (Mon May 11) → new weekly window → pending.
    const wk2Start = new Date(2026, 4, 11, 9, 0, 0);
    const wk2Window = getTimeframeBoundaries(Timeframe.WEEKLY, wk2Start, 'monday');
    expect(wk2Window.startDate).not.toBe(wk1Window.startDate);

    const wk2Pending = findTemplatesPendingSpawn([tpl], boards, 'monday', wk2Start);
    expect(wk2Pending).toHaveLength(1);
    expect(wk2Pending[0].windowStart).toBe(wk2Window.startDate);
  });

  it('idempotency belt alone (without lastSpawnedWindowKey advance) still suppresses re-spawn', () => {
    // Belt-and-braces check: if a transaction races so the board insert
    // commits but the template's lastSpawnedWindowKey advance gets lost
    // (e.g., a future bug regresses the txn boundary), the belt over the
    // existing board list still prevents a duplicate same-window spawn.
    const tpl = buildTemplate({ timeframe: Timeframe.DAILY }); // lastSpawnedWindowKey=null
    const day = new Date(2026, 4, 7, 9, 0, 0);
    const win = getTimeframeBoundaries(Timeframe.DAILY, day, 'monday');
    const board = buildBoard({
      id: 'board-belt',
      timeframe: Timeframe.DAILY,
      startDate: win.startDate,
      endDate: win.endDate,
      spawnedFromTemplateId: tpl.id,
    });

    // Template still says "never spawned" but a matching board exists →
    // belt suppresses. Without the belt, the user would see a duplicate
    // spawn for that window on next Boards-tab open.
    expect(findTemplatesPendingSpawn([tpl], [board], 'monday', day)).toHaveLength(0);
  });
});

// ─── Golden-parity matrix: buildSpawnPlacement ───────────────────────────────
//
// PLAY_TRANSITION.md T2. Byte-for-byte golden of `buildSpawnPlacement` across
// {3×3, 4×4, 5×5} × {FREE, CUSTOM_FREE, CHOSEN, NONE} × {randomized, not} ×
// {exact-fit, overfilled pool}, driven by the shared seeded LCG below. These
// expected arrays were committed against the OLD hand-rolled loop first
// (baseline), then must stay byte-identical after buildSpawnPlacement is
// refactored to delegate to bingo-core`s `placeBoard`. The Swift twin
// (BoardPlacementTests.swift) ports the SAME LCG + SAME expected arrays — that
// lockstep is the cross-platform placement proof.

/** Deterministic uniform [0,1) LCG (Numerical Recipes constants). Identical to
 *  packages/bingo-core/tests/seededRng.ts and the Swift port in
 *  OYBCTests/BoardPlacementTests.swift. */
function makeSeededRng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 4294967296;
  };
}

const SPAWN_GOLDEN_SEED = 2026;

interface SpawnGoldenCase {
  size: number;
  center: CenterSquareType;
  randomize: boolean;
  fit: string;
  poolCount: number;
  expected: (string | null)[];
}

const SPAWN_GOLDENS: SpawnGoldenCase[] = [
  { size: 3, center: CenterSquareType.FREE, randomize: false, fit: "exact", poolCount: 8,
    expected: ["t0", "t1", "t2", "t3", null, "t4", "t5", "t6", "t7"] },
  { size: 3, center: CenterSquareType.FREE, randomize: false, fit: "over", poolCount: 14,
    expected: ["t0", "t1", "t2", "t3", null, "t4", "t5", "t6", "t7"] },
  { size: 3, center: CenterSquareType.FREE, randomize: true, fit: "exact", poolCount: 8,
    expected: ["t5", "t4", "t1", "t2", null, "t3", "t6", "t7", "t0"] },
  { size: 3, center: CenterSquareType.FREE, randomize: true, fit: "over", poolCount: 14,
    expected: ["t2", "t1", "t3", "t9", null, "t10", "t11", "t5", "t8"] },
  { size: 3, center: CenterSquareType.CUSTOM_FREE, randomize: false, fit: "exact", poolCount: 8,
    expected: ["t0", "t1", "t2", "t3", null, "t4", "t5", "t6", "t7"] },
  { size: 3, center: CenterSquareType.CUSTOM_FREE, randomize: false, fit: "over", poolCount: 14,
    expected: ["t0", "t1", "t2", "t3", null, "t4", "t5", "t6", "t7"] },
  { size: 3, center: CenterSquareType.CUSTOM_FREE, randomize: true, fit: "exact", poolCount: 8,
    expected: ["t5", "t4", "t1", "t2", null, "t3", "t6", "t7", "t0"] },
  { size: 3, center: CenterSquareType.CUSTOM_FREE, randomize: true, fit: "over", poolCount: 14,
    expected: ["t2", "t1", "t3", "t9", null, "t10", "t11", "t5", "t8"] },
  { size: 3, center: CenterSquareType.CHOSEN, randomize: false, fit: "exact", poolCount: 9,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"] },
  { size: 3, center: CenterSquareType.CHOSEN, randomize: false, fit: "over", poolCount: 15,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"] },
  { size: 3, center: CenterSquareType.CHOSEN, randomize: true, fit: "exact", poolCount: 9,
    expected: ["t6", "t2", "t4", "t1", "t5", "t3", "t7", "t8", "t0"] },
  { size: 3, center: CenterSquareType.CHOSEN, randomize: true, fit: "over", poolCount: 15,
    expected: ["t10", "t3", "t2", "t9", "t12", "t8", "t1", "t6", "t5"] },
  { size: 3, center: CenterSquareType.NONE, randomize: false, fit: "exact", poolCount: 9,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"] },
  { size: 3, center: CenterSquareType.NONE, randomize: false, fit: "over", poolCount: 15,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"] },
  { size: 3, center: CenterSquareType.NONE, randomize: true, fit: "exact", poolCount: 9,
    expected: ["t6", "t2", "t4", "t1", "t5", "t3", "t7", "t8", "t0"] },
  { size: 3, center: CenterSquareType.NONE, randomize: true, fit: "over", poolCount: 15,
    expected: ["t10", "t3", "t2", "t9", "t12", "t8", "t1", "t6", "t5"] },
  { size: 4, center: CenterSquareType.FREE, randomize: false, fit: "exact", poolCount: 16,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"] },
  { size: 4, center: CenterSquareType.FREE, randomize: false, fit: "over", poolCount: 22,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"] },
  { size: 4, center: CenterSquareType.FREE, randomize: true, fit: "exact", poolCount: 16,
    expected: ["t3", "t11", "t4", "t2", "t10", "t13", "t12", "t1", "t9", "t6", "t5", "t7", "t8", "t14", "t15", "t0"] },
  { size: 4, center: CenterSquareType.FREE, randomize: true, fit: "over", poolCount: 22,
    expected: ["t16", "t3", "t15", "t10", "t14", "t6", "t5", "t4", "t13", "t7", "t1", "t19", "t18", "t2", "t17", "t9"] },
  { size: 4, center: CenterSquareType.CUSTOM_FREE, randomize: false, fit: "exact", poolCount: 16,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"] },
  { size: 4, center: CenterSquareType.CUSTOM_FREE, randomize: false, fit: "over", poolCount: 22,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"] },
  { size: 4, center: CenterSquareType.CUSTOM_FREE, randomize: true, fit: "exact", poolCount: 16,
    expected: ["t3", "t11", "t4", "t2", "t10", "t13", "t12", "t1", "t9", "t6", "t5", "t7", "t8", "t14", "t15", "t0"] },
  { size: 4, center: CenterSquareType.CUSTOM_FREE, randomize: true, fit: "over", poolCount: 22,
    expected: ["t16", "t3", "t15", "t10", "t14", "t6", "t5", "t4", "t13", "t7", "t1", "t19", "t18", "t2", "t17", "t9"] },
  { size: 4, center: CenterSquareType.CHOSEN, randomize: false, fit: "exact", poolCount: 16,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"] },
  { size: 4, center: CenterSquareType.CHOSEN, randomize: false, fit: "over", poolCount: 22,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"] },
  { size: 4, center: CenterSquareType.CHOSEN, randomize: true, fit: "exact", poolCount: 16,
    expected: ["t3", "t11", "t4", "t2", "t10", "t13", "t12", "t1", "t9", "t6", "t5", "t7", "t8", "t14", "t15", "t0"] },
  { size: 4, center: CenterSquareType.CHOSEN, randomize: true, fit: "over", poolCount: 22,
    expected: ["t16", "t3", "t15", "t10", "t14", "t6", "t5", "t4", "t13", "t7", "t1", "t19", "t18", "t2", "t17", "t9"] },
  { size: 4, center: CenterSquareType.NONE, randomize: false, fit: "exact", poolCount: 16,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"] },
  { size: 4, center: CenterSquareType.NONE, randomize: false, fit: "over", poolCount: 22,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15"] },
  { size: 4, center: CenterSquareType.NONE, randomize: true, fit: "exact", poolCount: 16,
    expected: ["t3", "t11", "t4", "t2", "t10", "t13", "t12", "t1", "t9", "t6", "t5", "t7", "t8", "t14", "t15", "t0"] },
  { size: 4, center: CenterSquareType.NONE, randomize: true, fit: "over", poolCount: 22,
    expected: ["t16", "t3", "t15", "t10", "t14", "t6", "t5", "t4", "t13", "t7", "t1", "t19", "t18", "t2", "t17", "t9"] },
  { size: 5, center: CenterSquareType.FREE, randomize: false, fit: "exact", poolCount: 24,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", null, "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23"] },
  { size: 5, center: CenterSquareType.FREE, randomize: false, fit: "over", poolCount: 30,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", null, "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23"] },
  { size: 5, center: CenterSquareType.FREE, randomize: true, fit: "exact", poolCount: 24,
    expected: ["t4", "t6", "t3", "t10", "t18", "t22", "t16", "t17", "t7", "t5", "t19", "t8", null, "t15", "t21", "t14", "t2", "t20", "t11", "t9", "t12", "t13", "t23", "t1", "t0"] },
  { size: 5, center: CenterSquareType.FREE, randomize: true, fit: "over", poolCount: 30,
    expected: ["t25", "t15", "t8", "t19", "t23", "t5", "t11", "t10", "t7", "t6", "t2", "t18", null, "t27", "t22", "t24", "t9", "t4", "t13", "t21", "t29", "t20", "t3", "t26", "t14"] },
  { size: 5, center: CenterSquareType.CUSTOM_FREE, randomize: false, fit: "exact", poolCount: 24,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", null, "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23"] },
  { size: 5, center: CenterSquareType.CUSTOM_FREE, randomize: false, fit: "over", poolCount: 30,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", null, "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23"] },
  { size: 5, center: CenterSquareType.CUSTOM_FREE, randomize: true, fit: "exact", poolCount: 24,
    expected: ["t4", "t6", "t3", "t10", "t18", "t22", "t16", "t17", "t7", "t5", "t19", "t8", null, "t15", "t21", "t14", "t2", "t20", "t11", "t9", "t12", "t13", "t23", "t1", "t0"] },
  { size: 5, center: CenterSquareType.CUSTOM_FREE, randomize: true, fit: "over", poolCount: 30,
    expected: ["t25", "t15", "t8", "t19", "t23", "t5", "t11", "t10", "t7", "t6", "t2", "t18", null, "t27", "t22", "t24", "t9", "t4", "t13", "t21", "t29", "t20", "t3", "t26", "t14"] },
  { size: 5, center: CenterSquareType.CHOSEN, randomize: false, fit: "exact", poolCount: 25,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23", "t24"] },
  { size: 5, center: CenterSquareType.CHOSEN, randomize: false, fit: "over", poolCount: 31,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23", "t24"] },
  { size: 5, center: CenterSquareType.CHOSEN, randomize: true, fit: "exact", poolCount: 25,
    expected: ["t10", "t5", "t7", "t4", "t18", "t23", "t17", "t21", "t12", "t8", "t6", "t3", "t19", "t16", "t22", "t15", "t2", "t20", "t11", "t9", "t13", "t14", "t24", "t1", "t0"] },
  { size: 5, center: CenterSquareType.CHOSEN, randomize: true, fit: "over", poolCount: 31,
    expected: ["t11", "t16", "t20", "t5", "t24", "t9", "t6", "t25", "t2", "t8", "t7", "t19", "t26", "t28", "t14", "t23", "t10", "t4", "t13", "t22", "t30", "t21", "t3", "t27", "t15"] },
  { size: 5, center: CenterSquareType.NONE, randomize: false, fit: "exact", poolCount: 25,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23", "t24"] },
  { size: 5, center: CenterSquareType.NONE, randomize: false, fit: "over", poolCount: 31,
    expected: ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15", "t16", "t17", "t18", "t19", "t20", "t21", "t22", "t23", "t24"] },
  { size: 5, center: CenterSquareType.NONE, randomize: true, fit: "exact", poolCount: 25,
    expected: ["t10", "t5", "t7", "t4", "t18", "t23", "t17", "t21", "t12", "t8", "t6", "t3", "t19", "t16", "t22", "t15", "t2", "t20", "t11", "t9", "t13", "t14", "t24", "t1", "t0"] },
  { size: 5, center: CenterSquareType.NONE, randomize: true, fit: "over", poolCount: 31,
    expected: ["t11", "t16", "t20", "t5", "t24", "t9", "t6", "t25", "t2", "t8", "t7", "t19", "t26", "t28", "t14", "t23", "t10", "t4", "t13", "t22", "t30", "t21", "t3", "t27", "t15"] },
];

describe("buildSpawnPlacement golden-parity matrix (seed " + String(SPAWN_GOLDEN_SEED) + ")", () => {
  it.each(SPAWN_GOLDENS)(
    "$size×$size $center randomize=$randomize $fit-fit (pool $poolCount) matches golden",
    ({ size, center, randomize, poolCount, expected }) => {
      const tpl = buildTemplate({
        boardSize: size as 3 | 4 | 5,
        centerSquareType: center,
        isRandomized: randomize,
        seedTaskIds: Array.from({ length: poolCount }, (_, i) => `t${i}`),
      });
      const placement = buildSpawnPlacement({
        template: tpl,
        poolTasks: buildPool(tpl),
        rng: makeSeededRng(SPAWN_GOLDEN_SEED),
      });
      expect(placement.map((t) => t?.id ?? null)).toEqual(expected);
    },
  );
});
