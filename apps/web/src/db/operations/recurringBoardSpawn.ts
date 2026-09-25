import { db } from '../internal';
import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  buildCounterFamilyMap,
  buildSpawnPlacement,
  validateSpawnPool,
  computeBoardStatsUpdate,
  fillableCellCount,
  poolSourceSupplyById,
  availableSupplyIds,
  applyMemberRules,
  resolveSourceAvailable,
  selectBoardTasks,
  sourcesForRecord,
  type Board,
  type BoardSource,
  type BoardWindow,
  type BoardTask,
  type CompoundChild,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
  type TaskEvent,
  type PendingTemplateSpawn,
  type SpawnPoolFailureReason,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { resolveBoardSourceSupply, resolveOpenSourceBoard } from './boardSources';
import { candidateRootIds, planAndMintDerivedRows } from './derivedCounters';

/**
 * Recurring-board spawn (Phase 6.2).
 *
 * Atomically creates a Board + BoardTasks from a `PendingTemplateSpawn`,
 * and updates the template's `lastSpawnedWindowKey` in the same Dexie
 * transaction. If the multi-step write fails partway, the entire
 * transaction rolls back — the next Boards-tab open will retry.
 *
 * Multi-device race: two devices each open the Boards tab before sync
 * settles → both spawn the same window. Two boards land in Firestore
 * with different UUIDs but matching `spawnedFromTemplateId + startDate`.
 * Phase 6.2 MVP accepts this; user deletes the duplicate. Single-device
 * idempotency is structurally guaranteed by the
 * `findTemplatesPendingSpawn` belt (lastSpawnedWindowKey check + existing
 * Board scan).
 */

export type SpawnResult =
  | {
      ok: true;
      boardId: string;
      templateId: string;
      windowStart: string;
      /**
       * Board-kind source ids that resolved to NO board for this window
       * (owner ruling 2026-09-24 — a series with no instance containing the
       * window start, or an ended/sealed one-off). They dealt nothing; the
       * board's spawn-provenance note says "No board for this window yet".
       */
      noBoardForWindowSourceIds: string[];
    }
  | {
      ok: false;
      templateId: string;
      reason:
        | SpawnPoolFailureReason
        | 'no_pool_tasks_resolved'
        | 'spawn_failed'
        | 'source_board_missing';
    };

/**
 * Spawn one board from a pending-spawn descriptor.
 *
 * @param spawn - From `findTemplatesPendingSpawn`. Carries the template +
 *                window boundaries.
 * @param options.now - The instant a board source's "is it open" is judged
 *   against (owner ruling 2026-09-24: sources are open boards). Defaults to
 *   the wall clock; tests inject it.
 * @returns The new board, or the structured skip reason.
 */
export async function spawnTemplateBoard(
  spawn: PendingTemplateSpawn,
  options: { now?: Date } = {},
): Promise<SpawnResult> {
  const sourceClock = options.now ?? new Date();
  const { template, windowStart, windowEnd, suggestedName } = spawn;

  const boardId = generateUUID();
  const now = currentTimestamp();

  // Single transaction covers task resolution + pool validation +
  // placement + writes. Folding the read inside the same txn closes
  // the soft-delete race — without `db.tasks` in the scope, sync could
  // soft-delete a seed task between the read and the writes, allowing
  // a board to spawn against stale pool data.
  //
  // Returning a non-throwing skip outcome from within the txn requires
  // a sentinel pattern (Dexie aborts a txn on thrown errors but we
  // want to commit nothing AND return the structured failure cleanly).
  // The closure resolves to a SpawnResult; abort outcomes return
  // before reaching the writes.
  return await db.transaction(
    'rw',
    [
      db.boards,
      db.boardTasks,
      db.tasks,
      db.pools,
      db.compoundChildren,
      db.taskEvents,
      db.recurringBoardTemplates,
      db.syncQueue,
    ],
    async (): Promise<SpawnResult> => {
      // Board Sources P1 (docs/BOARD_SOURCES.md) — the task source is the
      // record's SOURCES: the stamped `sources` array when present, else
      // the legacy trio derived on the fly (`sourcesForRecord` — no data
      // backfill required; rows written by old clients keep working). Pool
      // sources supply their resolvable taskIds; board sources resolve
      // through `resolveOpenSourceBoard` below. An EMPTY source contributes
      // nothing and never blocks (the design's empty-source rule).
      //
      // Single full-table reads (tasks, pools): the supply resolvers need
      // a `tasksById` map to filter each pool's OWN resolvable supply
      // (deleted tasks skipped — derived detachment), and the same
      // `allTasks`/`tasksById` are reused below for the spawn-time
      // derivation pass, so this is not an added read.
      const allTasks = await db.tasks.toArray();
      const tasksById: Record<string, Task> = {};
      for (const t of allTasks) tasksById[t.id] = t;

      const sources = sourcesForRecord(template);

      // Board Sources P3 + series binding, under the owner ruling of
      // 2026-09-24 (SOURCES ARE OPEN BOARDS): each pulled board resolves
      // through `resolveOpenSourceBoard` — the one-off itself while open, or
      // the series' instance open NOW (the same clock the wizard's live
      // supply, Preview, capacity and persist use). No open board is
      // `noWindow`: that source deals nothing and the provenance note says
      // "No board for this window yet" — the window still spawns. Only a
      // `dead` source (the stored row gone / deleted / archived, or a series
      // with no instance at all) blocks the window with the ask.
      const boardSourceIds = sources
        .filter((s) => s.kind === 'board')
        .map((s) => s.sourceId);
      const sourceBoardById = new Map<string, Board>();
      const noBoardForWindowSourceIds: string[] = [];
      for (const id of boardSourceIds) {
        const resolution = await resolveOpenSourceBoard(id, sourceClock);
        if (resolution.kind === 'dead') {
          return {
            ok: false,
            templateId: template.id,
            reason: 'source_board_missing',
          };
        }
        if (resolution.kind === 'noWindow') {
          noBoardForWindowSourceIds.push(id);
          continue;
        }
        sourceBoardById.set(id, resolution.board);
      }

      const poolSourceIds = sources
        .filter((s) => s.kind === 'pool')
        .map((s) => s.sourceId);
      const pools =
        poolSourceIds.length > 0
          ? await db.pools.where('id').anyOf(poolSourceIds).toArray()
          : [];
      const poolsById: Record<string, Pool> = {};
      for (const p of pools) poolsById[p.id] = p;

      // Full event map — the board-source 'todo' filter resolves against
      // the SOURCE board's window here, and the spawn-time derivation
      // pass reuses the same map below (one read, two consumers).
      const eventsByTaskId: Record<string, TaskEvent[]> = {};
      for (const e of await db.taskEvents.toArray()) {
        if (e.isDeleted) continue;
        (eventsByTaskId[e.taskId] ??= []).push(e);
      }

      // Compound children — read ONCE, above the supply resolution, and
      // reused by three consumers: Split-up expansion + the member-rules plan
      // below, and the spawn-time derivation pass at the bottom. (It used to
      // be read only for the derivation pass.)
      const allChildren = (await db.compoundChildren.toArray()).filter((c) => !c.isDeleted);
      const childrenByCompound: Record<string, CompoundChild[]> = {};
      for (const c of allChildren) (childrenByCompound[c.compoundTaskId] ??= []).push(c);

      // Board Sources P3/P4 — board-kind sources resolve LIVE per window
      // through the SHARED resolver (`resolveBoardSourceSupply`, also the
      // wizard's code path — the P3 lock): the source board's placed
      // squares, with the 'todo' filter dropping squares complete in THAT
      // board's window.
      const resolveBoardSupply = async (sourceBoard: Board, source: BoardSource) => {
        const rows = await db.boardTasks.where('boardId').equals(sourceBoard.id).toArray();
        const info = resolveBoardSourceSupply(sourceBoard, rows, tasksById, eventsByTaskId);
        return availableSupplyIds(source, info.supplyTaskIds, info.doneTaskIds);
      };

      const supplies = [];
      for (const source of sources) {
        if (source.kind === 'pool') {
          supplies.push({
            source,
            supplyTaskIds: poolSourceSupplyById(source.sourceId, poolsById, tasksById),
          });
          continue;
        }
        const sourceBoard = sourceBoardById.get(source.sourceId);
        supplies.push({
          source,
          supplyTaskIds: sourceBoard
            ? await resolveBoardSupply(sourceBoard, source)
            : [],
        });
      }
      // Board Sources §Member rules (B2) — spec step 1: Split-up expansion
      // happens ONCE, here, and the expanded supplies are what the capacity
      // validation, the selection and the member-rule plan all consume. A
      // `split: true` compound therefore contributes its PARTS as selectable
      // squares (and never itself), so what Settings' capacity says and what
      // this spawn places can't disagree.
      const ruleSupplies = applyMemberRules(
        supplies.map((s) => ({ source: s.source, supplyTaskIds: resolveSourceAvailable(s) })),
        childrenByCompound,
        tasksById,
      );

      // The manual layer isn't deleted-filtered (caller-curated, matching
      // resolveMix's old contract), but hard-gone ids ARE dropped — the
      // old path dropped them via its tasksById lookup the same way. A
      // resolved-but-deleted manual task stays, for the validator below.
      const manualTaskIds = (template.manualTaskIds ?? []).filter(
        (id) => tasksById[id] !== undefined,
      );

      // Validate the FULL candidate set (manual + every source's
      // available list, deduped) BEFORE selecting — this preserves the
      // pre-sources skip semantics exactly: a deleted manual task
      // anywhere in the mix skips the window as `has_deleted_tasks`, and
      // a too-small mix as `pool_too_small`, independent of which subset
      // selection would have picked.
      const candidateSeen = new Set<string>();
      const candidateTasks: Task[] = [];
      const addCandidate = (id: string): void => {
        if (candidateSeen.has(id)) return;
        candidateSeen.add(id);
        const t = tasksById[id];
        if (t !== undefined) candidateTasks.push(t);
      };
      for (const id of manualTaskIds) addCandidate(id);
      for (const supply of ruleSupplies) {
        for (const id of resolveSourceAvailable(supply)) addCandidate(id);
      }

      if (candidateTasks.length === 0) {
        return {
          ok: false,
          templateId: template.id,
          reason: 'no_pool_tasks_resolved',
        };
      }

      const validation = validateSpawnPool(template, candidateTasks);
      if (!validation.ok) {
        return {
          ok: false,
          templateId: template.id,
          reason: validation.reason,
        };
      }

      // Pick exactly the fillable cell count, honoring each source's
      // membership range (min/max — `[0, all]` for a migrated shape). A
      // range-infeasible pick maps to the same skip-and-warn family as a
      // small pool.
      const selection = selectBoardTasks({
        // The expanded supplies (see above) — `selectBoardTasks` re-applies
        // `resolveSourceAvailable` internally, which is a no-op on an already
        // exclude-filtered list.
        supplies: ruleSupplies,
        manualTaskIds,
        cellCount: fillableCellCount(template.boardSize, template.centerSquareType),
        // Honor the template's determinism contract: an
        // `isRandomized: false` template must keep its stable first-N
        // subset + order (review-caught — `placeBoard`'s verbatim path
        // is defeated if selection already shuffled).
        randomize: template.isRandomized,
        // Counter-family exclusivity (2026-09-08): at most one member of
        // a shared-counter family per spawned board. Recurring boards
        // have no CHOSEN center, so nothing is pinned here.
        counterFamilyByTaskId: buildCounterFamilyMap(allTasks),
      });
      if (!selection.ok) {
        return {
          ok: false,
          templateId: template.id,
          reason: 'pool_too_small',
        };
      }
      // Board Sources §Member rules (B2, docs/BOARD_SOURCES.md §Member rules —
      // *Resolution pipeline* steps 3/5): the picked ids are resolved against
      // this window's rules and any window-stamped derived counter / derived
      // compound they call for is MINTED HERE — before the `board_tasks` rows
      // below point at it, in this same transaction.
      // Auto targets pro-rate a member's goal by the ratio of the SOURCE
      // board's window to this one, so every supplied id — and every child of
      // a compound member, which is looked up by the CHILD's id — needs its
      // source window recorded.
      const sourceWindowByTaskId: Record<string, BoardWindow | undefined> = {};
      for (const supply of ruleSupplies) {
        if (supply.source.kind !== 'board') continue;
        const sourceBoard = sourceBoardById.get(supply.source.sourceId);
        if (sourceBoard === undefined) continue;
        const sourceWindow: BoardWindow = {
          timeframe: sourceBoard.timeframe,
          startDate: sourceBoard.startDate ?? null,
          endDate: sourceBoard.endDate ?? null,
        };
        for (const id of supply.supplyTaskIds) {
          sourceWindowByTaskId[id] = sourceWindow;
          for (const k of childrenByCompound[id] ?? []) {
            sourceWindowByTaskId[k.childTaskId] = sourceWindow;
          }
        }
      }
      const rootEvents: TaskEvent[] = [];
      for (const root of candidateRootIds(selection.taskIds, tasksById, childrenByCompound)) {
        for (const e of eventsByTaskId[root] ?? []) rootEvents.push(e);
      }
      const { placementIds, minted } = await planAndMintDerivedRows({
        boardId,
        userId: template.userId,
        now,
        selectedIds: selection.taskIds,
        supplies: ruleSupplies,
        manualTaskIds,
        // RB7 — a repeating board carries its hand-added members' dice levels
        // on the record; absent means "nobody varies".
        manualTaskVary: template.manualTaskVary ?? {},
        window: {
          timeframe: template.timeframe,
          startDate: windowStart,
          endDate: windowEnd,
        },
        mode: 'recurring',
        tasksById,
        childrenByCompoundId: childrenByCompound,
        sourceWindowByTaskId,
        events: rootEvents,
      });
      // Fold the minted rows into the snapshots the placement and the
      // derivation pass below read from. Read BACK rather than trusting the
      // built row: RB3 skips an already-live row, so what is stored is the
      // authority for what the board then derives from.
      for (const row of minted.tasks) {
        const stored = await db.tasks.get(row.id);
        if (stored !== undefined) tasksById[row.id] = stored;
      }
      for (const link of minted.links) {
        const stored = await db.compoundChildren.get(link.id);
        if (stored === undefined || stored.isDeleted) continue;
        (childrenByCompound[stored.compoundTaskId] ??= []).push(stored);
      }

      const orderedPool: Task[] = selection.taskIds
        .map((id, i) => tasksById[placementIds[i] ?? id])
        .filter((t): t is Task => t !== undefined);

      const placement = buildSpawnPlacement({
        template,
        poolTasks: orderedPool,
      });

      const board: Board = {
        id: boardId,
        userId: template.userId,
        name: suggestedName,
        status: BoardStatus.ACTIVE,
        boardSize: template.boardSize,
        timeframe: template.timeframe,
        startDate: windowStart,
        endDate: windowEnd,
        centerSquareType: template.centerSquareType,
        isRandomized: template.isRandomized,
        totalTasks: template.boardSize * template.boardSize,
        completedTasks: 0,
        linesCompleted: 0,
        completedLineIds: [],
        createdAt: now,
        updatedAt: now,
        version: 1,
        isDeleted: false,
        spawnedFromTemplateId: template.id,
        // Phase 6.1 — template-spawned boards are core by construction.
        // They fulfill the same "recurring board for this window exists"
        // promise as banner-spawned boards, so the recurring banner
        // detector must treat them the same.
        isCore: true,
      };

      // For odd-sized boards, the center cell index is `floor(N²/2)`;
      // for even-sized, no center exists. `placement` encodes a FREE
      // center as `null`, so the `t === null`
      // check below covers the "auto-completed center" case directly.
      const centerCellIndex =
        template.boardSize % 2 === 1
          ? Math.floor((template.boardSize * template.boardSize) / 2)
          : -1;

      const boardTasks: BoardTask[] = [];
      // Two members that share a shared-counter root collapse onto ONE derived
      // counter, so the same id can reach the placement twice. Counter-family
      // exclusivity already forbids that at selection time, making this a
      // belt-and-braces guard — but a duplicate `taskId` on one board trips
      // the placement-integrity invariants (docs/BOARD_INTEGRITY.md), so the
      // repeat cell is left empty rather than written.
      const placedTaskIds = new Set<string>();
      for (let cell = 0; cell < placement.length; cell++) {
        const t = placement[cell];
        if (t === null) continue; // auto-completed FREE center
        if (placedTaskIds.has(t.id)) {
          console.warn(
            `spawnTemplateBoard: task ${t.id} resolved twice on board ${boardId}; leaving cell ${cell} empty`,
          );
          continue;
        }
        placedTaskIds.add(t.id);
        const row = Math.floor(cell / template.boardSize);
        const col = cell % template.boardSize;
        boardTasks.push({
          id: generateUUID(),
          boardId,
          taskId: t.id,
          row,
          col,
          // isCenter marks a CHOSEN centre task only. Recurring templates
          // never use CHOSEN (free = null centre slot, none = an
          // ordinary task), so this is effectively always false — but gating
          // on CHOSEN keeps it correct + prevents a stale isCenter from
          // syncing to iOS as a gold "FREE" cell over a real task.
          isCenter:
            cell === centerCellIndex &&
            template.centerSquareType === CenterSquareType.CHOSEN,
          createdAt: now,
          updatedAt: now,
          version: 1,
          isDeleted: false,
        });
      }

      // Windowed Completion (docs/WINDOWED_COMPLETION.md §What this closes —
      // respawn-bleed row): run the derivation pass at spawn so stored stats are
      // derivation output, not a hand-initialized 0. A fresh window has no events,
      // so event-owning squares resolve incomplete (no respawn bleed); a
      // FREE center still auto-fills. The invariant "stored stats are
      // always derivation output" now holds from the first row written.
      // (`childrenByCompound` hoisted above the supply resolution — the
      // member-rules plan needs it too; the minted derived links were pushed
      // into it, so a derived compound evaluates against its own parts here.)
      // Reuse the `tasksById` map read at the top of this closure for
      // mix resolution — the only `tasks` writes in between are the member-
      // rule mint's, and those rows were read back into the map above, so it
      // is still an accurate snapshot for the derivation pass.
      const taskById: Record<string, Task> = tasksById;
      // (eventsByTaskId hoisted above the supply resolution — board-kind
      // sources need it for the 'todo' filter; reused here for stats.)
      const allBoards = await db.boards.toArray();
      const stats = computeBoardStatsUpdate(
        board,
        boardTasks,
        childrenByCompound,
        taskById,
        allBoards,
        { eventsByTaskId },
      );
      board.completedTasks = stats.completedTasks;
      board.linesCompleted = stats.linesCompleted;
      board.completedLineIds = stats.completedLineIds;

      const updatedTemplate: RecurringBoardTemplate = {
        ...template,
        lastSpawnedWindowKey: windowStart,
        updatedAt: now,
        version: (template.version ?? 0) + 1,
      };

      await db.boards.add(board);
      if (boardTasks.length > 0) await db.boardTasks.bulkAdd(boardTasks);
      await db.recurringBoardTemplates.put(updatedTemplate);

      // Enqueue through the D3 choke point (per-entity coalescing). The
      // board + boardTasks are freshly-minted UUIDs so their lookups are
      // no-op appends; the template UPDATE coalesces with any pending
      // template edit.
      await addToSyncQueue('boards', board.id, SyncOperationType.CREATE, board);
      for (const bt of boardTasks) {
        await addToSyncQueue('boardTasks', bt.id, SyncOperationType.CREATE, bt);
      }
      await addToSyncQueue(
        'recurringBoardTemplates',
        updatedTemplate.id,
        SyncOperationType.UPDATE,
        updatedTemplate,
      );

      return {
        ok: true,
        boardId,
        templateId: template.id,
        windowStart,
        noBoardForWindowSourceIds,
      };
    },
  );
}
