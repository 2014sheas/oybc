import {
  progressTaskToCompound,
  taskStepToCompoundChild,
  compositeTaskToTask,
  compositeNodeToCompoundChild,
  backfillTaskCompletion,
  collectEverCompletedStepIds,
  shouldBackfillStepLinkedTaskAsComplete,
  migrationDefaultPoolToPoolId,
  migrationDefaultPoolToCoreBoardDefaultId,
  migrationTemplateToPoolId,
} from '../../src/algorithms/migrationHelpers';
import type { LegacyBoardTaskCompletion } from '../../src/algorithms/migrationHelpers';
import { OperatorType, TaskType } from '../../src/constants/enums';
import type { TaskStep } from '../../src/types/task';
import type { CompositeTask, CompositeNode } from '../../src/types/compositeTask';

// ─── Helpers ──────────────────────────────────────────────────────────────────

const NOW = '2026-04-23T00:00:00.000Z';
const EARLIER = '2026-01-01T00:00:00.000Z';
const EARLIEST = '2025-12-01T00:00:00.000Z';

function makeStep(overrides: Partial<TaskStep> = {}): TaskStep {
  return {
    id: 'step-1',
    taskId: 'task-1',
    stepIndex: 0,
    title: 'Do something',
    type: TaskType.NORMAL,
    linkedTaskId: 'linked-task-1',
    createdAt: NOW,
    updatedAt: NOW,
    version: 3,
    isDeleted: false,
    ...overrides,
  };
}

function makeCompositeTask(overrides: Partial<CompositeTask> = {}): CompositeTask {
  return {
    id: 'composite-1',
    userId: 'user-1',
    title: 'Composite Task',
    description: 'A composite',
    rootNodeId: 'root-node-1',
    createdAt: NOW,
    updatedAt: NOW,
    version: 2,
    isDeleted: false,
    ...overrides,
  };
}

function makeOperatorNode(overrides: Partial<CompositeNode> = {}): CompositeNode {
  return {
    id: 'node-root',
    compositeTaskId: 'composite-1',
    nodeIndex: 0,
    nodeType: 'operator',
    operatorType: OperatorType.AND,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function makeLeafNode(overrides: Partial<CompositeNode> = {}): CompositeNode {
  return {
    id: 'node-leaf-1',
    compositeTaskId: 'composite-1',
    nodeIndex: 0,
    nodeType: 'leaf',
    taskId: 'task-leaf-1',
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function makeLegacyRow(overrides: Partial<LegacyBoardTaskCompletion> = {}): LegacyBoardTaskCompletion {
  return {
    taskId: 'task-1',
    isCompleted: false,
    ...overrides,
  };
}

// ─── progressTaskToCompound ───────────────────────────────────────────────────

describe('progressTaskToCompound', () => {
  it('returns type=COMPOUND, operator=AND', () => {
    const result = progressTaskToCompound();
    expect(result.type).toBe(TaskType.COMPOUND);
    expect(result.operator).toBe(OperatorType.AND);
  });

  it('does not include threshold', () => {
    const result = progressTaskToCompound();
    expect(result).not.toHaveProperty('threshold');
  });
});

// ─── taskStepToCompoundChild ──────────────────────────────────────────────────

describe('taskStepToCompoundChild', () => {
  it('returns a CompoundChild with correct field mappings', () => {
    const step = makeStep({ taskId: 'parent-task', linkedTaskId: 'child-task', stepIndex: 2 });
    const result = taskStepToCompoundChild(step, 'new-child-id');
    expect(result).not.toBeNull();
    expect(result!.id).toBe('new-child-id');
    expect(result!.compoundTaskId).toBe('parent-task');
    expect(result!.childTaskId).toBe('child-task');
    expect(result!.childIndex).toBe(2);
  });

  it('returns null when step.linkedTaskId is undefined', () => {
    const step = makeStep({ linkedTaskId: undefined });
    const result = taskStepToCompoundChild(step, 'new-id');
    expect(result).toBeNull();
  });

  it('preserves createdAt, updatedAt, isDeleted, deletedAt', () => {
    const step = makeStep({
      createdAt: EARLIER,
      updatedAt: NOW,
      isDeleted: true,
      deletedAt: NOW,
    });
    const result = taskStepToCompoundChild(step, 'new-id');
    expect(result).not.toBeNull();
    expect(result!.createdAt).toBe(EARLIER);
    expect(result!.updatedAt).toBe(NOW);
    expect(result!.isDeleted).toBe(true);
    expect(result!.deletedAt).toBe(NOW);
  });

  it('sets version=1 even when legacy step had a higher version', () => {
    const step = makeStep({ version: 7 });
    const result = taskStepToCompoundChild(step, 'new-id');
    expect(result).not.toBeNull();
    expect(result!.version).toBe(1);
  });
});

// ─── compositeTaskToTask ──────────────────────────────────────────────────────

describe('compositeTaskToTask', () => {
  it('AND root → Task with operator=AND, no threshold', () => {
    const ct = makeCompositeTask();
    const root = makeOperatorNode({ operatorType: OperatorType.AND });
    const result = compositeTaskToTask(ct, root);
    expect(result).not.toBeNull();
    expect(result!.operator).toBe(OperatorType.AND);
    expect(result!.threshold).toBeUndefined();
  });

  it('M_OF_N root with threshold=2 → Task with operator=M_OF_N, threshold=2', () => {
    const ct = makeCompositeTask();
    const root = makeOperatorNode({ operatorType: OperatorType.M_OF_N, threshold: 2 });
    const result = compositeTaskToTask(ct, root);
    expect(result).not.toBeNull();
    expect(result!.operator).toBe(OperatorType.M_OF_N);
    expect(result!.threshold).toBe(2);
  });

  it('OR root → Task with operator=OR, no threshold', () => {
    const ct = makeCompositeTask();
    const root = makeOperatorNode({ operatorType: OperatorType.OR });
    const result = compositeTaskToTask(ct, root);
    expect(result).not.toBeNull();
    expect(result!.operator).toBe(OperatorType.OR);
    expect(result!.threshold).toBeUndefined();
  });

  it('preserves id, userId, title, description, timestamps, version, isDeleted', () => {
    const ct = makeCompositeTask({
      id: 'comp-123',
      userId: 'user-xyz',
      title: 'My Composite',
      description: 'desc',
      createdAt: EARLIER,
      updatedAt: NOW,
      version: 5,
      isDeleted: true,
      deletedAt: NOW,
    });
    const root = makeOperatorNode({ operatorType: OperatorType.AND });
    const result = compositeTaskToTask(ct, root);
    expect(result).not.toBeNull();
    expect(result!.id).toBe('comp-123');
    expect(result!.userId).toBe('user-xyz');
    expect(result!.title).toBe('My Composite');
    expect(result!.description).toBe('desc');
    expect(result!.createdAt).toBe(EARLIER);
    expect(result!.updatedAt).toBe(NOW);
    expect(result!.version).toBe(5);
    expect(result!.isDeleted).toBe(true);
    expect(result!.deletedAt).toBe(NOW);
  });

  it('returns null when rootOperatorNode is undefined', () => {
    const ct = makeCompositeTask();
    const result = compositeTaskToTask(ct, undefined);
    expect(result).toBeNull();
  });

  it('returns null when rootOperatorNode.nodeType is leaf', () => {
    const ct = makeCompositeTask();
    const leafNode = makeLeafNode();
    const result = compositeTaskToTask(ct, leafNode);
    expect(result).toBeNull();
  });

  it('returns null when rootOperatorNode.operatorType is undefined', () => {
    const ct = makeCompositeTask();
    const root = makeOperatorNode({ operatorType: undefined });
    const result = compositeTaskToTask(ct, root);
    expect(result).toBeNull();
  });

  it('sets type=COMPOUND and isCompleted=false', () => {
    const ct = makeCompositeTask();
    const root = makeOperatorNode({ operatorType: OperatorType.AND });
    const result = compositeTaskToTask(ct, root);
    expect(result).not.toBeNull();
    expect(result!.type).toBe(TaskType.COMPOUND);
    expect(result!.isCompleted).toBe(false);
  });
});

// ─── compositeNodeToCompoundChild ────────────────────────────────────────────

describe('compositeNodeToCompoundChild', () => {
  it('leaf with taskId → CompoundChild with childTaskId=node.taskId, childIndex=node.nodeIndex', () => {
    const node = makeLeafNode({ taskId: 'task-abc', nodeIndex: 3 });
    const result = compositeNodeToCompoundChild(node, 'new-id');
    expect(result).not.toBeNull();
    expect(result!.childTaskId).toBe('task-abc');
    expect(result!.childIndex).toBe(3);
    expect(result!.id).toBe('new-id');
    expect(result!.compoundTaskId).toBe('composite-1');
  });

  it('leaf with childCompositeTaskId (no taskId) → CompoundChild with childTaskId=childCompositeTaskId', () => {
    const node = makeLeafNode({ taskId: undefined, childCompositeTaskId: 'nested-comp-1' });
    const result = compositeNodeToCompoundChild(node, 'new-id');
    expect(result).not.toBeNull();
    expect(result!.childTaskId).toBe('nested-comp-1');
  });

  it('operator node → returns null', () => {
    const node = makeOperatorNode();
    const result = compositeNodeToCompoundChild(node, 'new-id');
    expect(result).toBeNull();
  });

  it('leaf with neither taskId nor childCompositeTaskId → returns null', () => {
    const node = makeLeafNode({ taskId: undefined, childCompositeTaskId: undefined });
    const result = compositeNodeToCompoundChild(node, 'new-id');
    expect(result).toBeNull();
  });
});

// ─── backfillTaskCompletion ───────────────────────────────────────────────────

describe('backfillTaskCompletion', () => {
  it('empty input → isCompleted=false, no completedAt, no currentCount', () => {
    const result = backfillTaskCompletion([]);
    expect(result.isCompleted).toBe(false);
    expect(result.completedAt).toBeUndefined();
    expect(result.currentCount).toBeUndefined();
  });

  it('single complete row → isCompleted=true, completedAt from that row', () => {
    const rows = [makeLegacyRow({ isCompleted: true, completedAt: NOW })];
    const result = backfillTaskCompletion(rows);
    expect(result.isCompleted).toBe(true);
    expect(result.completedAt).toBe(NOW);
  });

  it('mixed rows: one complete (older), one incomplete (newer) → isCompleted=true, completedAt from complete row', () => {
    const rows = [
      makeLegacyRow({ isCompleted: true, completedAt: EARLIER }),
      makeLegacyRow({ isCompleted: false, completedAt: NOW }),
    ];
    const result = backfillTaskCompletion(rows);
    expect(result.isCompleted).toBe(true);
    expect(result.completedAt).toBe(EARLIER);
  });

  it('multiple complete rows → completedAt is the latest', () => {
    // Under the global completion model, `Task.completedAt` reads as "when
    // this task became globally complete" — the most recent completion
    // anchors that semantic, especially for re-completed tasks.
    const rows = [
      makeLegacyRow({ isCompleted: true, completedAt: NOW }),
      makeLegacyRow({ isCompleted: true, completedAt: EARLIEST }),
      makeLegacyRow({ isCompleted: true, completedAt: EARLIER }),
    ];
    const result = backfillTaskCompletion(rows);
    expect(result.completedAt).toBe(NOW);
  });

  it('mixed currentCount values → returns the max', () => {
    const rows = [
      makeLegacyRow({ currentCount: 5 }),
      makeLegacyRow({ currentCount: 12 }),
      makeLegacyRow({ currentCount: 3 }),
    ];
    const result = backfillTaskCompletion(rows);
    expect(result.currentCount).toBe(12);
  });

  it('isCompleted=true on row without completedAt still sets isCompleted but not completedAt', () => {
    const rows = [makeLegacyRow({ isCompleted: true, completedAt: undefined })];
    const result = backfillTaskCompletion(rows);
    expect(result.isCompleted).toBe(true);
    expect(result.completedAt).toBeUndefined();
  });

  it('no rows have currentCount → currentCount is undefined', () => {
    const rows = [
      makeLegacyRow({ isCompleted: true, completedAt: NOW }),
      makeLegacyRow({ isCompleted: false }),
    ];
    const result = backfillTaskCompletion(rows);
    expect(result.currentCount).toBeUndefined();
  });
});

// ─── collectEverCompletedStepIds ─────────────────────────────────────────────

describe('collectEverCompletedStepIds', () => {
  it('returns the union of all completedStepIds arrays', () => {
    const rows = [
      makeLegacyRow({ completedStepIds: ['step-a', 'step-b'] }),
      makeLegacyRow({ completedStepIds: ['step-b', 'step-c'] }),
    ];
    const result = collectEverCompletedStepIds(rows);
    expect(result).toEqual(new Set(['step-a', 'step-b', 'step-c']));
  });

  it('empty input → empty Set', () => {
    const result = collectEverCompletedStepIds([]);
    expect(result.size).toBe(0);
  });

  it('skips rows where completedStepIds is undefined', () => {
    const rows = [
      makeLegacyRow({ completedStepIds: undefined }),
      makeLegacyRow({ completedStepIds: ['step-x'] }),
    ];
    const result = collectEverCompletedStepIds(rows);
    expect(result).toEqual(new Set(['step-x']));
  });
});

// ─── shouldBackfillStepLinkedTaskAsComplete ───────────────────────────────────

describe('shouldBackfillStepLinkedTaskAsComplete', () => {
  it('returns true when step.id is in the set', () => {
    const step = makeStep({ id: 'step-1' });
    const set = new Set(['step-1', 'step-2']);
    expect(shouldBackfillStepLinkedTaskAsComplete(step, set)).toBe(true);
  });

  it('returns false when step.id is not in the set', () => {
    const step = makeStep({ id: 'step-99' });
    const set = new Set(['step-1', 'step-2']);
    expect(shouldBackfillStepLinkedTaskAsComplete(step, set)).toBe(false);
  });
});

// ─── P1 migration mint ids (review finding C2) ────────────────────────────
//
// docs/POOLS_RECURRING.md §Migration. These must be pure + deterministic:
// same source id in → same minted id out, every time, on every platform.

describe('migrationDefaultPoolToPoolId / migrationDefaultPoolToCoreBoardDefaultId / migrationTemplateToPoolId', () => {
  it('is deterministic — same source id always derives the same minted id', () => {
    expect(migrationDefaultPoolToPoolId('dp-1')).toBe(migrationDefaultPoolToPoolId('dp-1'));
    expect(migrationDefaultPoolToCoreBoardDefaultId('dp-1')).toBe(
      migrationDefaultPoolToCoreBoardDefaultId('dp-1'),
    );
    expect(migrationTemplateToPoolId('tmpl-1')).toBe(migrationTemplateToPoolId('tmpl-1'));
  });

  it('the three mint sites never collide with each other for the same source id', () => {
    const poolId = migrationDefaultPoolToPoolId('shared-id');
    const coreDefaultId = migrationDefaultPoolToCoreBoardDefaultId('shared-id');
    const templatePoolId = migrationTemplateToPoolId('shared-id');
    expect(new Set([poolId, coreDefaultId, templatePoolId]).size).toBe(3);
  });

  it('different source ids derive different minted ids', () => {
    expect(migrationDefaultPoolToPoolId('dp-a')).not.toBe(migrationDefaultPoolToPoolId('dp-b'));
  });

  // Cross-platform pin: this exact literal is asserted BYTE-IDENTICAL in the
  // iOS XCTest suite (`OYBCTests/PoolsCoreBoardDefaultsMigrationTests.swift`,
  // `test_deterministicMintIds_matchCrossPlatformFixture`) AND in the web
  // Vitest suite (`apps/web/src/db/operations/__tests__/migrationV16.test.ts`,
  // "derives the exact fixture id..."). If this literal ever needs to
  // change, update all three in the same PR — the whole point of uuidv5
  // here is that both platforms derive the identical id from the identical
  // source id, given byte-identical namespace strings.
  it('derives the exact fixture ids for the locked cross-platform vector', () => {
    expect(migrationDefaultPoolToPoolId('dp-fixture-1')).toBe(
      'e1105aeb-04bc-58ca-936c-be32ea86437b',
    );
    expect(migrationDefaultPoolToCoreBoardDefaultId('dp-fixture-1')).toBe(
      '94e67c0c-b1d1-50f6-90ab-6cedf9e60efc',
    );
    expect(migrationTemplateToPoolId('tmpl-fixture-1')).toBe(
      'f11ff2bb-283e-5867-8348-253dc1fe46db',
    );
  });
});
