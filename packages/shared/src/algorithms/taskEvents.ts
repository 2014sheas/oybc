import type { Board } from '../types/board';
import type { Task } from '../types/task';
import type { TaskEvent } from '../types/taskEvent';
import { TaskType } from '../constants/enums';
import { isWithinTimeframe } from './calendarBoundaries';
import { isWindowStampedDerived } from './memberRules';
import { deriveDisplayedCount } from './sharedCounter';

/**
 * Windowed Completion — pure evaluation helpers
 * (docs/WINDOWED_COMPLETION.md §Semantics per task type + §Sealing).
 *
 * These functions are the shared kernel that PR B (write paths / grids /
 * derivation) and PR C (sealing) build on. Nothing here has platform
 * dependencies — the iOS twin mirrors it verbatim.
 */

/** 48h cap on the auto-seal backstop (docs §Sealing → backstop table). */
export const BACKSTOP_MAX_MS = 48 * 60 * 60 * 1000;

/**
 * P5 — Hub-born counters. `occurredAt` for seed (starting-count) increment
 * events. Fixed far-past sentinel: lifetime sums include the seed, no board
 * window ever does, and P4 stats can identify seeds by it.
 * Canonical design: docs/SHARED_COUNTERS.md §P5 decision 4.
 */
export const SEED_EVENT_OCCURRED_AT = '1970-01-01T00:00:00.000Z';

/**
 * The result of resolving a task's state within a window: whether the square
 * is complete, and the windowed count (0 for normal tasks).
 */
export interface TaskWindowState {
  isCompleted: boolean;
  count: number;
}

/**
 * Context threaded through windowed compound evaluation (docs §Semantics —
 * "evaluateCompound gains a window-context parameter"). When present, primitive
 * children resolve against `windowStart` via {@link resolveTaskWindowState};
 * window-stamped derived counters resolve from their root's events in their own
 * window ({@link resolveDerivedCounterWindowState}); hub-linked derived-counting
 * children fall back to their lifetime cache (the carve-out);
 * nested compounds inherit the SAME `windowStart` / `windowEnd` (host-window
 * inheritance).
 */
export interface CompoundWindowContext {
  /** Window lower bound (`board.startDate`), or `null` for lifetime. */
  windowStart: string | null;
  /**
   * Window INCLUSIVE upper bound (`board.endDate`, via {@link boardWindowEnd}),
   * or `null` / absent for an open-ended window (indefinite boards, lifetime).
   * 2026-09-24 amendment: a board's root squares evaluate `[startDate, endDate]`.
   * Optional so construction sites that predate the amendment keep compiling
   * (absent ≡ `null` ≡ the historical `[windowStart, ∞)` behaviour).
   */
  windowEnd?: string | null;
  /** This workspace's non-deleted TaskEvents grouped by `taskId`. */
  eventsByTaskId: Record<string, TaskEvent[]>;
}

/**
 * Context passed to `computeBoardStatsUpdate` to switch it from lifetime
 * (today's behavior) to windowed evaluation. The board supplies its own
 * `startDate` as the window lower bound — the caller only provides the
 * grouped events.
 */
export interface WindowEvaluationContext {
  /** This workspace's non-deleted TaskEvents grouped by `taskId`. */
  eventsByTaskId: Record<string, TaskEvent[]>;
}

/**
 * Whether a Task **owns its completion state** as events (docs §New entity +
 * §Derived-task carve-out). Only event-owning tasks may have `TaskEvent` rows;
 * the write choke points call this before appending an event, and backfill
 * skips non-owning tasks.
 *
 *   - `NORMAL` → owns events.
 *   - `COUNTING` with no `sharedCounterId` (plain / source) → owns events.
 *   - `COUNTING` with `sharedCounterId` (derived) → does NOT (source-driven).
 *   - `COMPOUND` / `ACHIEVEMENT` → do NOT (derived from children / board state).
 *
 * @param task Minimal task shape (type + shared-counter link).
 * @returns `true` iff the task owns its state via events.
 */
export function isEventOwningTask(
  task: Pick<Task, 'type' | 'sharedCounterId'>,
): boolean {
  if (task.type === TaskType.NORMAL) return true;
  if (task.type === TaskType.COUNTING) {
    return task.sharedCounterId == null;
  }
  return false;
}

/**
 * Resolve an event-owning task's state within a window (docs §Semantics).
 *
 * Callers MUST branch derived / compound / achievement tasks BEFORE calling —
 * this function only handles `NORMAL` and plain / source `COUNTING`. Events are
 * filtered to non-deleted defensively (a tombstoned event never counts), so a
 * `tombstoned` vector resolves the same whether or not the caller pre-filtered.
 *
 * Window semantics are `[windowStart, windowEnd]`, **inclusive at both ends**
 * (2026-09-24 amendment of WC Decision 1 — previously start-bound only, with
 * the upper bound left to sealing). `windowStart = null` means no lower bound
 * (lifetime: library surfaces); `windowEnd = null` (the default) means no upper
 * bound (indefinite boards, lifetime). A sealed board's snapshot is narrowed
 * further by `sealedAt` upstream ({@link boundWindowContextAtSeal}), so its
 * effective upper bound is `min(windowEnd, sealedAt)`.
 * Comparison is a parsed timestamp compare (`occurredAt >= windowStart`,
 * `occurredAt <= windowEnd`), never string equality — board dates are
 * LOCAL-ISO while event timestamps are UTC-`Z`. An unparseable bound admits
 * nothing (`NaN` compares false), matching the historical lower-bound rule.
 *
 * @param task        The event-owning task (normal or plain/source counting).
 * @param events      This task's events (deleted rows ignored internally).
 * @param windowStart Window lower bound, or `null` for lifetime.
 * @param windowEnd   Window inclusive upper bound, or `null` (default) for none.
 * @returns `{ isCompleted, count }`. For counting, `count` is the low-clamped
 *          window sum (overshoot preserved — never high-clamped). For normal,
 *          `count` is the number of in-window completion events.
 */
export function resolveTaskWindowState(
  task: Task,
  events: TaskEvent[],
  windowStart: string | null,
  windowEnd: string | null = null,
): TaskWindowState {
  const lowerMs = windowStart == null ? null : new Date(windowStart).getTime();
  const upperMs = windowEnd == null ? null : new Date(windowEnd).getTime();
  const inWindow = (e: TaskEvent): boolean => {
    if (e.isDeleted) return false;
    if (lowerMs === null && upperMs === null) return true;
    const t = new Date(e.occurredAt).getTime();
    if (lowerMs !== null && !(t >= lowerMs)) return false;
    if (upperMs !== null && !(t <= upperMs)) return false;
    return true;
  };

  if (task.type === TaskType.COUNTING) {
    let sum = 0;
    for (const e of events) {
      if (e.kind !== 'increment') continue;
      if (!inWindow(e)) continue;
      sum += e.delta ?? 0;
    }
    // Low-end clamp only — overshoot invariant preserved (never high-clamped).
    const count = Math.max(0, sum);
    const isCompleted = task.maxCount != null && count >= task.maxCount;
    return { isCompleted, count };
  }

  // NORMAL (and any defensive non-counting caller): complete iff a non-deleted
  // completion event falls in the window.
  let completions = 0;
  for (const e of events) {
    if (e.kind !== 'completion') continue;
    if (!inWindow(e)) continue;
    completions += 1;
  }
  return { isCompleted: completions > 0, count: completions };
}

/**
 * The inclusive upper bound a board's LIVE windowed evaluation uses for its
 * root squares (and compound children, by host-window inheritance): the
 * board's own `endDate`, or `null` for an indefinite board (2026-09-24
 * amendment of WC Decision 1 — `[startDate, endDate]`, not `[startDate, ∞)`).
 *
 * @param board The board being evaluated (only `endDate` is read).
 * @returns `board.endDate`, or `null` when the board has none.
 */
export function boardWindowEnd(board: Pick<Board, 'endDate'>): string | null {
  return board.endDate ?? null;
}

/**
 * The `occurredAt` to stamp on a log made from `board`'s OWN play surface at
 * `nowIso` (2026-09-24 amendment, decision C2 — "late logs").
 *
 *   - Window still open (`now <= endDate`), or the board has no `endDate` →
 *     `nowIso`, verbatim.
 *   - Window ended (`now > endDate`) and the board is UNSEALED → the board's
 *     `endDate` instant, re-encoded as a UTC event timestamp
 *     (`new Date(endDate).toISOString()`), so the overtime log still counts
 *     for this board (whose inclusive upper bound is `endDate`) and for no
 *     later window.
 *   - Sealed boards never log (play is locked), so there is no clamp branch
 *     for them: a sealed board returns `nowIso`.
 *
 * Comparison is by parsed ms, never by string — board dates are LOCAL-ISO,
 * event timestamps are UTC ISO. An unparseable `endDate` or `nowIso` fails
 * open (returns `nowIso`) rather than throwing.
 *
 * @param board  The board the log is made from (`endDate` + `sealedAt` read).
 * @param nowIso The current instant as an ISO timestamp (the caller's clock).
 * @returns The ISO timestamp to store as the event's `occurredAt`.
 */
export function lateLogOccurredAt(
  board: Pick<Board, 'endDate' | 'sealedAt'>,
  nowIso: string,
): string {
  if (board.endDate == null || board.sealedAt != null) return nowIso;
  const endMs = new Date(board.endDate).getTime();
  const nowMs = new Date(nowIso).getTime();
  if (Number.isNaN(endMs) || Number.isNaN(nowMs)) return nowIso;
  if (nowMs <= endMs) return nowIso;
  return new Date(endMs).toISOString();
}

/**
 * Resolve a **window-stamped derived counter**'s state from its ROOT's events
 * (docs/WINDOWED_COMPLETION.md §Derived-task carve-out, amended 2026-09-23;
 * docs/BOARD_SOURCES.md §Plan B2 notes → "Window-stamped derived counters").
 *
 * A window-stamped derived counter owns no events (carve-out item 1), but it
 * carries its own window (`startDate` / `endDate`, stamped from the board it
 * was minted for) and a per-window target (`maxCount`). Its completion is
 * therefore a pure function of the root's converged increment events inside
 * that window — never the propagation-stamped one-way latch, which a LATER
 * window's increments can set and which made sealed re-derivation diverge
 * across devices (audit 2026-09-23 finding #1).
 *
 * Window membership uses {@link isWithinTimeframe} — the SAME `[startDate,
 * endDate]` convention (inclusive both ends, parsed-timestamp compare, `null`
 * `endDate` = unbounded) the kernel already uses for board windows. Deltas are
 * signed (a decrement is a negative delta) and summed as-is; the sum is then
 * low-clamped at 0 exactly like {@link resolveTaskWindowState} and
 * `deriveDisplayedCount`. Completion is `count >= (maxCount ?? 0)` — the
 * derived-counter convention (`deriveDisplayedCount`: a missing / 0 target is
 * immediately complete). Overshoot is valid; nothing is high-clamped.
 *
 * `baseline` is NOT read — it stays a non-authored display cache.
 *
 * @param task       The window-stamped derived counter (its window + target).
 * @param rootEvents The ROOT task's events (`eventsByTaskId[task.sharedCounterId]`);
 *                   deleted rows and completion events are ignored internally.
 * @returns `{ isCompleted, count }` where `count` is the clamped in-window sum.
 */
export function resolveWindowStampedDerivedState(
  task: Pick<Task, 'startDate' | 'endDate' | 'maxCount'>,
  rootEvents: TaskEvent[],
): TaskWindowState {
  let sum = 0;
  if (task.startDate) {
    for (const e of rootEvents) {
      if (e.isDeleted || e.kind !== 'increment') continue;
      if (!isWithinTimeframe(e.occurredAt, task.startDate, task.endDate ?? null)) continue;
      sum += e.delta ?? 0;
    }
  }
  const count = Math.max(0, sum);
  return { isCompleted: count >= (task.maxCount ?? 0), count };
}

/**
 * Kernel dispatch for the window-stamped derived-counter branch: when `task`
 * is a COUNTING row that {@link isWindowStampedDerived} identifies, resolve it
 * from its root's events via {@link resolveWindowStampedDerivedState};
 * otherwise return `null` so the caller falls through to its existing branches
 * (event-owning → `resolveTaskWindowState`; hub-linked derived with no
 * `startDate` → the lifetime latch, unchanged).
 *
 * A root with no entry in `eventsByTaskId` resolves as zero events (count 0) —
 * never as "fall back to the latch". Every production context builder loads
 * the whole workspace's non-deleted events keyed by `taskId` (so the root's
 * events are present even when only the derived row is placed), and the
 * sealed context drops keys whose events were all bounded away — for that
 * case "absent" genuinely means "nothing in the window". The only latch
 * fallback is a context-less (lifetime) resolution, which the callers already
 * handle before reaching this branch.
 *
 * @param task           The task being resolved.
 * @param eventsByTaskId The window context's grouped events.
 * @returns The derived window state, or `null` when `task` is not a
 *          window-stamped derived counter.
 */
export function resolveDerivedCounterWindowState(
  task: Task,
  eventsByTaskId: Record<string, TaskEvent[]>,
): TaskWindowState | null {
  if (task.type !== TaskType.COUNTING) return null;
  if (!isWindowStampedDerived(task) || !task.sharedCounterId) return null;
  return resolveWindowStampedDerivedState(task, eventsByTaskId[task.sharedCounterId] ?? []);
}

/**
 * What a LINKED (derived) counting square or row SHOWS: its displayed count and
 * its completion — the events-based variant of `deriveDisplayedCount`
 * (docs/WINDOWED_COMPLETION.md §Derived-task carve-out, amended 2026-09-23).
 *
 * - **Window-stamped** (`isWindowStampedDerived`, COUNTING) with an event map:
 *   the ROOT's increment sum inside the row's own `[startDate, endDate]` via
 *   {@link resolveWindowStampedDerivedState} — the SAME function the derivation
 *   kernel resolves the cell with, so a cell can never paint green (or read
 *   N/N) while board stats count it incomplete. When `sealedAt` is given (the
 *   row's board is sealed) root events after it are dropped first, matching
 *   {@link boundWindowContextAtSeal} on the sealed re-derive; this only binds
 *   when the row has no `endDate` (an unparseable `sealedAt` applies no bound). Overshoot is shown; never high-clamped.
 * - **Hub-linked** (no `startDate`), or no event map (library / lifetime
 *   readers): `currentCount − baseline` (low-clamped) for the count, and the
 *   propagation-stamped latch `task.isCompleted` for completion — exactly the
 *   kernel's own carve-out for these rows.
 *
 * @param task           The linked counting task being rendered.
 * @param eventsByTaskId Non-deleted events grouped by `taskId` (the whole
 *                       workspace, or at least the root's), or `null`/`undefined`
 *                       when the caller has none.
 * @param sealedAt       The row's board `sealedAt`, when that board is sealed.
 * @returns `{ displayed, isCompleted }`.
 */
export function resolveLinkedCounterDisplay(
  task: Task,
  eventsByTaskId: Record<string, TaskEvent[]> | null | undefined,
  sealedAt?: string | null,
): { displayed: number; isCompleted: boolean } {
  if (eventsByTaskId && task.type === TaskType.COUNTING && isWindowStampedDerived(task) && task.sharedCounterId) {
    let rootEvents = eventsByTaskId[task.sharedCounterId] ?? [];
    const sealedAtMs = sealedAt ? new Date(sealedAt).getTime() : NaN;
    if (!Number.isNaN(sealedAtMs)) {
      rootEvents = rootEvents.filter((e) => new Date(e.occurredAt).getTime() <= sealedAtMs);
    }
    const { count, isCompleted } = resolveWindowStampedDerivedState(task, rootEvents);
    return { displayed: count, isCompleted };
  }
  const { displayed } = deriveDisplayedCount(
    { baseline: task.baseline ?? 0, maxCount: task.maxCount ?? 0 },
    { currentCount: task.currentCount ?? 0 },
  );
  return { displayed, isCompleted: task.isCompleted };
}

/**
 * Cascade reachability for window-stamped derived counters: return `ids`
 * UNION the ids of every live window-stamped derived row
 * ({@link isWindowStampedDerived}) whose `sharedCounterId` is in `ids`.
 *
 * A shared-counter ROOT is never placed on a board, but every window-stamped
 * derived row linked to it resolves FROM the root's events
 * ({@link resolveDerivedCounterWindowState}). So whenever a root's event set
 * changes (a pulled / healed event), the placement walk that finds affected
 * boards must start from those derived rows too — both the LIVE pull cascade
 * and the SEALED re-derivation. Hub-linked rows (no `startDate`) are NOT
 * added: they resolve from their latch, which only an authored task write
 * changes (and that write cascades on its own). Ids that aren't roots pass
 * through unchanged.
 *
 * @param ids   The task ids whose events changed.
 * @param tasks Candidate task rows (any superset of the linked rows — the
 *              whole workspace, or just the rows with `sharedCounterId` in `ids`).
 * @returns A new set: `ids` plus the reachable window-stamped derived row ids.
 */
export function expandToWindowStampedDerived(
  ids: Iterable<string>,
  tasks: Iterable<Pick<Task, 'id' | 'isDeleted' | 'sharedCounterId' | 'startDate' | 'createdInWizard'>>,
): Set<string> {
  const roots = new Set(ids);
  const out = new Set(roots);
  if (roots.size === 0) return out;
  for (const t of tasks) {
    if (t.isDeleted || !t.sharedCounterId || !roots.has(t.sharedCounterId)) continue;
    if (isWindowStampedDerived(t)) out.add(t.id);
  }
  return out;
}

/**
 * Bound a window context's events at a sealed board's `sealedAt` (docs §Seal
 * snapshots re-derive from the event union): keep only events with
 * `occurredAt <= sealedAtMs`, dropping a task's key when none survive. Applied
 * to EVERY task's events — including a shared-counter ROOT's, which is what a
 * window-stamped derived cell now reads — so a post-seal increment can never
 * leak into a frozen record. At seal time `sealedAtMs = now`, so nothing is
 * dropped; the bound matters for pull-path re-derivation.
 *
 * Shared so both platforms' sealing data layers (web `db/operations/sealing.ts`
 * ↔ iOS `AppDatabase+Sealing.swift`) and the seal vectors run the same filter.
 * An unparseable `occurredAt` is dropped (JS `NaN <= x === false`).
 *
 * @param eventsByTaskId Non-deleted events grouped by `taskId` (unbounded).
 * @param sealedAtMs     The board's `sealedAt` as epoch ms (inclusive bound).
 * @returns A new context; the input is not mutated.
 */
export function boundWindowContextAtSeal(
  eventsByTaskId: Record<string, TaskEvent[]>,
  sealedAtMs: number,
): WindowEvaluationContext {
  const bounded: Record<string, TaskEvent[]> = {};
  for (const [taskId, evs] of Object.entries(eventsByTaskId)) {
    const kept = evs.filter((e) => new Date(e.occurredAt).getTime() <= sealedAtMs);
    if (kept.length > 0) bounded[taskId] = kept;
  }
  return { eventsByTaskId: bounded };
}

/**
 * A sealed board's frozen window as epoch-ms bounds (docs §Write paths →
 * "Sealed-window immunity"). An event is immune to tombstoning iff its
 * `occurredAt` falls inside one of these windows.
 */
export interface SealImmuneWindow {
  /** Sealed board's `startDate` as epoch ms (inclusive lower bound). */
  startMs: number;
  /** Sealed board's `sealedAt` as epoch ms (inclusive upper bound). */
  sealedAtMs: number;
}

/**
 * Build the immune windows for a task from the sealed boards that place it
 * (docs Decision 9 + §Write paths). The caller resolves *which* non-deleted
 * sealed boards place the task (directly or via a placed compound — the same
 * reachability the pull-path re-derivation uses) and passes their
 * `startDate`/`sealedAt`; this turns them into epoch-ms bounds.
 *
 * @param sealedBoards Sealed boards placing the task (each with a set `sealedAt`).
 * @returns One immune window per sealed board.
 */
export function buildSealImmuneWindows(
  sealedBoards: ReadonlyArray<{ startDate: string; sealedAt: string }>,
): SealImmuneWindow[] {
  return sealedBoards.map((b) => ({
    startMs: new Date(b.startDate).getTime(),
    sealedAtMs: new Date(b.sealedAt).getTime(),
  }));
}

/**
 * Whether an event's `occurredAt` is sealed-window immune (docs Decision 9):
 * it falls inside `[startDate, sealedAt]` of some sealed board that places the
 * task. Immune events can never be tombstoned by any un-complete/decrement
 * gesture — history stays history. Bounds are inclusive on both ends (the
 * boundary instants belong to the frozen record).
 *
 * @param occurredAt The event's semantic timestamp (ISO8601).
 * @param windows    The task's immune windows (from {@link buildSealImmuneWindows}).
 * @returns `true` iff the event is immune to tombstoning.
 */
export function isOccurredAtSealImmune(
  occurredAt: string,
  windows: ReadonlyArray<SealImmuneWindow>,
): boolean {
  if (windows.length === 0) return false;
  const t = new Date(occurredAt).getTime();
  return windows.some((w) => w.startMs <= t && t <= w.sealedAtMs);
}

/**
 * The auto-seal backstop **duration** for a board's window (docs §Sealing):
 * `min(48h, windowLength/4)`. Timeframe-scaling falls out of the window length
 * itself — daily → 6h, weekly → 42h, monthly/yearly/custom≥8d → 48h — so one
 * formula owns every timeframe.
 *
 * @param startDate Board window start (ISO8601).
 * @param endDate   Board window end (ISO8601).
 * @returns Backstop duration in ms, capped at 48h and floored at 0.
 */
export function backstopWindowMs(startDate: string, endDate: string): number {
  const lengthMs = new Date(endDate).getTime() - new Date(startDate).getTime();
  return Math.min(BACKSTOP_MAX_MS, Math.max(0, lengthMs) / 4);
}

/**
 * The absolute auto-seal deadline for a board, as epoch ms (docs §Sealing →
 * "deadline keys off `max(endDate, activatedAt)`"). Returning ms — rather than
 * an ISO string — sidesteps the local-ISO vs UTC encoding decision; callers
 * compare `now.getTime() > deadline`.
 *
 * A draft activated AFTER its window already expired keys off `activatedAt`, so
 * it still gets one full prompt cycle instead of an instant silent seal.
 * Indefinite boards (no `endDate`) never seal → `null`.
 *
 * @param startDate   Board window start (ISO8601).
 * @param endDate     Board window end (ISO8601), or null/undefined for indefinite.
 * @param activatedAt When the board was activated (ISO8601), if known.
 * @returns Epoch-ms deadline, or `null` when the board never seals.
 */
export function computeBackstopDeadlineMs(
  startDate: string,
  endDate: string | null | undefined,
  activatedAt?: string | null,
): number | null {
  if (endDate == null) return null;
  const endMs = new Date(endDate).getTime();
  const activatedMs = activatedAt != null ? new Date(activatedAt).getTime() : endMs;
  const anchor = Math.max(endMs, activatedMs);
  return anchor + backstopWindowMs(startDate, endDate);
}
