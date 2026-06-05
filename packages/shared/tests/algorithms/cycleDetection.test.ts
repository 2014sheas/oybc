import { hasCycle } from '../../src/algorithms/cycleDetection';
import { BoardStatus, CenterSquareType, TaskType, Timeframe } from '../../src/constants/enums';
import type { Board, BoardTask, Task } from '../../src';

// ─── Helpers ──────────────────────────────────────────────────────────────────
//
// Phase 6.3 refactor: achievement-task cross-board references live on Task,
// not BoardTask. Each helper builds the smallest valid shape needed to drive
// the cycle-detection graph.

function board(id: string, overrides: Partial<Board> = {}): Board {
  return {
    id,
    userId: 'u',
    name: id,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.MONTHLY,
    startDate: '2026-04-01T00:00:00.000Z',
    endDate: '2026-04-30T23:59:59.000Z',
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: '2026-04-23T00:00:00.000Z',
    updatedAt: '2026-04-23T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function achievementTask(
  id: string,
  refs: { referencedBoardId?: string; referencedTemplateId?: string },
): Task {
  return {
    id,
    userId: 'u',
    title: id,
    type: TaskType.ACHIEVEMENT,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-04-23T00:00:00.000Z',
    updatedAt: '2026-04-23T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...refs,
  };
}

function placement(boardId: string, taskId: string, idx = 0): BoardTask {
  return {
    id: `bt-${boardId}-${taskId}-${idx}`,
    boardId,
    taskId,
    row: 0,
    col: idx,
    isCenter: false,
    createdAt: '2026-04-23T00:00:00.000Z',
    updatedAt: '2026-04-23T00:00:00.000Z',
    version: 1,
  };
}

// ─── Direct (referencedBoardId) cycles ───────────────────────────────────────

describe('hasCycle — referencedBoardId edges', () => {
  it('no parents → trivially safe (achievement Task not yet placed)', () => {
    const a = board('a');
    const result = hasCycle(
      { parentBoardIds: [], referencedBoardId: 'a' },
      { allBoardTasks: [], allTasks: [], allBoards: [a] },
    );
    expect(result.ok).toBe(true);
  });

  it('self-reference (parentBoardId === referencedBoardId) → degenerate cycle', () => {
    const a = board('a');
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedBoardId: 'a' },
      { allBoardTasks: [], allTasks: [], allBoards: [a] },
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.cyclePath).toEqual(['a', 'a']);
    }
  });

  it('two-cycle A→B→A: candidate is the closing edge → rejected with path', () => {
    const a = board('a');
    const b = board('b');
    // Pre-existing: an achievement Task watching A is placed on B.
    const existingTask = achievementTask('ach-b→a', { referencedBoardId: 'a' });
    const existingPlacement = placement('b', 'ach-b→a');
    // Candidate: a NEW achievement Task watching B, about to be placed on A.
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedBoardId: 'b' },
      {
        allBoardTasks: [existingPlacement],
        allTasks: [existingTask],
        allBoards: [a, b],
      },
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.cyclePath[0]).toBe('a');
      expect(result.cyclePath[result.cyclePath.length - 1]).toBe('a');
      expect(result.cyclePath).toContain('b');
    }
  });

  it('three-cycle A→B→C→A: candidate is the closing edge → rejected', () => {
    const a = board('a');
    const b = board('b');
    const c = board('c');
    const t1 = achievementTask('t1', { referencedBoardId: 'c' }); // B → C
    const p1 = placement('b', 't1');
    const t2 = achievementTask('t2', { referencedBoardId: 'a' }); // C → A
    const p2 = placement('c', 't2');
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedBoardId: 'b' }, // A → B (candidate)
      {
        allBoardTasks: [p1, p2],
        allTasks: [t1, t2],
        allBoards: [a, b, c],
      },
    );
    expect(result.ok).toBe(false);
  });

  it('no cycle: A→B and A→C (fan-out, no return path) → ok', () => {
    const a = board('a');
    const b = board('b');
    const c = board('c');
    const t1 = achievementTask('t1', { referencedBoardId: 'c' });
    const p1 = placement('a', 't1');
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedBoardId: 'b' },
      {
        allBoardTasks: [p1],
        allTasks: [t1],
        allBoards: [a, b, c],
      },
    );
    expect(result.ok).toBe(true);
  });

  it('no cycle baseline: empty graph → candidate accepted', () => {
    const a = board('a');
    const b = board('b');
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedBoardId: 'b' },
      { allBoardTasks: [], allTasks: [], allBoards: [a, b] },
    );
    expect(result.ok).toBe(true);
  });

  it('cycle through a chain that does NOT include the candidate (unrelated cycle in graph) → ok', () => {
    const a = board('a');
    const b = board('b');
    const c = board('c');
    const d = board('d');
    // Pre-existing cycle B↔C (placed in the past, possibly via a sync race).
    const tBC = achievementTask('tBC', { referencedBoardId: 'c' });
    const pBC = placement('b', 'tBC');
    const tCB = achievementTask('tCB', { referencedBoardId: 'b' });
    const pCB = placement('c', 'tCB');
    // Candidate A→D doesn't touch the cycle → ok.
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedBoardId: 'd' },
      {
        allBoardTasks: [pBC, pCB],
        allTasks: [tBC, tCB],
        allBoards: [a, b, c, d],
      },
    );
    expect(result.ok).toBe(true);
  });

  it('non-achievement Task placements do NOT contribute edges → ok', () => {
    const a = board('a');
    const b = board('b');
    // A normal Task placed on B — has no reference at all (not an achievement).
    // Adjacency should ignore this placement.
    const normalTask: Task = {
      id: 'norm',
      userId: 'u',
      title: 'norm',
      type: TaskType.NORMAL,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: '2026-04-23T00:00:00.000Z',
      updatedAt: '2026-04-23T00:00:00.000Z',
      version: 1,
      isDeleted: false,
    };
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedBoardId: 'b' },
      {
        allBoardTasks: [placement('b', 'norm')],
        allTasks: [normalTask],
        allBoards: [a, b],
      },
    );
    expect(result.ok).toBe(true);
  });

  it('multi-parent candidate: same achievement Task placed on A and B, candidate target loops to A → rejected', () => {
    // Pre-existing: an achievement Task watching A placed on C.
    const a = board('a');
    const b = board('b');
    const c = board('c');
    const tCA = achievementTask('tCA', { referencedBoardId: 'a' });
    const pCA = placement('c', 'tCA');
    // Candidate: an achievement Task watching C, placed on BOTH A and B.
    // Adjacency A→C and B→C are added. The C→A edge already exists, so
    // start=C → A (in parentSet) closes a cycle through parent A.
    const result = hasCycle(
      { parentBoardIds: ['a', 'b'], referencedBoardId: 'c' },
      {
        allBoardTasks: [pCA],
        allTasks: [tCA],
        allBoards: [a, b, c],
      },
    );
    expect(result.ok).toBe(false);
  });
});

// ─── Template-edge cycles ────────────────────────────────────────────────────

describe('hasCycle — referencedTemplateId edges', () => {
  it('template-self-reference: parent board\'s spawnedFromTemplateId === referencedTemplateId → degenerate cycle', () => {
    const parent = board('p', { spawnedFromTemplateId: 't1' });
    const result = hasCycle(
      { parentBoardIds: ['p'], referencedTemplateId: 't1' },
      { allBoardTasks: [], allTasks: [], allBoards: [parent] },
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.cyclePath).toEqual(['p', 'p']);
    }
  });

  it('candidate template fans out to spawns; one spawn has a square referencing back to candidate parent → rejected', () => {
    const parent = board('parent');
    const spawn = board('spawn-1', { spawnedFromTemplateId: 't1' });
    // Existing: achievement Task watching parent placed on spawn-1.
    const tBack = achievementTask('tBack', { referencedBoardId: 'parent' });
    const pBack = placement('spawn-1', 'tBack');
    // Candidate: achievement Task watching template t1, placed on parent.
    // Adjacency: parent → spawn-1 (via template fan-out) → parent → cycle.
    const result = hasCycle(
      { parentBoardIds: ['parent'], referencedTemplateId: 't1' },
      {
        allBoardTasks: [pBack],
        allTasks: [tBack],
        allBoards: [parent, spawn],
      },
    );
    expect(result.ok).toBe(false);
  });

  it('candidate references template with zero spawns yet → no cycle possible (fan-out is empty) → ok', () => {
    const parent = board('parent');
    const result = hasCycle(
      { parentBoardIds: ['parent'], referencedTemplateId: 't1' },
      { allBoardTasks: [], allTasks: [], allBoards: [parent] },
    );
    expect(result.ok).toBe(true);
  });

  it('two-cycle through templates: A → templateT (spawns B) → B has square → templateU (spawns A) → rejected', () => {
    // Setup:
    //   - Board A is a spawn of templateU.
    //   - Board B is a spawn of templateT.
    //   - B has a square that references templateU (which fans out to A).
    //   - Candidate: A's achievement Task references templateT (fans out to B).
    // Closes: A → B → A.
    const a = board('a', { spawnedFromTemplateId: 'tu' });
    const b = board('b', { spawnedFromTemplateId: 'tt' });
    const tB = achievementTask('tB', { referencedTemplateId: 'tu' });
    const pB = placement('b', 'tB');
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedTemplateId: 'tt' },
      {
        allBoardTasks: [pB],
        allTasks: [tB],
        allBoards: [a, b],
      },
    );
    expect(result.ok).toBe(false);
  });

  it('soft-deleted spawn does NOT contribute a cycle edge → ok', () => {
    const parent = board('parent');
    const spawn = board('spawn-1', { spawnedFromTemplateId: 't1', isDeleted: true });
    // Even though the soft-deleted spawn has a square pointing back at parent,
    // the deleted board doesn't contribute to the adjacency (it's filtered).
    const tBack = achievementTask('tBack', { referencedBoardId: 'parent' });
    const pBack = placement('spawn-1', 'tBack');
    const result = hasCycle(
      { parentBoardIds: ['parent'], referencedTemplateId: 't1' },
      {
        allBoardTasks: [pBack],
        allTasks: [tBack],
        allBoards: [parent, spawn],
      },
    );
    expect(result.ok).toBe(true);
  });

  it('window-aware fan-out: out-of-window spawn reachable back to parent does NOT report a cycle', () => {
    // Parent P is monthly (April 1-30). Template T has two spawns:
    //   - April spawn (in P's window)
    //   - May spawn (out of P's window)
    // The May spawn places an achievement task that watches P. Without
    // window-aware fan-out, the cycle check would build edge May→P AND
    // add candidate edges P→April AND P→May, then DFS would find
    // May→P → cycle. But derivation only counts in-window spawns, so
    // the May spawn never contributes to P's evaluation — the cycle
    // doesn't exist semantically. The post-fix algorithm filters May
    // out of P's template fan-out, breaking the false-positive path.
    const parent = board('p', {
      startDate: '2026-04-01T00:00:00.000Z',
      endDate: '2026-04-30T23:59:59.000Z',
    });
    const aprilSpawn = board('apr', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-04-15T00:00:00.000Z',
      endDate: '2026-04-15T23:59:59.000Z',
    });
    const maySpawn = board('may', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-05-15T00:00:00.000Z',
      endDate: '2026-05-15T23:59:59.000Z',
    });
    // May spawn places an achievement task watching P.
    const tBack = achievementTask('tBack', { referencedBoardId: 'p' });
    const pBack = placement('may', 'tBack');
    // Candidate: P places an achievement task watching template t1.
    const result = hasCycle(
      { parentBoardIds: ['p'], referencedTemplateId: 't1' },
      {
        allBoardTasks: [pBack],
        allTasks: [tBack],
        allBoards: [parent, aprilSpawn, maySpawn],
      },
    );
    expect(result.ok).toBe(true);
  });

  it('window-aware fan-out: in-window spawn reachable back to parent DOES report a cycle', () => {
    // Mirror of the test above but the cycle-closing spawn is IN P's
    // window — so the cycle is real and must be rejected.
    const parent = board('p', {
      startDate: '2026-04-01T00:00:00.000Z',
      endDate: '2026-04-30T23:59:59.000Z',
    });
    const aprilSpawn = board('apr', {
      spawnedFromTemplateId: 't1',
      startDate: '2026-04-15T00:00:00.000Z',
      endDate: '2026-04-15T23:59:59.000Z',
    });
    const tBack = achievementTask('tBack', { referencedBoardId: 'p' });
    const pBack = placement('apr', 'tBack');
    const result = hasCycle(
      { parentBoardIds: ['p'], referencedTemplateId: 't1' },
      {
        allBoardTasks: [pBack],
        allTasks: [tBack],
        allBoards: [parent, aprilSpawn],
      },
    );
    expect(result.ok).toBe(false);
  });

  it('placement on a soft-deleted board does NOT contribute an edge → ok', () => {
    // Derivation ignores tasks placed on soft-deleted boards; cycle
    // adjacency should match. Without the boardsById guard, the edge
    // from the deleted board could close a false-positive cycle.
    const a = board('a');
    const b = board('b');
    const cDeleted = board('c', { isDeleted: true });
    const tCA = achievementTask('tCA', { referencedBoardId: 'a' });
    const pCA = placement('c', 'tCA');
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedBoardId: 'b' },
      {
        allBoardTasks: [pCA],
        allTasks: [tCA],
        allBoards: [a, b, cDeleted],
      },
    );
    expect(result.ok).toBe(true);
  });

  it('candidate referencing a soft-deleted board does NOT contribute an edge → ok', () => {
    // Mirror of the test above but the DELETED endpoint is on the
    // candidate side: A's candidate watches a soft-deleted B. Even
    // if B has a back-edge to A (its placement still exists), the
    // candidate edge into B should be skipped.
    const a = board('a');
    const bDeleted = board('b', { isDeleted: true });
    const tBA = achievementTask('tBA', { referencedBoardId: 'a' });
    const pBA = placement('b', 'tBA');
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedBoardId: 'b' },
      {
        allBoardTasks: [pBA],
        allTasks: [tBA],
        allBoards: [a, bDeleted],
      },
    );
    expect(result.ok).toBe(true);
  });

  it('soft-deleted achievement Task does NOT contribute a cycle edge → ok', () => {
    const a = board('a');
    const b = board('b');
    // Achievement Task watching A is soft-deleted; placement still exists,
    // but the deleted Task is filtered out of `tasksById` so no edge.
    const tDel = achievementTask('tDel', { referencedBoardId: 'a' });
    tDel.isDeleted = true;
    const pDel = placement('b', 'tDel');
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedBoardId: 'b' },
      {
        allBoardTasks: [pDel],
        allTasks: [tDel],
        allBoards: [a, b],
      },
    );
    expect(result.ok).toBe(true);
  });
});

// ─── Live-edit M1: Achievement re-target cycle detection ─────────────────────
//
// When the user edits an existing Achievement task and changes its target
// (referencedBoardId or referencedTemplateId), hasCycle() is called with
// the NEW candidate value before the DB write. These tests document the
// two key outcomes: rejection when the new target would close a cycle,
// and acceptance when the new target is safe.

describe('hasCycle — Achievement re-target (live-edit M1)', () => {
  it('re-target to a board that would close a cycle → rejected', () => {
    // Pre-existing graph: achievement Task on board B watches board A.
    // User edits an existing achievement Task on board A to now watch board B.
    // This closes A → B → A.
    const a = board('a');
    const b = board('b');
    const existingTask = achievementTask('tBA', { referencedBoardId: 'a' });
    const existingPlacement = placement('b', 'tBA');
    // Candidate: existing task being re-targeted, currently on board A, new target = B.
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedBoardId: 'b' },
      {
        allBoardTasks: [existingPlacement],
        allTasks: [existingTask],
        allBoards: [a, b],
      },
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.cyclePath).toContain('a');
      expect(result.cyclePath).toContain('b');
    }
  });

  it('re-target to a board with no return path → accepted', () => {
    // Pre-existing graph: achievement Task on board A watches board C.
    // User re-targets the task to watch board B instead.
    // B has no path back to A, so the new reference is safe.
    const a = board('a');
    const b = board('b');
    const c = board('c');
    const existingTask = achievementTask('tAC', { referencedBoardId: 'c' });
    const existingPlacement = placement('a', 'tAC');
    // Candidate: re-targeting from C to B (parentBoardIds stays ['a']).
    const result = hasCycle(
      { parentBoardIds: ['a'], referencedBoardId: 'b' },
      {
        allBoardTasks: [existingPlacement],
        allTasks: [existingTask],
        allBoards: [a, b, c],
      },
    );
    expect(result.ok).toBe(true);
  });

  it('re-target to a template whose spawns close a cycle → rejected', () => {
    // Board P is the parent of the achievement task being edited.
    // Template T has a spawn S. S already has a task watching P.
    // If P's achievement now watches T (which fans out to S → P), cycle.
    const p = board('p');
    const s = board('s', { spawnedFromTemplateId: 'T' });
    const backTask = achievementTask('tBack', { referencedBoardId: 'p' });
    const backPlacement = placement('s', 'tBack');
    const result = hasCycle(
      { parentBoardIds: ['p'], referencedTemplateId: 'T' },
      {
        allBoardTasks: [backPlacement],
        allTasks: [backTask],
        allBoards: [p, s],
      },
    );
    expect(result.ok).toBe(false);
  });

  it('re-target to a template with no cycle-closing spawn → accepted', () => {
    // Board P watches template T. T has spawn S. S has no reference to P.
    const p = board('p');
    const s = board('s', { spawnedFromTemplateId: 'T' });
    const unrelatedTask = achievementTask('tSX', { referencedBoardId: 'x' });
    const unrelatedPlacement = placement('s', 'tSX');
    const unrelatedBoard = board('x');
    const result = hasCycle(
      { parentBoardIds: ['p'], referencedTemplateId: 'T' },
      {
        allBoardTasks: [unrelatedPlacement],
        allTasks: [unrelatedTask],
        allBoards: [p, s, unrelatedBoard],
      },
    );
    expect(result.ok).toBe(true);
  });
});
