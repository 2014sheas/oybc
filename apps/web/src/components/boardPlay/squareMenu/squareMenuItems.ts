/**
 * The square hold menu's vocabulary (docs/TASK_DETAIL_REDESIGN.md §PR 3): ONE
 * pure item list per square, so a unit test pins every label. iOS twin:
 * `SquareMenuItems.swift`.
 */
import {
  countUnitSuffix, formatCount, formatCountWithUnit, hubChips, nextCompoundSubtask, quickLogAmount, TaskType,
  type CompoundSubtaskAction, type CountKind,
} from '@oybc/shared';
import type { RisoIconName } from '../../riso/RisoIcon';
import type { SquareTaskType } from '../../interactiveTaskSquareUtils';

/** What choosing an item does (the host maps each to a write or a surface). */
export type MenuAction =
  | { kind: 'toggleNormal' }
  | { kind: 'log'; amount: number }
  | { kind: 'logOther' }
  | { kind: 'remove' }
  | { kind: 'completeNext'; next: CompoundSubtaskAction; amount?: number }
  | { kind: 'allSubtasks' }
  | { kind: 'openBoard' }
  | { kind: 'lateLog' }
  | { kind: 'details' }
  | { kind: 'library' };

export interface MenuItem {
  id: string;
  label: string;
  /** Muted trailing text (a child's name, "2 / 3"). */
  meta?: string;
  icon: RisoIconName;
  action: MenuAction;
  /** Changes data (disabled while a write is in flight). */
  write: boolean;
  /** Greyed and inert regardless of busy. */
  disabled?: boolean;
}

export type MenuEntry = MenuItem | 'divider';

export interface SquareMenuModel {
  type: SquareTaskType;
  title: string;
  /** Header's trailing text: "12 / 20", "2 / 3", "Not done", "Watching". */
  meta: string;
  /** Items; the first is rendered gold. */
  entries: MenuEntry[];
}

/** One compound child as the menu sees it. */
export interface MenuChild {
  id: string;
  title: string;
  type: TaskType;
  isCompleted: boolean;
  /** Counting children: the family kind, unit and remembered log amount. */
  count?: { kind: CountKind; unit: string; defaultAmount?: number | null };
}

export interface SquareMenuInput {
  type: SquareTaskType;
  title: string;
  /** Sealed board: write items collapse to `Late log…`. */
  closed: boolean;
  /** `isLateLogRoutable` — absent → a closed menu simply has no write item. */
  lateLogRoutable: boolean;
  done: boolean;
  /** Normal: un-completing is blocked by a sealed window. */
  /** Normal: un-completing is blocked by a sealed window; `undefined` = the seal check is still loading (treated as blocked). */
  uncompleteBlocked?: boolean;
  counting?: { count: number; goal: number; kind: CountKind; unit: string; defaultAmount?: number | null };
  compound?: { children: ReadonlyArray<MenuChild> };
  /** Achievement: the watched board's name; null when there is no single board (template watcher / gone). */
  watchedBoardName?: string | null;
}

/**
 * The amount a menu "Log +‹n›" writes: the remembered default, else the first
 * FIXED preset (`hubChips`) — 1 for discrete.
 *
 * @param kind - The counter's family kind.
 * @param defaultAmount - The counter's remembered last-used amount.
 * @returns The quick amount.
 */
export function menuQuickAmount(kind: CountKind, defaultAmount?: number | null): number {
  return quickLogAmount(kind, hubChips(kind), defaultAmount);
}

/**
 * The next FIXED preset strictly above `amount`, or undefined when none.
 *
 * @param kind - The counter's family kind.
 * @param amount - The quick amount.
 * @returns The next preset.
 */
export function menuNextPreset(kind: CountKind, amount: number): number | undefined {
  return hubChips(kind)
    .flatMap((c) => (c.value === null ? [] : [c.value]))
    .find((v) => v > amount);
}

const item = (i: MenuItem): MenuItem => i;
const DETAILS = item({ id: 'details', label: 'Details', icon: 'edit', action: { kind: 'details' }, write: false });
const LIBRARY = item({ id: 'library', label: 'Open in library', icon: 'boards', action: { kind: 'library' }, write: false });
const LATE_LOG = item({ id: 'lateLog', label: 'Late log…', icon: 'lock', action: { kind: 'lateLog' }, write: false });

/** The items a closed board replaces with `Late log…` (the writes, plus the two that open the sheet on a write entry). */
const COLLAPSED_ON_CLOSED: ReadonlySet<MenuAction['kind']> = new Set(['toggleNormal', 'log', 'logOther', 'remove', 'completeNext']);

/** Joins non-empty groups with dividers. */
function join(groups: MenuItem[][]): MenuEntry[] {
  const out: MenuEntry[] = [];
  for (const g of groups.filter((x) => x.length > 0)) {
    if (out.length > 0) out.push('divider');
    out.push(...g);
  }
  return out;
}

function countingGroups(c: NonNullable<SquareMenuInput['counting']>): MenuItem[][] {
  const quick = menuQuickAmount(c.kind, c.defaultAmount);
  const next = menuNextPreset(c.kind, quick);
  const log = (amount: number, id: string): MenuItem =>
    item({ id, label: `Log +${formatCountWithUnit(amount, c.kind, c.unit)}`, icon: 'plus', action: { kind: 'log', amount }, write: true });
  return [
    [log(quick, 'log'), ...(next !== undefined ? [log(next, 'logNext')] : []),
      item({ id: 'logOther', label: 'Log other amount…', icon: 'edit', action: { kind: 'logOther' }, write: false })],
    [item({ id: 'remove', label: `Remove${countUnitSuffix(c.kind, c.unit)}…`, icon: 'trash', action: { kind: 'remove' }, write: false, disabled: c.count <= 0 })],
  ];
}

function compoundGroup(children: ReadonlyArray<MenuChild>): MenuItem[] {
  const next = nextCompoundSubtask(children.map((c) => ({ id: c.id, type: c.type, isCompleted: c.isCompleted })));
  const out: MenuItem[] = [];
  if (next) {
    const child = children.find((c) => c.id === next.childId);
    if (next.kind === 'toggle') {
      out.push(item({ id: 'next', label: 'Complete next sub-task', meta: child?.title, icon: 'check', action: { kind: 'completeNext', next }, write: true }));
    } else if (child?.count) {
      const amount = menuQuickAmount(child.count.kind, child.count.defaultAmount);
      out.push(item({
        id: 'next', label: `Log +${formatCountWithUnit(amount, child.count.kind, child.count.unit)} · ${child.title}`,
        icon: 'plus', action: { kind: 'completeNext', next, amount }, write: true,
      }));
    }
  }
  out.push(item({
    id: 'all', label: 'All sub-tasks…', meta: `${children.filter((c) => c.isCompleted).length} / ${children.length}`,
    icon: 'tasks', action: { kind: 'allSubtasks' }, write: false,
  }));
  return out;
}

/**
 * Builds the hold menu for one square.
 *
 * Normal: Mark done · Details · Open in library. Counting: Log +quick · Log
 * +next preset · Log other amount… · Remove… · Details · Open in library.
 * Compound: Complete next sub-task / Log + · All sub-tasks… · Open in
 * library. Achievement: Open ‹board› · Details · Open in library. On a closed
 * board every write item collapses to one `Late log…` (only when routable).
 *
 * @param input - The square's resolved facts.
 * @returns The header + entries.
 */
export function buildSquareMenu(input: SquareMenuInput): SquareMenuModel {
  let groups: MenuItem[][];
  let meta: string;
  switch (input.type) {
    case 'counting': {
      const c = input.counting;
      meta = c ? `${formatCount(c.count, c.kind)} / ${formatCount(c.goal, c.kind)}` : '';
      groups = [...(c ? countingGroups(c) : []), [DETAILS, LIBRARY]];
      break;
    }
    case 'compound':
      meta = `${(input.compound?.children ?? []).filter((c) => c.isCompleted).length} / ${input.compound?.children.length ?? 0}`;
      groups = [compoundGroup(input.compound?.children ?? []), [LIBRARY]];
      break;
    case 'achievement':
      meta = input.done ? 'Done' : 'Watching';
      groups = [
        input.watchedBoardName ? [item({ id: 'openBoard', label: `Open ${input.watchedBoardName}`, icon: 'boards', action: { kind: 'openBoard' }, write: false })] : [],
        [DETAILS, LIBRARY],
      ];
      break;
    default:
      meta = input.done ? 'Done' : 'Not done';
      groups = [
        [item({ id: 'toggle', label: input.done ? 'Mark not done' : 'Mark done', icon: 'check', action: { kind: 'toggleNormal' }, write: true, disabled: input.done && input.uncompleteBlocked !== false })],
        [DETAILS, LIBRARY],
      ];
  }
  if (input.closed) {
    groups = groups.map((g) => g.filter((i) => !COLLAPSED_ON_CLOSED.has(i.action.kind)));
    if (input.lateLogRoutable) groups = [[LATE_LOG], ...groups];
  }
  return { type: input.type, title: input.title, meta, entries: join(groups) };
}
