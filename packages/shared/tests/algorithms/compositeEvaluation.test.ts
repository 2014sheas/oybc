import {
  evaluateCompositeTree,
} from '../../src/algorithms/compositeEvaluation';
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

// ─── evaluateCompositeTree ────────────────────────────────────────────────────

describe('evaluateCompositeTree', () => {
  describe('AND operator', () => {
    const ctId = 'ct-and';
    const root = makeOperator('root', ctId, undefined, 0, OperatorType.AND);
    const leafA = makeLeaf('leaf-a', ctId, 'root', 0, 'task-a');
    const leafB = makeLeaf('leaf-b', ctId, 'root', 1, 'task-b');
    const nodes = [root, leafA, leafB];

    it('returns true when all children complete', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', { 'task-a': true, 'task-b': true }, {})
      ).toBe(true);
    });

    it('returns false when first child incomplete', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', { 'task-a': false, 'task-b': true }, {})
      ).toBe(false);
    });

    it('returns false when second child incomplete', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', { 'task-a': true, 'task-b': false }, {})
      ).toBe(false);
    });

    it('returns false when all children incomplete', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', { 'task-a': false, 'task-b': false }, {})
      ).toBe(false);
    });
  });

  describe('OR operator', () => {
    const ctId = 'ct-or';
    const root = makeOperator('root', ctId, undefined, 0, OperatorType.OR);
    const leafA = makeLeaf('leaf-a', ctId, 'root', 0, 'task-a');
    const leafB = makeLeaf('leaf-b', ctId, 'root', 1, 'task-b');
    const nodes = [root, leafA, leafB];

    it('returns true when all children complete', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', { 'task-a': true, 'task-b': true }, {})
      ).toBe(true);
    });

    it('returns true when only first child complete', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', { 'task-a': true, 'task-b': false }, {})
      ).toBe(true);
    });

    it('returns true when only second child complete', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', { 'task-a': false, 'task-b': true }, {})
      ).toBe(true);
    });

    it('returns false when all children incomplete', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', { 'task-a': false, 'task-b': false }, {})
      ).toBe(false);
    });
  });

  describe('M_OF_N operator', () => {
    const ctId = 'ct-mon';
    const root = makeOperator('root', ctId, undefined, 0, OperatorType.M_OF_N, 2);
    const leafA = makeLeaf('leaf-a', ctId, 'root', 0, 'task-a');
    const leafB = makeLeaf('leaf-b', ctId, 'root', 1, 'task-b');
    const leafC = makeLeaf('leaf-c', ctId, 'root', 2, 'task-c');
    const nodes = [root, leafA, leafB, leafC];

    it('returns true when all 3 complete (threshold=2)', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', {
          'task-a': true,
          'task-b': true,
          'task-c': true,
        }, {})
      ).toBe(true);
    });

    it('returns true when exactly threshold (2) complete', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', {
          'task-a': true,
          'task-b': true,
          'task-c': false,
        }, {})
      ).toBe(true);
    });

    it('returns false when only 1 of 3 complete (threshold=2)', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', {
          'task-a': true,
          'task-b': false,
          'task-c': false,
        }, {})
      ).toBe(false);
    });

    it('returns false when none complete', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', {
          'task-a': false,
          'task-b': false,
          'task-c': false,
        }, {})
      ).toBe(false);
    });
  });

  describe('nested tree: (A OR B) AND (2-of-3: C, D, E)', () => {
    const ctId = 'ct-nested';
    // Root AND
    const root = makeOperator('root', ctId, undefined, 0, OperatorType.AND);
    // Left child: OR
    const orNode = makeOperator('or-node', ctId, 'root', 0, OperatorType.OR);
    const leafA = makeLeaf('leaf-a', ctId, 'or-node', 0, 'task-a');
    const leafB = makeLeaf('leaf-b', ctId, 'or-node', 1, 'task-b');
    // Right child: M_OF_N(2)
    const monNode = makeOperator('mon-node', ctId, 'root', 1, OperatorType.M_OF_N, 2);
    const leafC = makeLeaf('leaf-c', ctId, 'mon-node', 0, 'task-c');
    const leafD = makeLeaf('leaf-d', ctId, 'mon-node', 1, 'task-d');
    const leafE = makeLeaf('leaf-e', ctId, 'mon-node', 2, 'task-e');
    const nodes = [root, orNode, leafA, leafB, monNode, leafC, leafD, leafE];

    it('returns true when OR branch and M_OF_N branch both pass', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', {
          'task-a': true,
          'task-b': false,
          'task-c': true,
          'task-d': true,
          'task-e': false,
        }, {})
      ).toBe(true);
    });

    it('returns false when OR branch fails', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', {
          'task-a': false,
          'task-b': false,
          'task-c': true,
          'task-d': true,
          'task-e': true,
        }, {})
      ).toBe(false);
    });

    it('returns false when M_OF_N branch fails (only 1 of 3)', () => {
      expect(
        evaluateCompositeTree(nodes, 'root', {
          'task-a': true,
          'task-b': false,
          'task-c': true,
          'task-d': false,
          'task-e': false,
        }, {})
      ).toBe(false);
    });
  });

  describe('edge cases', () => {
    it('treats unknown taskId as incomplete', () => {
      const ctId = 'ct-edge';
      const root = makeLeaf('root', ctId, undefined, 0, 'task-unknown');
      expect(evaluateCompositeTree([root], 'root', {}, {})).toBe(false);
    });

    it('ignores deleted nodes', () => {
      const ctId = 'ct-del';
      const root = makeOperator('root', ctId, undefined, 0, OperatorType.AND);
      const leaf = makeLeaf('leaf', ctId, 'root', 0, 'task-a');
      const deletedLeaf: CompositeNode = {
        ...makeLeaf('deleted-leaf', ctId, 'root', 1, 'task-b'),
        isDeleted: true,
      };
      // Only leaf 'task-a' is visible; deleted leaf doesn't count as a child
      expect(
        evaluateCompositeTree([root, leaf, deletedLeaf], 'root', {
          'task-a': true,
          'task-b': false,
        }, {})
      ).toBe(true);
    });

    it('vacuous AND (operator with no children) returns true', () => {
      const ctId = 'ct-vac';
      const root = makeOperator('root', ctId, undefined, 0, OperatorType.AND);
      expect(evaluateCompositeTree([root], 'root', {}, {})).toBe(true);
    });

    it('empty OR returns false', () => {
      const ctId = 'ct-empty-or';
      const root = makeOperator('root', ctId, undefined, 0, OperatorType.OR);
      expect(evaluateCompositeTree([root], 'root', {}, {})).toBe(false);
    });

    it('throws when root node not found', () => {
      expect(() =>
        evaluateCompositeTree([], 'nonexistent-root', {}, {})
      ).toThrow('Root node "nonexistent-root" not found');
    });
  });

  describe('compositeCompletions parameter', () => {
    const ctId = 'ct-comp';

    it('leaf with childCompositeTaskId returns true when composite is complete', () => {
      const root = makeCompositeLeaf('root', ctId, undefined, 0, 'comp-a');
      expect(evaluateCompositeTree([root], 'root', {}, { 'comp-a': true })).toBe(true);
    });

    it('leaf with childCompositeTaskId returns false when composite is incomplete', () => {
      const root = makeCompositeLeaf('root', ctId, undefined, 0, 'comp-a');
      expect(evaluateCompositeTree([root], 'root', {}, { 'comp-a': false })).toBe(false);
    });

    it('leaf with childCompositeTaskId returns false when id not in compositeCompletions map', () => {
      const root = makeCompositeLeaf('root', ctId, undefined, 0, 'comp-unknown');
      expect(evaluateCompositeTree([root], 'root', {}, {})).toBe(false);
    });

    it('AND operator: all children are composite refs, all complete → true', () => {
      const root = makeOperator('root', ctId, undefined, 0, OperatorType.AND);
      const leafA = makeCompositeLeaf('leaf-a', ctId, 'root', 0, 'comp-a');
      const leafB = makeCompositeLeaf('leaf-b', ctId, 'root', 1, 'comp-b');
      expect(
        evaluateCompositeTree([root, leafA, leafB], 'root', {}, { 'comp-a': true, 'comp-b': true })
      ).toBe(true);
    });

    it('OR operator: one composite ref complete → true', () => {
      const root = makeOperator('root', ctId, undefined, 0, OperatorType.OR);
      const leafA = makeCompositeLeaf('leaf-a', ctId, 'root', 0, 'comp-a');
      const leafB = makeCompositeLeaf('leaf-b', ctId, 'root', 1, 'comp-b');
      expect(
        evaluateCompositeTree([root, leafA, leafB], 'root', {}, { 'comp-a': false, 'comp-b': true })
      ).toBe(true);
    });

    it('M_OF_N operator: threshold composite refs complete → true', () => {
      const root = makeOperator('root', ctId, undefined, 0, OperatorType.M_OF_N, 2);
      const leafA = makeCompositeLeaf('leaf-a', ctId, 'root', 0, 'comp-a');
      const leafB = makeCompositeLeaf('leaf-b', ctId, 'root', 1, 'comp-b');
      const leafC = makeCompositeLeaf('leaf-c', ctId, 'root', 2, 'comp-c');
      expect(
        evaluateCompositeTree(
          [root, leafA, leafB, leafC],
          'root',
          {},
          { 'comp-a': true, 'comp-b': true, 'comp-c': false }
        )
      ).toBe(true);
    });

    it('mixed: taskId leaf + childCompositeTaskId leaf in same AND operator, both complete → true', () => {
      const root = makeOperator('root', ctId, undefined, 0, OperatorType.AND);
      const taskLeaf = makeLeaf('leaf-task', ctId, 'root', 0, 'task-a');
      const compLeaf = makeCompositeLeaf('leaf-comp', ctId, 'root', 1, 'comp-a');
      expect(
        evaluateCompositeTree(
          [root, taskLeaf, compLeaf],
          'root',
          { 'task-a': true },
          { 'comp-a': true }
        )
      ).toBe(true);
    });

    it('leaf with neither taskId nor childCompositeTaskId returns false', () => {
      const emptyLeaf: CompositeNode = {
        id: 'root',
        compositeTaskId: ctId,
        parentNodeId: undefined,
        nodeIndex: 0,
        nodeType: 'leaf',
        createdAt: '2024-01-01T00:00:00.000Z',
        updatedAt: '2024-01-01T00:00:00.000Z',
        version: 1,
        isDeleted: false,
      };
      expect(evaluateCompositeTree([emptyLeaf], 'root', {}, {})).toBe(false);
    });
  });
});
