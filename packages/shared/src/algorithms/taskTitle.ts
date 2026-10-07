import { formatCounterName } from './counterName';
import { quantizeCount } from './countValue';

/**
 * Generates a display title for a COUNTING task.
 *
 * If a non-empty providedTitle is given, returns it trimmed.
 * Otherwise, generates a title from action, maxCount, and unit.
 *
 * @param action - Action verb (e.g., "Read")
 * @param maxCount - Target count (e.g., 100), rendered as a trimmed 2dp number (locale-independent: titles are stored data), or null/undefined for a goal-less hub-born counter
 * @param unit - Unit of measurement (e.g., "pages")
 * @param providedTitle - Optional user-provided title
 * @returns The resolved task title string
 */
export function generateCounterTaskTitle(
  action: string,
  maxCount: number | null | undefined,
  unit: string,
  providedTitle?: string
): string {
  if (providedTitle && providedTitle.trim().length > 0) {
    return providedTitle.trim();
  }
  // Goal-less hub-born counters are accumulators with no numeric target —
  // the title IS the pair-derived counter display name (design 2026-07-18,
  // R1 counters refresh). The earlier P5 "{action} ({unit})" parenthetical
  // is retired: "Do" + "push-ups" now renders "Push-ups", "Run" + "miles"
  // renders "Run miles" — see `formatCounterName`.
  if (maxCount == null) {
    return formatCounterName(action, unit);
  }
  return `${action.trim()} ${String(quantizeCount(maxCount))} ${unit.trim()}`;
}

/**
 * The fields of a counting member that decide its copy's title.
 *
 * Structural on purpose (not `Pick<Task, …>`) so this module stays free of
 * the `types/` import graph; both `PlanTask` and a stored `Task` satisfy it.
 */
export interface CounterTitleFields {
  title: string;
  action?: string | null;
  unit?: string | null;
  maxCount?: number | null;
}

/**
 * Whether a counting task's title is the AUTO one — i.e. not a name the
 * user chose.
 *
 * A title is auto iff, after trimming, it is empty OR equal to the title
 * {@link generateCounterTaskTitle} builds from the task's OWN
 * `action` / `maxCount` / `unit` (also trimmed). The compare is
 * **case-sensitive** ("read 10 pages" is a custom name for a "Read" / 10 /
 * "pages" counter) and **whitespace-insensitive at the ends only** — inner
 * spacing must match exactly. Owner bug 2026-10-06: a custom wizard name
 * was lost when a per-board copy of the member was minted, because the
 * copy regenerated its title from fields whenever `action` was set; this
 * predicate is how the mint tells a chosen name from a generated one.
 *
 * @param title - The stored title.
 * @param action - The task's own action verb (`''` when absent).
 * @param maxCount - The task's own goal (`null`/`undefined` for goal-less).
 * @param unit - The task's own unit (`''` when absent).
 * @returns `true` when the title is empty or generated; `false` when custom.
 */
export function isAutoCounterTitle(
  title: string,
  action: string,
  maxCount: number | null | undefined,
  unit: string
): boolean {
  const trimmed = title.trim();
  if (trimmed.length === 0) return true;
  return trimmed === generateCounterTaskTitle(action, maxCount, unit).trim();
}

/**
 * The title a per-board COPY of a counting member carries.
 *
 * A custom member title ({@link isAutoCounterTitle} is `false`) carries
 * over VERBATIM (trimmed) — even when the copy's target differs, because the
 * user chose that name. An auto (or empty) title is regenerated from the
 * copy's `action` / NEW `maxCount` / `unit`, exactly as before the
 * 2026-10-06 fix. Shared by `planDerivedTasks`'s mint and the linked-counter
 * window heal's `windowStampedCopyDraft` so the two mint paths can never
 * disagree; Swift twin `TaskTitle.counterCopyTitle`.
 *
 * @param member - The member being copied (its own title / action / unit / goal).
 * @param newMaxCount - The copy's target.
 * @returns The copy's title.
 */
export function counterCopyTitle(member: CounterTitleFields, newMaxCount: number): string {
  const action = member.action ?? '';
  const unit = member.unit ?? '';
  if (!isAutoCounterTitle(member.title, action, member.maxCount, unit)) {
    return member.title.trim();
  }
  return generateCounterTaskTitle(action, newMaxCount, unit);
}
