import * as fs from 'fs';
import * as path from 'path';
import { TaskType } from '../../src/constants/enums';
import type { AnonymisedWorkspace } from '../../src/algorithms/workspaceAnonymiser';

/**
 * TASK_WINDOW_REWORK slice 5 acceptance — the owner's anonymised workspace
 * (web Developer "Export anonymised workspace", exported after a clean pull
 * from a device that had run the slice-4 sweep; committed as
 * `tests/fixtures/owner/workspace.anonymised.json` — outside the iOS-mirrored top level). Over it the slice-4 sweep
 * planned 0 repoints, 0 strips and 0 orphans — the gate for deleting the
 * sweep. This pins the end state: no live row carries the legacy marks.
 */
const FIXTURE = path.join(__dirname, '../fixtures/owner/workspace.anonymised.json');

describe('owner workspace fixture (slice 5)', () => {
  const ws: AnonymisedWorkspace = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  const live = ws.tasks.filter((t) => !t.isDeleted);

  it('carries a real workspace', () => {
    expect(live.length).toBeGreaterThan(0);
    expect(ws.boards.length).toBeGreaterThan(0);
  });

  it('has no live per-window derived row left (counter or compound)', () => {
    // The three marks of a legacy derived counter, the two of a compound.
    const marked = live.filter(
      (t) =>
        t.startDate != null &&
        t.createdInWizard === true &&
        ((t.type === TaskType.COUNTING && t.sharedCounterId != null) || t.type === TaskType.COMPOUND),
    );
    expect(marked.map((t) => t.id)).toEqual([]);
  });

});
