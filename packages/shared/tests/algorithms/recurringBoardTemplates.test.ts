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
