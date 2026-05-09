import { hasCycle } from '../../src/algorithms/cycleDetection';
import { BoardStatus, CenterSquareType, Timeframe } from '../../src/constants/enums';
import type { Board, BoardTask } from '../../src';

// ─── Helpers ──────────────────────────────────────────────────────────────────

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

function squareReferencingBoard(boardId: string, refBoardId: string, idx = 0): BoardTask {
  return {
    id: `bt-${boardId}-${refBoardId}-${idx}`,
    boardId,
    taskId: `task-${idx}`,
    row: 0,
    col: idx,
    isCenter: false,
    isAchievementSquare: true,
    referencedBoardId: refBoardId,
    createdAt: '2026-04-23T00:00:00.000Z',
    updatedAt: '2026-04-23T00:00:00.000Z',
    version: 1,
  };
}

function squareReferencingTemplate(boardId: string, refTemplateId: string, idx = 0): BoardTask {
  return {
    id: `bt-${boardId}-${refTemplateId}-${idx}`,
    boardId,
    taskId: `task-${idx}`,
    row: 0,
    col: idx,
    isCenter: false,
    isAchievementSquare: true,
    referencedTemplateId: refTemplateId,
    createdAt: '2026-04-23T00:00:00.000Z',
    updatedAt: '2026-04-23T00:00:00.000Z',
    version: 1,
  };
}

// ─── Direct (referencedBoardId) cycles ───────────────────────────────────────

describe('hasCycle — referencedBoardId edges', () => {
  it('self-reference (boardId === referencedBoardId) → degenerate cycle', () => {
    const a = board('a');
    const result = hasCycle(
      { boardId: 'a', referencedBoardId: 'a' },
      { allBoardTasks: [], allBoards: [a] },
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.cyclePath).toEqual(['a', 'a']);
    }
  });

  it('two-cycle A→B→A: candidate is the closing edge → rejected with path', () => {
    const a = board('a');
    const b = board('b');
    // Pre-existing edge: B's square references A.
    const existing = [squareReferencingBoard('b', 'a')];
    // Candidate: A's square would reference B → closes the loop A→B→A.
    const result = hasCycle(
      { boardId: 'a', referencedBoardId: 'b' },
      { allBoardTasks: existing, allBoards: [a, b] },
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      // Path starts with the candidate's parent, walks to the target,
      // and ends back at the parent.
      expect(result.cyclePath[0]).toBe('a');
      expect(result.cyclePath[result.cyclePath.length - 1]).toBe('a');
      expect(result.cyclePath).toContain('b');
    }
  });

  it('three-cycle A→B→C→A: candidate is the closing edge → rejected', () => {
    const a = board('a');
    const b = board('b');
    const c = board('c');
    const existing = [
      squareReferencingBoard('b', 'c'), // B → C
      squareReferencingBoard('c', 'a'), // C → A
    ];
    // Candidate: A → B closes the loop.
    const result = hasCycle(
      { boardId: 'a', referencedBoardId: 'b' },
      { allBoardTasks: existing, allBoards: [a, b, c] },
    );
    expect(result.ok).toBe(false);
  });

  it('no cycle: A→B and A→C (fan-out, no return path) → ok', () => {
    const a = board('a');
    const b = board('b');
    const c = board('c');
    const existing = [squareReferencingBoard('a', 'c')]; // A → C (existing)
    const result = hasCycle(
      { boardId: 'a', referencedBoardId: 'b' }, // A → B (candidate)
      { allBoardTasks: existing, allBoards: [a, b, c] },
    );
    expect(result.ok).toBe(true);
  });

  it('no cycle baseline: empty graph → candidate accepted', () => {
    const a = board('a');
    const b = board('b');
    const result = hasCycle(
      { boardId: 'a', referencedBoardId: 'b' },
      { allBoardTasks: [], allBoards: [a, b] },
    );
    expect(result.ok).toBe(true);
  });

  it('cycle through a chain that does NOT include the candidate (unrelated cycle in graph) → ok', () => {
    const a = board('a');
    const b = board('b');
    const c = board('c');
    const d = board('d');
    // Pre-existing cycle B↔C (placed in the past, possibly via a sync race).
    const existing = [
      squareReferencingBoard('b', 'c'),
      squareReferencingBoard('c', 'b'),
    ];
    // Candidate A→D doesn't touch the cycle → ok.
    const result = hasCycle(
      { boardId: 'a', referencedBoardId: 'd' },
      { allBoardTasks: existing, allBoards: [a, b, c, d] },
    );
    expect(result.ok).toBe(true);
  });
});

// ─── Template-edge cycles ────────────────────────────────────────────────────

describe('hasCycle — referencedTemplateId edges', () => {
  it('template-self-reference: parent board\'s spawnedFromTemplateId === referencedTemplateId → degenerate cycle', () => {
    const parent = board('p', { spawnedFromTemplateId: 't1' });
    const result = hasCycle(
      { boardId: 'p', referencedTemplateId: 't1' },
      { allBoardTasks: [], allBoards: [parent] },
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.cyclePath).toEqual(['p', 'p']);
    }
  });

  it('candidate template fans out to spawns; one spawn has a square referencing back to candidate → rejected', () => {
    const parent = board('parent');
    const spawn = board('spawn-1', { spawnedFromTemplateId: 't1' });
    // Existing edge: spawn-1 has a square referencing parent.
    const existing = [squareReferencingBoard('spawn-1', 'parent')];
    // Candidate: parent's square would reference template t1.
    // Adjacency: parent → spawn-1 (via template fan-out) → parent → cycle.
    const result = hasCycle(
      { boardId: 'parent', referencedTemplateId: 't1' },
      { allBoardTasks: existing, allBoards: [parent, spawn] },
    );
    expect(result.ok).toBe(false);
  });

  it('candidate references template with zero spawns yet → no cycle possible (fan-out is empty) → ok', () => {
    const parent = board('parent');
    const result = hasCycle(
      { boardId: 'parent', referencedTemplateId: 't1' },
      { allBoardTasks: [], allBoards: [parent] },
    );
    expect(result.ok).toBe(true);
  });

  it('two-cycle through templates: A → templateT (spawns B) → B has square → templateU (spawns A) → rejected', () => {
    // Setup:
    //   - Board A is a spawn of templateU.
    //   - Board B is a spawn of templateT.
    //   - B has a square that references templateU (which fans out to A).
    //   - Candidate: A's square references templateT (which fans out to B).
    // Closes: A → B → A.
    const a = board('a', { spawnedFromTemplateId: 'tu' });
    const b = board('b', { spawnedFromTemplateId: 'tt' });
    const existing = [squareReferencingTemplate('b', 'tu')];
    const result = hasCycle(
      { boardId: 'a', referencedTemplateId: 'tt' },
      { allBoardTasks: existing, allBoards: [a, b] },
    );
    expect(result.ok).toBe(false);
  });

  it('soft-deleted spawn does NOT contribute a cycle edge → ok', () => {
    const parent = board('parent');
    const spawn = board('spawn-1', { spawnedFromTemplateId: 't1', isDeleted: true });
    // Even though the soft-deleted spawn has a square pointing back at parent,
    // the deleted board doesn't contribute to the adjacency (it's filtered).
    const existing = [squareReferencingBoard('spawn-1', 'parent')];
    const result = hasCycle(
      { boardId: 'parent', referencedTemplateId: 't1' },
      { allBoardTasks: existing, allBoards: [parent, spawn] },
    );
    expect(result.ok).toBe(true);
  });
});
