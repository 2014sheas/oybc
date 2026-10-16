import { Timeframe, TaskType } from '../constants/enums';
import type { Task } from '../types/task';
import { formatWindowLabel, isTimeframeExpired } from './calendarBoundaries';
import { isWindowStampedDerived } from './memberRules';

/**
 * The slice of a task the Task Detail window caption reads.
 */
export type TaskWindowCaptionTask = Pick<
  Task,
  'type' | 'timeframe' | 'startDate' | 'endDate' | 'sharedCounterId' | 'createdInWizard'
>;

/** "Oct 13, 2026" — the DAILY form of `formatWindowLabel`, for a bare date. */
function shortDate(iso: string): string {
  return formatWindowLabel(Timeframe.DAILY, iso);
}

/**
 * Task Detail's read-only window facts (owner request 2026-10-16, after the
 * PR #624 incident where a sub-task pinned to one day's window was invisible
 * in the UI — the only tell was "Updated: 2d ago").
 *
 * Up to two lines, rendered under the Details text on both platforms:
 *
 *   - `"Window · <label>"` when the task carries its OWN window (`startDate`
 *     set): the timeframe's label (`formatWindowLabel`), or for CUSTOM / no
 *     timeframe the bare `start – end` dates (`start` alone when open-ended);
 *     `" · ended"` is appended once `now` is past `endDate`.
 *   - for a LINKED counting task: `"Linked counter · per-window copy"` when
 *     the row is window-stamped (`isWindowStampedDerived` — it resolves from
 *     its own window) or `"Linked counter · follows each board's window"`
 *     otherwise (hub-linked — the kernel reads it over each host board).
 *
 * Pure; iOS twin `TaskCountDisplay.windowCaptionLines(for:now:)`.
 *
 * @param task - The task being rendered.
 * @param now - The instant "ended" is judged against (injectable for tests).
 * @returns The lines, in order; empty when the task has neither fact.
 */
export function taskWindowCaptionLines(task: TaskWindowCaptionTask, now: Date = new Date()): string[] {
  const lines: string[] = [];
  const start = task.startDate;
  if (start) {
    const tf = task.timeframe;
    let label: string;
    if (tf && tf !== Timeframe.CUSTOM) {
      label = formatWindowLabel(tf, start);
    } else {
      label = task.endDate ? `${shortDate(start)} – ${shortDate(task.endDate)}` : shortDate(start);
    }
    const ended = isTimeframeExpired(task.endDate, now) ? ' · ended' : '';
    lines.push(`Window · ${label}${ended}`);
  }
  if (task.type === TaskType.COUNTING && task.sharedCounterId) {
    lines.push(
      isWindowStampedDerived(task)
        ? 'Linked counter · per-window copy'
        : "Linked counter · follows each board's window",
    );
  }
  return lines;
}
