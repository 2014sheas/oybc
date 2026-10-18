import { useLiveQuery } from 'dexie-react-hooks';
import type { TaskEvent } from '@oybc/shared';
import { buildWindowContext } from '../../db/operations/windowContext';

const EMPTY_EVENTS_BY_TASK_ID: Record<string, TaskEvent[]> = Object.freeze({}) as Record<string, TaskEvent[]>;

/**
 * Every non-deleted `taskEvents` row in the workspace, grouped by `taskId`
 * (Gate 1 ruling, slice 2c). Context-less library readers
 * (`contextlessCounterState`) sum a counter's lifetime events from it.
 *
 * Opt-in on purpose: it is a full `taskEvents` scan that re-runs on every
 * event write, so only the Tasks tab's status filters call it. It used to be
 * part of `useTaskLibrary`, which made every board render pay for the scan on
 * every log. Kept in its own module so a value import of it never drags in
 * the `hooks` barrel (and with it the Firebase config).
 *
 * @returns The live events map; a stable empty map until the first emission.
 */
export function useLibraryEventsByTaskId(): Record<string, TaskEvent[]> {
  return (
    useLiveQuery(async () => (await buildWindowContext()).eventsByTaskId, []) ?? EMPTY_EVENTS_BY_TASK_ID
  );
}
