import { afterEach, describe, expect, it } from 'vitest';
import { db } from '../../internal';
import { exportAnonymisedWorkspace } from '../workspaceExport';
import { JUNE, ROOT, USER, boardRow, clearAll, placement, rootTask } from './linkedCounterFixtures';

afterEach(clearAll);

describe('exportAnonymisedWorkspace', () => {
  it('keeps ids and drops every original title / name', async () => {
    await db.tasks.put(rootTask({ title: 'Secret marathon plan', action: 'Sprint', unit: 'furlongs' }));
    await db.boards.put(boardRow(JUNE, { name: 'My private June board' }));
    await db.boardTasks.put(placement('bt1', JUNE.id, ROOT));
    const ws = await exportAnonymisedWorkspace(USER);
    const json = JSON.stringify(ws);
    for (const secret of ['Secret marathon plan', 'Sprint', 'furlongs', 'My private June board']) {
      expect(json).not.toContain(secret);
    }
    expect(ws.tasks.map((t) => t.id)).toEqual([ROOT]);
    expect(ws.boards.map((b) => b.id)).toEqual([JUNE.id]);
    expect(ws.boardTasks.map((b) => b.id)).toEqual(['bt1']);
  });
});
