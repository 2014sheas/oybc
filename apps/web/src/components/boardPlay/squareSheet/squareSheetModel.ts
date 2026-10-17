/**
 * Pure glue for the board square sheet (docs/TASK_DETAIL_REDESIGN.md §PR 2).
 * iOS twin: `SquareSheetModel.swift`.
 */
import { formatCount, formatCountWithUnit, quantizeCount, type CountKind } from '@oybc/shared';
import type { StatusPillStatus } from '../../StatusPill';

/** The status pill a hero shows: none at zero, IN PROGRESS partway, DONE once met. */
export function progressPill(done: boolean, started: boolean): StatusPillStatus | null {
  if (done) return 'completed';
  return started ? 'inProgress' : null;
}

/** What is left of a window's goal, or 0 once it is met (drives the "‹rest› to go" line). */
export function restToGo(goal: number, windowedCount: number): number {
  return Math.max(0, quantizeCount(goal - windowedCount));
}

/** The 52pt hero count shrinks to 40pt for duration so "4h 30m" stays on one line. */
export function heroCountSize(kind: CountKind): 52 | 40 {
  return kind === 'duration' ? 40 : 52;
}

/** "Logged +5 pages · Week 42" / "Removed 5 pages · Week 42" — the Undo strip's line. */
export function logStripText(verb: 'logged' | 'removed', amount: number, kind: CountKind, unit: string, boardLabel: string): string {
  const withUnit = formatCountWithUnit(amount, kind, unit);
  return `${verb === 'logged' ? 'Logged +' : 'Removed '}${withUnit} · ${boardLabel}`;
}

/** "‹count› / ‹goal› ‹unit› · ‹board›" — the line beside the hero count. */
export function goalLine(goal: number, kind: CountKind, unit: string, boardLabel: string): string {
  return `/ ${formatCountWithUnit(goal, kind, unit)} · ${boardLabel}`;
}

/** "‹rest› to go · ‹board›" — the TAP TO LOG eyebrow's right side. */
export function restLine(rest: number, kind: CountKind, boardLabel: string): string {
  return `${formatCount(rest, kind)} to go · ${boardLabel}`;
}

/** A compound child's meta ("12 / 20"), counting children only. */
export function childMeta(current: number, max: number, kind: CountKind): string {
  return `${formatCount(current, kind)} / ${formatCount(max, kind)}`;
}

/** "of ‹n› sub-tasks · ‹board›" — the compound hero's line. */
export function subtaskLine(total: number, boardLabel: string): string {
  return `of ${total} sub-task${total === 1 ? '' : 's'} · ${boardLabel}`;
}

/** "Closed Oct 11" — the closed-board lock row (a missing / unparseable date reads plain "Closed"). */
export function closedLabel(sealedAt: string | null | undefined): string {
  const ms = sealedAt ? new Date(sealedAt).getTime() : NaN;
  if (Number.isNaN(ms)) return 'Closed';
  return `Closed ${new Date(ms).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}`;
}

/**
 * Whether a closed board's square can open the late-log sheet: achievement
 * squares and hub-linked derived counters have nothing to log (OQ2), so the
 * sheet shows no `Late log…` button for them.
 */
export function isLateLogRoutable(squareType: 'normal' | 'counting' | 'compound' | 'achievement', hubLinkedCounter: boolean): boolean {
  return squareType !== 'achievement' && !hubLinkedCounter;
}

/** The watched board's "‹n› days left" ("Last day" under 24h); null when open-ended or already over. */
export function daysLeftLabel(endDate: string | null | undefined, now: number): string | null {
  const end = endDate ? new Date(endDate).getTime() : NaN;
  if (Number.isNaN(end) || end < now) return null;
  if (end - now < 86_400_000) return 'Last day';
  const days = Math.ceil((end - now) / 86_400_000);
  return `${days} days left`;
}

/** The custom-entry amount, quantized to the kind's step; null when the field holds none. */
export function entryAmount(parsed: number | null): number | null {
  return parsed === null || parsed <= 0 ? null : quantizeCount(parsed);
}

/**
 * An Undo strip is only live until the next write settles on this board: it
 * was made at write sequence `seq`, and any later write bumps `writeSeq`.
 *
 * @param strip - The strip, if any (stamped with the sequence it was made at).
 * @param writeSeq - The board session's current write sequence.
 * @returns The strip while it is still the latest write, else null.
 */
export function liveStrip<T extends { seq: number }>(strip: T | null, writeSeq: number): T | null {
  return strip && strip.seq === writeSeq ? strip : null;
}
