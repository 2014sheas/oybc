import { afterEach, describe, expect, it, vi } from 'vitest';
import { persistPreferenceUpdate } from '../usePreferences';

/**
 * 2026-09 audit (T1, Task 4) — `usePreferences().update` used to fire
 * `void updateUserPreferences(...)` with no handler, so a failed IndexedDB
 * write became an unhandled rejection with no context. The hook now routes
 * through `persistPreferenceUpdate`, which must (a) swallow-and-log a
 * rejection rather than propagate it, and (b) stay silent on success.
 */
describe('persistPreferenceUpdate', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('logs a rejected write with context and resolves instead of rejecting', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const failure = new Error('IDB transaction aborted');
    const write = vi.fn().mockRejectedValue(failure);

    await expect(
      persistPreferenceUpdate('user-1', { theme: 'dark' }, write)
    ).resolves.toBeUndefined();

    expect(write).toHaveBeenCalledWith('user-1', { theme: 'dark' });
    expect(errorSpy).toHaveBeenCalledTimes(1);
    expect(errorSpy).toHaveBeenCalledWith(
      '[usePreferences] Failed to update preferences',
      failure
    );
  });

  it('does not log when the write succeeds', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const write = vi.fn().mockResolvedValue(undefined);

    await persistPreferenceUpdate('user-1', { weekStartDay: 'sunday' }, write);

    expect(write).toHaveBeenCalledWith('user-1', { weekStartDay: 'sunday' });
    expect(errorSpy).not.toHaveBeenCalled();
  });
});
