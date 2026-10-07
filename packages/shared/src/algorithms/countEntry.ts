/**
 * Counter kinds — the single owner of counting INPUT rules and the authoring
 * picker's state (docs/COUNTER_KINDS.md §5). Every Goal / custom-amount field
 * on every surface parses through {@link parseCountInput}; every kind picker
 * derives its locks from {@link kindPickerLock}. Swift twin:
 * `apps/ios/OYBC/Helpers/CountEntry.swift`, pinned by countEntryVectors.json.
 */
import { formatCount, quantizeCount, resolveCountKind, type CountKind } from './countValue';

/** On-screen kind labels, in picker order (D1 / §5). */
export const COUNT_KIND_LABELS: Readonly<Record<CountKind, string>> = {
  discrete: 'Discrete',
  continuous: 'Continuous',
  duration: 'Duration',
};

/** Which picker segments are locked: none, Duration only, or every segment. */
export type KindPickerLock = 'none' | 'duration' | 'all';

/**
 * The picker's lock state for a surface (D4: Duration never switches either way).
 *
 * @param mode - `'create'` for a task that does not exist yet, else `'edit'`.
 * @param kind - The task's current kind.
 * @returns `'none'` on create; `'all'` for an existing Duration; else `'duration'`.
 */
export function kindPickerLock(mode: 'create' | 'edit', kind: CountKind): KindPickerLock {
  if (mode === 'create') return 'none';
  return kind === 'duration' ? 'all' : 'duration';
}

/**
 * @param lock - The picker's lock state.
 * @param segment - The segment being rendered.
 * @returns Whether the segment ignores taps.
 */
export function isKindSegmentLocked(lock: KindPickerLock, segment: CountKind): boolean {
  return lock === 'all' || (lock === 'duration' && segment === 'duration');
}

/**
 * Whether a segment carries the lock glyph: with every segment locked only the
 * selected one does; otherwise each locked, unselected segment does.
 *
 * @param lock - The picker's lock state.
 * @param segment - The segment being rendered.
 * @param selected - The picker's value.
 * @returns True when the glyph renders on `segment`.
 */
export function kindSegmentShowsLock(lock: KindPickerLock, segment: CountKind, selected: CountKind): boolean {
  if (lock === 'all') return segment === selected;
  return isKindSegmentLocked(lock, segment) && segment !== selected;
}

const DIGITS = /^[0-9]+$/;
const CONTINUOUS = /^([0-9]+)?(?:[.,]([0-9]{0,2}))?$/;
const DURATION_COLON = /^([0-9]+):([0-5]?[0-9])$/;
/** Any entry above this is refused (an overflow digit string reads as invalid, never as a huge goal). */
const MAX_COUNT_INPUT = 1_000_000_000;
const DURATION_HM = /^(?:([0-9]+)\s*h)?\s*(?:([0-9]+)\s*m)?$/i;

function parseDurationMinutes(s: string): number | null {
  if (DIGITS.test(s)) return Number(s);
  const colon = DURATION_COLON.exec(s);
  if (colon) return Number(colon[1]) * 60 + Number(colon[2]);
  const hm = DURATION_HM.exec(s);
  if (hm && (hm[1] !== undefined || hm[2] !== undefined)) {
    return Number(hm[1] ?? '0') * 60 + Number(hm[2] ?? '0');
  }
  return null;
}

/**
 * Parses a Goal / custom-amount field for a kind. ASCII digits only (R10).
 *
 * @param raw - The field text.
 * @param kind - The counter's kind.
 * @param options - `allowZero` admits 0 (the hub's optional "Start from").
 * @returns The value (minutes for duration), or null when not a valid entry.
 */
export function parseCountInput(
  raw: string,
  kind: CountKind,
  options: { allowZero?: boolean } = {},
): number | null {
  const s = raw.trim();
  if (s === '') return null;
  let value: number | null = null;
  if (kind === 'discrete') {
    value = DIGITS.test(s) ? Number(s) : null;
  } else if (kind === 'continuous') {
    const m = CONTINUOUS.exec(s);
    if (m && `${m[1] ?? ''}${m[2] ?? ''}` !== '') {
      value = quantizeCount(Number(`${m[1] ?? '0'}.${m[2] || '0'}`));
    }
  } else {
    value = parseDurationMinutes(s);
  }
  if (value === null || !Number.isFinite(value) || value < 0 || value > MAX_COUNT_INPUT) return null;
  if (value === 0 && options.allowZero !== true) return null;
  return value;
}

/**
 * Splits stored minutes into the web Duration entry's two fields.
 *
 * @param minutes - Stored minutes, or absent.
 * @returns `{ hours, minutes }` strings; minutes zero-padded; both `''` when absent.
 */
export function durationToFields(minutes: number | null | undefined): { hours: string; minutes: string } {
  if (minutes == null) return { hours: '', minutes: '' };
  const total = Math.max(0, Math.floor(minutes + 0.5));
  return { hours: String(Math.floor(total / 60)), minutes: String(total % 60).padStart(2, '0') };
}

/**
 * Joins the two Duration fields into a {@link parseCountInput}-parsable string.
 *
 * @param hours - The hours field text.
 * @param minutes - The minutes field text.
 * @returns `'Xh Ym'` (a blank side reads 0), or `''` when both are blank.
 */
export function durationFromFields(hours: string, minutes: string): string {
  const h = hours.trim();
  const m = minutes.trim();
  if (h === '' && m === '') return '';
  return `${h === '' ? '0' : h}h ${m === '' ? '0' : m}m`;
}

/**
 * @param kind - The counter's kind.
 * @returns False only for duration (its unit is time; the Unit field hides).
 */
export function countKindNeedsUnit(kind: CountKind): boolean {
  return kind !== 'duration';
}

/**
 * The unit text that follows a count on screen.
 *
 * @param kind - The counter's kind.
 * @param unit - The stored unit.
 * @returns `' unit'`, or `''` for duration or a blank unit.
 */
export function countUnitSuffix(kind: CountKind, unit: string | null | undefined): string {
  const u = (unit ?? '').trim();
  return kind === 'duration' || u === '' ? '' : ` ${u}`;
}

/**
 * `formatCount` + {@link countUnitSuffix} — "3.1 mi", "1h 30m".
 *
 * @param value - The value (minutes for duration).
 * @param kind - The counter's kind.
 * @param unit - The stored unit.
 * @param locale - Optional BCP 47 locale.
 * @returns The display string.
 */
export function formatCountWithUnit(
  value: number,
  kind: CountKind,
  unit: string | null | undefined,
  locale?: string,
): string {
  return `${formatCount(value, kind, locale)}${countUnitSuffix(kind, unit)}`;
}

/**
 * A row's effective kind: a linked row (`sharedCounterId`) follows its root
 * (D5), even when the row itself was written before the root's kind landed
 * (a wizard-pending link — R19). A root that cannot be found falls back to
 * the row's own kind.
 *
 * @param task - The row.
 * @param lookup - Resolves a task id (the caller's task map).
 * @returns The family kind.
 */
export function resolveFamilyCountKind(
  task: { countKind?: CountKind | null; sharedCounterId?: string | null },
  lookup: (id: string) => { countKind?: CountKind | null } | undefined,
): CountKind {
  if (task.sharedCounterId) {
    const root = lookup(task.sharedCounterId);
    if (root) return resolveCountKind(root);
  }
  return resolveCountKind(task);
}
