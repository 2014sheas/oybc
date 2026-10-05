/** Library/Pools segment of the Tasks tab (Task Pools + Recurring Boards Rework, P2). */
export type TasksSegment = 'library' | 'pools';

/** URL search param carrying the segment, so the pool editor can return to Pools. */
export const TASKS_SEGMENT_PARAM = 'segment';

/** Where the pool editor routes live. */
export const NEW_POOL_PATH = '/tasks/pools/new';

/** Path of an existing pool's editor page. */
export function poolEditorPath(poolId: string): string {
  return `/tasks/pools/${poolId}`;
}

/** The Tasks tab URL with the Pools segment selected (the editor's return target). */
export const TASKS_POOLS_PATH = `/tasks?${TASKS_SEGMENT_PARAM}=pools`;

/**
 * Parses the segment from the page's search params. Anything but `pools`
 * (absent, unknown) is the default Library segment.
 */
export function parseTasksSegment(search: URLSearchParams): TasksSegment {
  return search.get(TASKS_SEGMENT_PARAM) === 'pools' ? 'pools' : 'library';
}

/** What the header "+" does for a segment. */
export interface TasksPrimaryAction {
  /** Button label (the leading "+" is the icon). */
  label: string;
  /** `new-task` opens the New-task sheet; `new-pool` routes to the pool editor. */
  kind: 'new-task' | 'new-pool';
}

/** Segment-aware header "+": Pools creates a pool, Library creates a task. */
export function tasksPrimaryAction(segment: TasksSegment): TasksPrimaryAction {
  return segment === 'pools'
    ? { label: 'New pool', kind: 'new-pool' }
    : { label: 'New task', kind: 'new-task' };
}
