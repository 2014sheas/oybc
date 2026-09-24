import {
  buildCounterFamilyMap,
  CenterSquareType,
  TaskType,
  type Board,
  type CompoundChild,
  type Pool,
  type Task,
} from '@oybc/shared';
import { fetchBoardSourceSupply } from '../../db/operations/boardSources';
import { fetchCompoundChildrenByCompoundIds } from '../../db/operations/compoundChildren';
import { fetchPoolsByIds } from '../../db/operations/pools';
import { fetchTasksByIds } from '../../db/operations/tasks';
import { decodeRecurringDraftMix } from '../../db/recurringDraftMix';
import { buildSupplyInfoMap, sourceCapacity, type SupplyInfoMap } from './wizardSources';
import { boardSupplyEntry } from './wizardSourcesLogic';

/**
 * The saved draft's honest pool size — the SAME number the wizard's
 * header and Step-2 gate show once this draft is reopened (2026-09 audit
 * T2, docs/BOARD_SOURCES.md §Selection step 3).
 *
 * Reads the blob's canonical `sources` (+ `manualTaskIds`) — never the
 * retired pool-mix mirror (`poolIds`/`removedTaskIds`), which drops
 * board-kind sources and every min/max range. A v1 blob with no `sources`
 * is already mapped forward by `decodeRecurringDraftMix`
 * (`sourcesFromMixFields`, the `[0, all]` rule), so no legacy branch is
 * needed here.
 *
 * Supplies resolve through the wizard's own resolvers: pools via
 * `buildSupplyInfoMap`, boards via `fetchBoardSourceSupply` (series-binding
 * aware) → `boardSupplyEntry`; the count is `sourceCapacity` — the
 * `computeAchievablePoolSize` dry-run with excludes, the `'todo'` filter,
 * Split-up expansion, counter-family exclusivity and the chosen center
 * pinned, exactly as `useWizardDerived.capacity` computes it.
 *
 * Every read goes through Dexie, so a `useLiveQuery` wrapper re-runs it
 * when any of the underlying rows change.
 *
 * iOS twin: `BoardWizardViewModel.resolveDraftCapacity`.
 *
 * @param board - The draft board; only its blob and center fields are read.
 * @returns The achievable pool size (0 for an empty/malformed blob).
 */
export async function resolveDraftCapacity(
  board: Pick<Board, 'recurringDraftMix' | 'centerSquareType' | 'centerTaskId'>,
): Promise<number> {
  const mix = decodeRecurringDraftMix(board.recurringDraftMix);
  const sources = mix.sources;
  const manualTaskIds = new Set(mix.manualTaskIds);

  const poolIds = sources.filter((s) => s.kind === 'pool').map((s) => s.sourceId);
  const pools: Pool[] = await fetchPoolsByIds(poolIds);
  const poolsById: Record<string, Pool> = Object.fromEntries(pools.map((p) => [p.id, p]));

  const boardSupplyById: SupplyInfoMap = {};
  for (const source of sources) {
    if (source.kind !== 'board') continue;
    boardSupplyById[source.sourceId] = boardSupplyEntry(
      await fetchBoardSourceSupply(source.sourceId),
    );
  }

  const referencedIds = new Set<string>(manualTaskIds);
  for (const p of pools) for (const id of p.taskIds) referencedIds.add(id);
  for (const info of Object.values(boardSupplyById)) {
    for (const id of info.rawSupplyTaskIds) referencedIds.add(id);
  }
  const tasksById: Record<string, Task> = {};
  if (referencedIds.size > 0) {
    for (const t of await fetchTasksByIds([...referencedIds])) tasksById[t.id] = t;
  }

  const supplyInfo = buildSupplyInfoMap(sources, poolsById, true, tasksById, boardSupplyById);

  // §Member rules (B3, RC7) — a Split-up member counts as its parts, so the
  // expansion needs every supplied COMPOUND's live links (and the parts'
  // rows, so a counting part joins the counter-family map).
  const compoundIds = new Set<string>();
  for (const info of Object.values(supplyInfo)) {
    for (const id of info.rawSupplyTaskIds) {
      if (tasksById[id]?.type === TaskType.COMPOUND) compoundIds.add(id);
    }
  }
  const childrenByCompoundId: Record<string, CompoundChild[]> = {};
  if (compoundIds.size > 0) {
    const partIds = new Set<string>();
    for (const link of await fetchCompoundChildrenByCompoundIds([...compoundIds])) {
      (childrenByCompoundId[link.compoundTaskId] ??= []).push(link);
      if (tasksById[link.childTaskId] === undefined) partIds.add(link.childTaskId);
    }
    if (partIds.size > 0) {
      for (const t of await fetchTasksByIds([...partIds])) tasksById[t.id] = t;
    }
  }

  const pinnedTaskId =
    board.centerSquareType === CenterSquareType.CHOSEN ? board.centerTaskId : undefined;
  return sourceCapacity(
    sources,
    supplyInfo,
    manualTaskIds,
    buildCounterFamilyMap(Object.values(tasksById)),
    pinnedTaskId,
    childrenByCompoundId,
    tasksById,
  );
}
