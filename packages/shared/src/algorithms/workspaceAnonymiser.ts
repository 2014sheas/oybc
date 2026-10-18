import { TaskType } from '../constants/enums';
import type { Board } from '../types/board';
import type { BoardTask } from '../types/boardTask';
import type { CompoundChild } from '../types/compoundChild';
import type { Pool } from '../types/pool';
import type { RecurringBoardTemplate } from '../types/recurringBoardTemplate';
import type { Task } from '../types/task';
import type { TaskEvent } from '../types/taskEvent';
import { resolveCountKind } from './countValue';
import { renderCounterTitle } from './counterSettings';
import { isAutoCounterTitle } from './taskTitle';

/**
 * workspaceAnonymiser.ts — the dev-only "Export anonymised workspace" action
 * (TASK_WINDOW_REWORK slice 4, Gate 1 ruling b): a pure rewrite of a
 * workspace that keeps every id, number, date, kind, flag and relation
 * intact and replaces every piece of user text with a deterministic
 * placeholder. The output is the input of the sweep planner and the sweep's
 * acceptance test, so:
 *
 *   - ids are KEPT verbatim (UUIDs carry no personal data, and the slice-4b
 *     forward uuidv5 match needs the real `(board, root)` pairs);
 *   - a counting title that was the auto formula / the root's template
 *     render stays auto after anonymisation (it is re-rendered from the
 *     anonymised action / unit / templates), a custom title becomes
 *     `Task <n>` — so `isAutoCounterTitle` answers the same before and after;
 *   - descriptions and the `recurringDraftMix` blob are dropped.
 *
 * Swift has no twin: the export lives on the web Developer settings only.
 */

export interface AnonymisableWorkspace {
  tasks: readonly Task[];
  boards: readonly Board[];
  boardTasks: readonly BoardTask[];
  compoundChildren: readonly CompoundChild[];
  events: readonly TaskEvent[];
  templates: readonly RecurringBoardTemplate[];
  pools: readonly Pool[];
}

export interface AnonymisedWorkspace {
  tasks: Task[];
  boards: Board[];
  boardTasks: BoardTask[];
  compoundChildren: CompoundChild[];
  events: TaskEvent[];
  templates: RecurringBoardTemplate[];
  pools: Pool[];
}

const OWNER = 'owner';

/** A deterministic per-value placeholder map ("Action 1", "Action 2", …). */
class Names {
  private readonly map = new Map<string, string>();
  constructor(private readonly prefix: string) {}
  of(value: string | null | undefined): string | undefined {
    if (value == null) return undefined;
    const key = value.trim().toLowerCase();
    if (key.length === 0) return value;
    let out = this.map.get(key);
    if (!out) {
      out = `${this.prefix} ${this.map.size + 1}`;
      this.map.set(key, out);
    }
    return out;
  }
}

/**
 * Anonymise a workspace. Pure and deterministic for a given input order.
 *
 * @param ws The workspace rows (every table the sweep and its gate read).
 * @returns The same rows with user text replaced; ids and relations intact.
 */
export function anonymiseWorkspace(ws: AnonymisableWorkspace): AnonymisedWorkspace {
  const actions = new Names('Action');
  const units = new Names('unit');
  const counters = new Names('Counter');
  const titles = new Names('Task');
  const boardNames = new Names('Board');
  const seriesNames = new Names('Series');
  const poolNames = new Names('Pool');
  const freeTitles = new Names('Title');

  const taskById = new Map(ws.tasks.map((t) => [t.id, t]));

  const anonSettings = (t: Task): Task => {
    const out: Task = { ...t };
    delete out.description;
    out.userId = OWNER;
    if (t.action != null) out.action = actions.of(t.action);
    if (t.unit != null) out.unit = units.of(t.unit);
    if (t.counterName != null) out.counterName = counters.of(t.counterName);
    if (t.titleTemplateSingular != null) out.titleTemplateSingular = `Do #N ${out.unit ?? 'unit'}`;
    if (t.titleTemplatePlural != null) out.titleTemplatePlural = `Do #N ${out.unit ?? 'units'}`;
    return out;
  };

  // Two passes: settings first (a linked row's auto title renders through its ROOT's templates).
  const settingsById = new Map<string, Task>();
  for (const t of ws.tasks) settingsById.set(t.id, anonSettings(t));

  const tasks: Task[] = ws.tasks.map((t) => {
    const out = settingsById.get(t.id) as Task;
    if (t.type === TaskType.COUNTING) {
      const kind = resolveCountKind(t);
      const root = t.sharedCounterId ? taskById.get(t.sharedCounterId) : undefined;
      const auto = isAutoCounterTitle(t.title, t.action ?? '', t.maxCount, t.unit ?? '', kind, root ?? t);
      if (auto) {
        const anonRoot = root ? (settingsById.get(root.id) as Task) : out;
        out.title = renderCounterTitle({ ...anonRoot, action: out.action, unit: out.unit, countKind: kind }, t.maxCount);
      } else {
        out.title = titles.of(t.title) as string;
      }
    } else {
      out.title = titles.of(t.title) as string;
    }
    return out;
  });

  const boards: Board[] = ws.boards.map((b) => {
    const out: Board = { ...b, userId: OWNER, name: boardNames.of(b.name) as string };
    delete out.description;
    delete out.recurringDraftMix;
    return out;
  });

  const boardTasks: BoardTask[] = ws.boardTasks.map((bt) => {
    const out: BoardTask = { ...bt };
    if (bt.titleOverride != null) out.titleOverride = freeTitles.of(bt.titleOverride);
    return out;
  });

  const events: TaskEvent[] = ws.events.map((e) => ({ ...e, userId: OWNER }));
  const compoundChildren: CompoundChild[] = ws.compoundChildren.map((c) => ({ ...c }));

  const templates: RecurringBoardTemplate[] = ws.templates.map((t) => {
    const out: RecurringBoardTemplate = { ...t, userId: OWNER, name: seriesNames.of(t.name) as string };
    if (t.manualTaskTargets) {
      out.manualTaskTargets = Object.fromEntries(
        Object.entries(t.manualTaskTargets).map(([id, v]) => [id, v.title != null ? { ...v, title: freeTitles.of(v.title) } : { ...v }]),
      );
    }
    return out;
  });

  const pools: Pool[] = ws.pools.map((p) => ({ ...p, userId: OWNER, name: poolNames.of(p.name) as string }));

  return { tasks, boards, boardTasks, compoundChildren, events, templates, pools };
}
