import {
  calculateCountingRollup,
  calculateProgressRollup,
} from '../../src/algorithms/rollup';
import { evaluateCompositeTree } from '../../src/algorithms/compositeEvaluation';
import { detectBingos } from '../../src/algorithms/bingoDetection';
import { OperatorType } from '../../src/constants/enums';
import { CompositeNode } from '../../src/types/compositeTask';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function makeLeaf(
  id: string,
  compositeTaskId: string,
  parentNodeId: string | undefined,
  nodeIndex: number,
  taskId: string
): CompositeNode {
  return {
    id,
    compositeTaskId,
    parentNodeId,
    nodeIndex,
    nodeType: 'leaf',
    taskId,
    createdAt: '2024-01-01T00:00:00.000Z',
    updatedAt: '2024-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  };
}

function makeCompositeLeaf(
  id: string,
  compositeTaskId: string,
  parentNodeId: string | undefined,
  nodeIndex: number,
  childCompositeTaskId: string
): CompositeNode {
  return {
    id,
    compositeTaskId,
    parentNodeId,
    nodeIndex,
    nodeType: 'leaf',
    childCompositeTaskId,
    createdAt: '2024-01-01T00:00:00.000Z',
    updatedAt: '2024-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  };
}

function makeOperator(
  id: string,
  compositeTaskId: string,
  parentNodeId: string | undefined,
  nodeIndex: number,
  operatorType: OperatorType,
  threshold?: number
): CompositeNode {
  return {
    id,
    compositeTaskId,
    parentNodeId,
    nodeIndex,
    nodeType: 'operator',
    operatorType,
    threshold,
    createdAt: '2024-01-01T00:00:00.000Z',
    updatedAt: '2024-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  };
}

/**
 * Simulates a multi-board scenario by applying a rollup to each board's
 * parent state independently, returning updated states.
 */
function applyCountingRollupToBoards(
  boardStates: { currentCount: number }[],
  parentMaxCount: number,
  subtaskMaxCount: number
) {
  return boardStates.map((state) => {
    const result = calculateCountingRollup(
      state.currentCount,
      parentMaxCount,
      subtaskMaxCount
    );
    return { currentCount: result.newCount, isCompleted: result.isCompleted };
  });
}

// ─── Tests ────────────────────────────────────────────────────────────────────

describe('Cross-Board Task Sharing', () => {
  // ── 1. Same Task on Multiple Boards ──────────────────────────────────────

  describe('same task on multiple boards', () => {
    it('bingo detection runs independently per board with shared task', () => {
      // Board A: T1 completed, T2 completed, T3 completed → row_0 bingo
      const gridA: boolean[] = [
        true, true, true,
        false, true, false, // center (FREE) auto-completed
        false, false, false,
      ];

      // Board B: T1 completed, T4 NOT completed, T5 NOT completed → no row_0
      const gridB: boolean[] = [
        true, false, false,
        false, true, false,
        false, false, false,
      ];

      const resultA = detectBingos(gridA, 3);
      const resultB = detectBingos(gridB, 3);

      expect(resultA.completedLines).toContain('row_0');
      expect(resultB.completedLines).not.toContain('row_0');
    });

    it('completing a task on one board does not affect another board\'s grid', () => {
      // Simulate: T1 is on both boards
      // Board A marks T1 complete, Board B does not
      const gridA: boolean[] = [
        true, false, false,
        false, true, false,
        false, false, false,
      ];

      const gridB: boolean[] = [
        false, false, false, // T1 NOT completed on this board
        false, true, false,
        false, false, false,
      ];

      const resultA = detectBingos(gridA, 3);
      const resultB = detectBingos(gridB, 3);

      expect(resultA.totalCompleted).toBe(2); // T1 + FREE center
      expect(resultB.totalCompleted).toBe(1); // Only FREE center
    });

    it('each board can have different bingos despite shared tasks', () => {
      // Board A: column 0 complete (shared T1 at [0,0] + others at [1,0], [2,0])
      const gridA: boolean[] = [
        true, false, false,
        true, true, false,
        true, false, false,
      ];

      // Board B: row 0 complete (shared T1 at [0,0] + others at [0,1], [0,2])
      const gridB: boolean[] = [
        true, true, true,
        false, true, false,
        false, false, false,
      ];

      const resultA = detectBingos(gridA, 3);
      const resultB = detectBingos(gridB, 3);

      expect(resultA.completedLines).toContain('col_0');
      expect(resultA.completedLines).not.toContain('row_0');

      expect(resultB.completedLines).toContain('row_0');
      expect(resultB.completedLines).not.toContain('col_0');
    });
  });

  // ── 2. Counting Subtask Cross-Board Rollup ───────────────────────────────

  describe('counting subtask cross-board rollup', () => {
    it('rolls up single increment to parent on multiple boards', () => {
      // Parent "Read 100 pages" on Board A (count=0) and Board C (count=10)
      // Subtask increments +1
      const results = applyCountingRollupToBoards(
        [{ currentCount: 0 }, { currentCount: 10 }],
        100,
        1
      );

      expect(results[0]).toEqual({ currentCount: 1, isCompleted: false });
      expect(results[1]).toEqual({ currentCount: 11, isCompleted: false });
    });

    it('rolls up subtask maxCount when subtask completes', () => {
      // Subtask "Read 25 pages" completes → add 25 to each parent board
      const results = applyCountingRollupToBoards(
        [{ currentCount: 0 }, { currentCount: 10 }],
        100,
        25
      );

      expect(results[0]).toEqual({ currentCount: 25, isCompleted: false });
      expect(results[1]).toEqual({ currentCount: 35, isCompleted: false });
    });

    it('handles multiple subtasks completing sequentially', () => {
      // First subtask: +25
      const after25 = calculateCountingRollup(0, 100, 25);
      expect(after25).toEqual({ newCount: 25, isCompleted: false });

      // Second subtask: +30
      const after30 = calculateCountingRollup(after25.newCount, 100, 30);
      expect(after30).toEqual({ newCount: 55, isCompleted: false });
    });

    it('caps at maxCount and marks completed', () => {
      // Parent at 80/100, subtask adds 25 → capped at 100
      const result = calculateCountingRollup(80, 100, 25);
      expect(result).toEqual({ newCount: 100, isCompleted: true });
    });

    it('does not overflow when parent already complete', () => {
      // Parent at 100/100, subtask adds 25
      const result = calculateCountingRollup(100, 100, 25);
      expect(result).toEqual({ newCount: 100, isCompleted: true });
    });

    it('handles subtask with maxCount larger than remaining', () => {
      // Parent at 90/100, subtask adds 50
      const result = calculateCountingRollup(90, 100, 50);
      expect(result).toEqual({ newCount: 100, isCompleted: true });
    });

    it('each board gets independent rollup result', () => {
      // Board A: 80/100 → completes
      // Board C: 10/100 → does not complete
      const resultA = calculateCountingRollup(80, 100, 25);
      const resultC = calculateCountingRollup(10, 100, 25);

      expect(resultA.isCompleted).toBe(true);
      expect(resultC.isCompleted).toBe(false);
    });
  });

  // ── 3. Progress Step Cross-Board Rollup ──────────────────────────────────

  describe('progress step cross-board rollup', () => {
    it('adds step to empty parent', () => {
      const result = calculateProgressRollup([], 'step_1', 3);
      expect(result.newCompletedStepIds).toEqual(['step_1']);
      expect(result.isCompleted).toBe(false);
    });

    it('adds step to parent with existing completed steps', () => {
      const result = calculateProgressRollup(['step_2'], 'step_1', 3);
      expect(result.newCompletedStepIds).toEqual(['step_2', 'step_1']);
      expect(result.isCompleted).toBe(false);
    });

    it('does not add duplicate step (idempotency)', () => {
      const result = calculateProgressRollup(['step_1'], 'step_1', 3);
      expect(result.newCompletedStepIds).toEqual(['step_1']);
      expect(result.isCompleted).toBe(false);
    });

    it('marks completed when last step is added', () => {
      const result = calculateProgressRollup(
        ['step_1', 'step_2'],
        'step_3',
        3
      );
      expect(result.newCompletedStepIds).toEqual([
        'step_1',
        'step_2',
        'step_3',
      ]);
      expect(result.isCompleted).toBe(true);
    });

    it('rolls up to multiple boards with different step states', () => {
      // Board A: no steps done
      const resultA = calculateProgressRollup([], 'step_1', 3);
      // Board C: step_2 already done
      const resultC = calculateProgressRollup(['step_2'], 'step_1', 3);

      expect(resultA.newCompletedStepIds).toEqual(['step_1']);
      expect(resultC.newCompletedStepIds).toEqual(['step_2', 'step_1']);

      expect(resultA.isCompleted).toBe(false);
      expect(resultC.isCompleted).toBe(false);
    });

    it('sequential step completions across different boards lead to parent completion', () => {
      // Step 1 completed on Board B1
      const after1 = calculateProgressRollup([], 'step_1', 3);
      // Step 2 completed on Board B2
      const after2 = calculateProgressRollup(
        after1.newCompletedStepIds,
        'step_2',
        3
      );
      // Step 3 completed on Board B3
      const after3 = calculateProgressRollup(
        after2.newCompletedStepIds,
        'step_3',
        3
      );

      expect(after3.newCompletedStepIds).toEqual([
        'step_1',
        'step_2',
        'step_3',
      ]);
      expect(after3.isCompleted).toBe(true);
    });

    it('step completion affects bingo on parent board', () => {
      // Board A: parent at [0,0], all other row_0 positions complete
      // After all steps done, parent completes → row_0 bingo
      const gridBefore: boolean[] = [
        false, true, true, // parent at [0,0] incomplete, others done
        false, true, false,
        false, false, false,
      ];

      const gridAfter: boolean[] = [
        true, true, true, // parent now complete after rollup
        false, true, false,
        false, false, false,
      ];

      const resultBefore = detectBingos(gridBefore, 3);
      const resultAfter = detectBingos(gridAfter, 3);

      expect(resultBefore.completedLines).not.toContain('row_0');
      expect(resultAfter.completedLines).toContain('row_0');
    });
  });

  // ── 4. Composite Task Evaluation with Cross-Board Leaves ─────────────────

  describe('composite task evaluation with cross-board leaves', () => {
    // Composite "Fitness Goals" (AND)
    // ├── run_task (Board A)
    // ├── read_task (Board A)
    // └── sub_composite "Morning Routine" (OR)
    //     ├── meditate_task (Board B)
    //     └── journal_task (Board C)

    const compositeId = 'fitness_composite';
    const subCompositeId = 'morning_composite';
    const rootId = 'root_op';
    const subRootId = 'sub_root_op';

    const mainNodes: CompositeNode[] = [
      makeOperator(rootId, compositeId, undefined, 0, OperatorType.AND),
      makeLeaf('leaf_run', compositeId, rootId, 0, 'run_task'),
      makeLeaf('leaf_read', compositeId, rootId, 1, 'read_task'),
      makeCompositeLeaf(
        'leaf_sub',
        compositeId,
        rootId,
        2,
        subCompositeId
      ),
    ];

    const subNodes: CompositeNode[] = [
      makeOperator(
        subRootId,
        subCompositeId,
        undefined,
        0,
        OperatorType.OR
      ),
      makeLeaf('leaf_meditate', subCompositeId, subRootId, 0, 'meditate_task'),
      makeLeaf('leaf_journal', subCompositeId, subRootId, 1, 'journal_task'),
    ];

    it('returns false when no tasks are completed', () => {
      const taskCompletions = {
        run_task: false,
        read_task: false,
        meditate_task: false,
        journal_task: false,
      };

      // Sub-composite (OR): both false → false
      const subResult = evaluateCompositeTree(
        subNodes,
        subRootId,
        taskCompletions
      );
      expect(subResult).toBe(false);

      // Main (AND): all false → false
      const mainResult = evaluateCompositeTree(mainNodes, rootId, taskCompletions, {
        [subCompositeId]: subResult,
      });
      expect(mainResult).toBe(false);
    });

    it('returns false when AND is partially satisfied', () => {
      const taskCompletions = {
        run_task: true, // Board A - done
        read_task: false, // Board A - not done
        meditate_task: true, // Board B - done
        journal_task: false, // Board C - not done
      };

      const subResult = evaluateCompositeTree(
        subNodes,
        subRootId,
        taskCompletions
      );
      expect(subResult).toBe(true); // OR: meditate done

      const mainResult = evaluateCompositeTree(mainNodes, rootId, taskCompletions, {
        [subCompositeId]: subResult,
      });
      expect(mainResult).toBe(false); // AND: read missing
    });

    it('returns true when all AND leaves satisfied across boards', () => {
      const taskCompletions = {
        run_task: true,
        read_task: true,
        meditate_task: true,
        journal_task: false, // doesn't matter, OR only needs one
      };

      const subResult = evaluateCompositeTree(
        subNodes,
        subRootId,
        taskCompletions
      );
      expect(subResult).toBe(true);

      const mainResult = evaluateCompositeTree(mainNodes, rootId, taskCompletions, {
        [subCompositeId]: subResult,
      });
      expect(mainResult).toBe(true);
    });

    it('M_OF_N with tasks distributed across boards', () => {
      const mofnNodes: CompositeNode[] = [
        makeOperator('mofn_root', 'mofn', undefined, 0, OperatorType.M_OF_N, 2),
        makeLeaf('mofn_a', 'mofn', 'mofn_root', 0, 'task_board_a'),
        makeLeaf('mofn_b', 'mofn', 'mofn_root', 1, 'task_board_b'),
        makeLeaf('mofn_c', 'mofn', 'mofn_root', 2, 'task_board_c'),
      ];

      // 1 of 3 → false
      expect(
        evaluateCompositeTree(mofnNodes, 'mofn_root', {
          task_board_a: true,
          task_board_b: false,
          task_board_c: false,
        })
      ).toBe(false);

      // 2 of 3 → true
      expect(
        evaluateCompositeTree(mofnNodes, 'mofn_root', {
          task_board_a: true,
          task_board_b: false,
          task_board_c: true,
        })
      ).toBe(true);

      // 3 of 3 → true
      expect(
        evaluateCompositeTree(mofnNodes, 'mofn_root', {
          task_board_a: true,
          task_board_b: true,
          task_board_c: true,
        })
      ).toBe(true);
    });
  });

  // ── 5. Edge Cases ────────────────────────────────────────────────────────

  describe('cross-board edge cases', () => {
    it('counting rollup with maxCount=0 handles gracefully', () => {
      const result = calculateCountingRollup(0, 0, 5);
      // 0 + 5 = 5, but capped at max 0 → 0, isCompleted: true (0 >= 0)
      expect(result.newCount).toBe(0);
      expect(result.isCompleted).toBe(true);
    });

    it('counting rollup with subtaskMaxCount=0 is a no-op', () => {
      const result = calculateCountingRollup(50, 100, 0);
      expect(result).toEqual({ newCount: 50, isCompleted: false });
    });

    it('progress rollup with totalStepCount=0 marks completed', () => {
      // Edge case: a progress task with 0 steps
      const result = calculateProgressRollup([], 'step_1', 0);
      // newCompletedStepIds has 1 element, 1 >= 0 → completed
      expect(result.newCompletedStepIds).toEqual(['step_1']);
      expect(result.isCompleted).toBe(true);
    });

    it('rollup-triggered completion creates bingo on receiving board', () => {
      // Board A: parent task at [2,2], row_2 almost complete
      // Before rollup: parent incomplete → no row_2 bingo
      const gridBefore: boolean[] = [
        true, false, false,
        false, true, false,
        true, true, false, // [2,2] = parent, incomplete
      ];

      // After rollup: parent completes at [2,2] → row_2 bingo + diag_main ([0,0],[1,1],[2,2])
      const gridAfter: boolean[] = [
        true, false, false,
        false, true, false,
        true, true, true, // [2,2] now complete
      ];

      const before = detectBingos(gridBefore, 3);
      const after = detectBingos(gridAfter, 3);

      expect(before.completedLines).not.toContain('row_2');
      expect(after.completedLines).toContain('row_2');
      expect(after.completedLines).toContain('diag_main'); // [0,0]=T [1,1]=T [2,2]=T
    });

    it('counting rollup with negative parentCurrentCount handled', () => {
      // Defensive: shouldn't happen, but function should not crash
      const result = calculateCountingRollup(-5, 100, 10);
      expect(result.newCount).toBe(5); // -5 + 10 = 5
      expect(result.isCompleted).toBe(false);
    });

    it('progress rollup preserves order of existing step IDs', () => {
      const result = calculateProgressRollup(
        ['step_3', 'step_1'],
        'step_2',
        3
      );
      expect(result.newCompletedStepIds).toEqual([
        'step_3',
        'step_1',
        'step_2',
      ]);
    });
  });
});
