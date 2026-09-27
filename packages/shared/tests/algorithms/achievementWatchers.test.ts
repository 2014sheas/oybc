import * as fs from 'fs';
import * as path from 'path';
import {
  findWatcherTaskIds,
  type WatcherTaskFields,
  type WatchedBoardFields,
} from '../../src/algorithms/achievementWatchers';
import { TaskType } from '../../src/constants/enums';

/**
 * achievementWatchers.test.ts — Board Edit redesign slice 4 (D8 / owner ruling
 * R3). Fixture-driven from `tests/fixtures/achievementWatcherVectors.json`, the
 * SAME file iOS `AchievementWatcherVectorTests.swift` runs through the Swift
 * twin.
 */

interface VectorTask {
  id: string;
  type: string;
  isDeleted: boolean;
  referencedBoardId: string | null;
  referencedTemplateId: string | null;
}
interface WatcherVector {
  name: string;
  tasks: VectorTask[];
  changedBoards: Array<{ id: string; spawnedFromTemplateId: string | null }>;
  expectedTaskIds: string[];
}

const vectors = (
  JSON.parse(
    fs.readFileSync(path.join(__dirname, '../fixtures/achievementWatcherVectors.json'), 'utf8'),
  ) as { vectors: WatcherVector[] }
).vectors;

function toTask(t: VectorTask): WatcherTaskFields {
  return {
    id: t.id,
    type: t.type as TaskType,
    isDeleted: t.isDeleted,
    referencedBoardId: t.referencedBoardId ?? undefined,
    referencedTemplateId: t.referencedTemplateId ?? undefined,
  };
}

function toBoard(b: { id: string; spawnedFromTemplateId: string | null }): WatchedBoardFields {
  return { id: b.id, spawnedFromTemplateId: b.spawnedFromTemplateId ?? undefined };
}

describe('findWatcherTaskIds (achievementWatcherVectors.json)', () => {
  it('fixture is present and non-trivial', () => {
    expect(vectors.length).toBeGreaterThanOrEqual(6);
  });

  for (const v of vectors) {
    it(v.name, () => {
      expect(findWatcherTaskIds(v.tasks.map(toTask), v.changedBoards.map(toBoard))).toEqual(
        v.expectedTaskIds,
      );
    });
  }

  it('a board with no template provenance cannot match a template watcher', () => {
    const tasks: WatcherTaskFields[] = [
      { id: 'w', type: TaskType.ACHIEVEMENT, isDeleted: false, referencedTemplateId: 'tpl' },
    ];
    expect(findWatcherTaskIds(tasks, [{ id: 'b' }])).toEqual([]);
  });
});
