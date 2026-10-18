import * as fs from 'fs';
import * as path from 'path';
import { planPlacementSweep } from '../../src/algorithms/placementSweep';
import type { AnonymisedWorkspace } from '../../src/algorithms/workspaceAnonymiser';

/**
 * TASK_WINDOW_REWORK slice 4 acceptance — the owner's anonymised workspace
 * (produced by the web Developer "Export anonymised workspace" action and
 * committed as `tests/fixtures/ownerWorkspace.anonymised.json`). Skipped
 * until the file exists. No sealed board's kernel re-derivation may change
 * across the sweep: a sealed board refused for `derivationChanged` fails it.
 */
const FIXTURE = path.join(__dirname, '../fixtures/ownerWorkspace.anonymised.json');
const present = fs.existsSync(FIXTURE);

(present ? describe : describe.skip)('placement sweep over the owner fixture', () => {
  // `describe.skip` still evaluates this body, so the read is lazy.
  const load = (): { ws: AnonymisedWorkspace; plan: ReturnType<typeof planPlacementSweep> } => {
    const ws: AnonymisedWorkspace = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
    return { ws, plan: planPlacementSweep(ws, '2026-10-18T00:00:00.000Z') };
  };

  it('repoints or settles every marked row without changing a sealed board', () => {
    const { ws, plan } = load();
    const sealedIds = new Set(ws.boards.filter((b) => b.sealedAt != null).map((b) => b.id));
    const sealedRefused = plan.outcomes.filter((o) => sealedIds.has(o.boardId) && o.reason === 'derivationChanged');
    expect(sealedRefused).toEqual([]);
  });

  it('prints a summary', () => {
    const { plan } = load();
    const refused = plan.outcomes.filter((o) => o.outcome === 'refused');
    // eslint-disable-next-line no-console
    console.log(
      `sweep over owner fixture: ${plan.repoints.length} repoints on ${plan.touchedBoardIds.length} boards, ` +
        `${refused.length} refused (${refused.map((o) => o.reason).join(', ')}), ${plan.strips.length} strips, ` +
        `${plan.orphanTombstones.length} orphans, drift on ${plan.outcomes.filter((o) => o.sealedSnapshotDrift).length} sealed boards`,
    );
  });
});
