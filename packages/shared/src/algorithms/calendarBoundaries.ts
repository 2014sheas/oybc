import { Timeframe } from '../constants/enums';

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * Configurable first day of the week.
 */
export type WeekStartDay = 'monday' | 'sunday';

/**
 * Start and end dates for a calendar period, as local ISO8601 strings
 * (no timezone suffix — stored as-is in the database).
 */
export interface TimeframeBoundaries {
  startDate: string; // e.g. "2026-03-23T00:00:00.000"
  endDate: string;   // e.g. "2026-03-29T23:59:59.999"
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Format a Date as a local ISO8601 string (YYYY-MM-DDTHH:mm:ss.sss).
 * Avoids timezone shifts that Date.toISOString() would introduce.
 *
 * Use this instead of Date.toISOString() when storing dates that represent
 * local calendar concepts (e.g., "today", "this week"). toISOString() converts
 * to UTC, which shifts the date for users not in UTC.
 */
export function toLocalISO(d: Date): string {
  const y = d.getFullYear();
  const mo = String(d.getMonth() + 1).padStart(2, '0');
  const da = String(d.getDate()).padStart(2, '0');
  const h = String(d.getHours()).padStart(2, '0');
  const mi = String(d.getMinutes()).padStart(2, '0');
  const s = String(d.getSeconds()).padStart(2, '0');
  const ms = String(d.getMilliseconds()).padStart(3, '0');
  return `${y}-${mo}-${da}T${h}:${mi}:${s}.${ms}`;
}

function startOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), 0, 0, 0, 0);
}

function endOfDay(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), 23, 59, 59, 999);
}

// ─── Boundary Calculators ─────────────────────────────────────────────────────

/**
 * Returns start/end of the day containing `date`.
 */
export function getDayBoundaries(date: Date): TimeframeBoundaries {
  return {
    startDate: toLocalISO(startOfDay(date)),
    endDate: toLocalISO(endOfDay(date)),
  };
}

/**
 * Returns start/end of the week containing `date`.
 *
 * @param weekStartDay - Whether weeks start on Monday or Sunday.
 *   Monday start: Mon 00:00 → Sun 23:59.
 *   Sunday start: Sun 00:00 → Sat 23:59.
 */
export function getWeekBoundaries(date: Date, weekStartDay: WeekStartDay): TimeframeBoundaries {
  const jsDay = date.getDay(); // 0=Sun, 1=Mon, …, 6=Sat

  let daysSinceStart: number;
  if (weekStartDay === 'monday') {
    // Monday = 0 offset. Sunday (0) maps to 6.
    daysSinceStart = (jsDay + 6) % 7;
  } else {
    // Sunday = 0 offset. Already matches JS getDay().
    daysSinceStart = jsDay;
  }

  const weekStart = new Date(date.getFullYear(), date.getMonth(), date.getDate() - daysSinceStart);
  const weekEnd = new Date(weekStart.getFullYear(), weekStart.getMonth(), weekStart.getDate() + 6);

  return {
    startDate: toLocalISO(startOfDay(weekStart)),
    endDate: toLocalISO(endOfDay(weekEnd)),
  };
}

/**
 * Returns start/end of the month containing `date`.
 */
export function getMonthBoundaries(date: Date): TimeframeBoundaries {
  const y = date.getFullYear();
  const m = date.getMonth();
  const firstDay = new Date(y, m, 1);
  // Day 0 of next month = last day of current month
  const lastDay = new Date(y, m + 1, 0);

  return {
    startDate: toLocalISO(startOfDay(firstDay)),
    endDate: toLocalISO(endOfDay(lastDay)),
  };
}

/**
 * Returns start/end of the year containing `date`.
 */
export function getYearBoundaries(date: Date): TimeframeBoundaries {
  const y = date.getFullYear();
  return {
    startDate: toLocalISO(new Date(y, 0, 1, 0, 0, 0, 0)),
    endDate: toLocalISO(new Date(y, 11, 31, 23, 59, 59, 999)),
  };
}

// ─── Router ───────────────────────────────────────────────────────────────────

/**
 * Given a timeframe and optional reference date, return the calendar boundaries.
 *
 * @param timeframe - Which period to compute.
 * @param referenceDate - Any date within the desired period (defaults to now).
 * @param weekStartDay - First day of week (defaults to 'monday'). Only used for WEEKLY.
 * @throws For Timeframe.CUSTOM — custom boards have user-specified dates, not computed boundaries.
 */
export function getTimeframeBoundaries(
  timeframe: Timeframe,
  referenceDate: Date = new Date(),
  weekStartDay: WeekStartDay = 'monday',
): TimeframeBoundaries {
  switch (timeframe) {
    case Timeframe.DAILY:
      return getDayBoundaries(referenceDate);
    case Timeframe.WEEKLY:
      return getWeekBoundaries(referenceDate, weekStartDay);
    case Timeframe.MONTHLY:
      return getMonthBoundaries(referenceDate);
    case Timeframe.YEARLY:
      return getYearBoundaries(referenceDate);
    case Timeframe.CUSTOM:
      throw new Error('Cannot compute boundaries for CUSTOM timeframe — use user-specified dates');
  }
}

// ─── Validation & Expiry ──────────────────────────────────────────────────────

/**
 * Check whether a date falls within a timeframe's start/end boundaries (inclusive).
 */
export function isWithinTimeframe(
  date: Date | string,
  startDate: string,
  endDate: string,
): boolean {
  const ts = typeof date === 'string' ? new Date(date).getTime() : date.getTime();
  return ts >= new Date(startDate).getTime() && ts <= new Date(endDate).getTime();
}

/**
 * Check whether a timeframe has expired (current time is past the end date).
 */
export function isTimeframeExpired(endDate: string, now: Date = new Date()): boolean {
  return now.getTime() > new Date(endDate).getTime();
}

// ─── Display ──────────────────────────────────────────────────────────────────

const MONTH_NAMES = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

const MONTH_ABBREVS = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/**
 * Human-readable label for a timeframe period.
 *
 * - DAILY (today): "Today"
 * - DAILY (other): "Mar 15, 2026"
 * - WEEKLY: "Week of Mar 23 – 29, 2026" or "Week of Dec 29 – Jan 4" (cross-month)
 * - MONTHLY: "March 2026"
 * - YEARLY: "2026"
 * - CUSTOM: "Custom"
 */
export function formatTimeframeLabel(timeframe: Timeframe, startDate: string): string {
  const d = new Date(startDate);

  switch (timeframe) {
    case Timeframe.DAILY: {
      const today = new Date();
      if (
        d.getFullYear() === today.getFullYear() &&
        d.getMonth() === today.getMonth() &&
        d.getDate() === today.getDate()
      ) {
        return 'Today';
      }
      return `${MONTH_ABBREVS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;
    }

    case Timeframe.WEEKLY: {
      const endD = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 6);
      const startMonth = MONTH_ABBREVS[d.getMonth()];
      const endMonth = MONTH_ABBREVS[endD.getMonth()];

      if (d.getMonth() === endD.getMonth()) {
        return `Week of ${startMonth} ${d.getDate()} – ${endD.getDate()}, ${d.getFullYear()}`;
      }
      // Cross-month or cross-year
      if (d.getFullYear() === endD.getFullYear()) {
        return `Week of ${startMonth} ${d.getDate()} – ${endMonth} ${endD.getDate()}, ${d.getFullYear()}`;
      }
      return `Week of ${startMonth} ${d.getDate()} – ${endMonth} ${endD.getDate()}`;
    }

    case Timeframe.MONTHLY:
      return `${MONTH_NAMES[d.getMonth()]} ${d.getFullYear()}`;

    case Timeframe.YEARLY:
      return `${d.getFullYear()}`;

    case Timeframe.CUSTOM:
      return 'Custom';
  }
}
