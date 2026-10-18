import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { BUSY_LOOK_DELAY_MS, scheduleBusyLook } from '../useBusyLook';

describe('busy look delay', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('is 250 ms (mirrored on iOS)', () => {
    expect(BUSY_LOOK_DELAY_MS).toBe(250);
  });

  it('a write that settles inside the delay never takes the busy look', () => {
    const onLate = vi.fn();
    const cancel = scheduleBusyLook(onLate);
    vi.advanceTimersByTime(BUSY_LOOK_DELAY_MS - 1);
    cancel();
    vi.advanceTimersByTime(1000);
    expect(onLate).not.toHaveBeenCalled();
  });

  it('a write still in flight at 250 ms takes it, once', () => {
    const onLate = vi.fn();
    scheduleBusyLook(onLate);
    vi.advanceTimersByTime(BUSY_LOOK_DELAY_MS - 1);
    expect(onLate).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(onLate).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(1000);
    expect(onLate).toHaveBeenCalledTimes(1);
  });
});
