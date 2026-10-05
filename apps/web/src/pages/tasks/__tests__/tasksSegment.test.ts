import { describe, expect, it } from 'vitest';
import {
  NEW_POOL_PATH,
  TASKS_POOLS_PATH,
  parseTasksSegment,
  poolEditorPath,
  tasksPrimaryAction,
} from '../tasksSegment';

describe('tasksPrimaryAction', () => {
  it('Pools segment: "+ New pool" routes to the pool editor', () => {
    expect(tasksPrimaryAction('pools')).toEqual({ label: 'New pool', kind: 'new-pool' });
  });
  it('Library segment: unchanged "+ New task" sheet', () => {
    expect(tasksPrimaryAction('library')).toEqual({ label: 'New task', kind: 'new-task' });
  });
});

describe('parseTasksSegment', () => {
  it('reads ?segment=pools', () => {
    expect(parseTasksSegment(new URLSearchParams('segment=pools'))).toBe('pools');
  });
  it('defaults to library when absent or unknown', () => {
    expect(parseTasksSegment(new URLSearchParams(''))).toBe('library');
    expect(parseTasksSegment(new URLSearchParams('segment=nope'))).toBe('library');
    expect(parseTasksSegment(new URLSearchParams('segment=library'))).toBe('library');
  });
  it('the editor return path round-trips to the Pools segment', () => {
    const qs = TASKS_POOLS_PATH.split('?')[1];
    expect(parseTasksSegment(new URLSearchParams(qs))).toBe('pools');
  });
});

describe('pool editor paths', () => {
  it('builds the new / edit routes', () => {
    expect(NEW_POOL_PATH).toBe('/tasks/pools/new');
    expect(poolEditorPath('abc')).toBe('/tasks/pools/abc');
  });
});
