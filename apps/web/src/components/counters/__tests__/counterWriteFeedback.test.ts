import { afterEach, describe, expect, it, vi } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { attemptCounterWrite, COUNTER_NOT_UPDATED_MESSAGE } from '../counterWriteFeedback';
import { CounterWriteError } from '../CounterWriteError';

/**
 * 2026-09 audit (T1, Task 6) — web parity with the iOS Counters alert: a failed
 * log/undo write is reported (never a success toast, never an unhandled
 * rejection). `attemptCounterWrite` is the seam the Hub card, Hub undo and
 * Detail log/undo all branch on; `CounterWriteError` is the line they show.
 *
 * Rendered with `react-dom/server` — no jsdom/RTL harness in this repo.
 */
describe('attemptCounterWrite', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('returns false and logs with context when the write rejects', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const failure = new Error('IDB write failed');

    const ok = await attemptCounterWrite('hub undo', () => Promise.reject(failure));

    expect(ok).toBe(false);
    expect(errorSpy).toHaveBeenCalledWith('[counters] hub undo failed', failure);
  });

  it('returns true and logs nothing when the write resolves', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const write = vi.fn().mockResolvedValue(undefined);

    const ok = await attemptCounterWrite('hub log', write);

    expect(ok).toBe(true);
    expect(write).toHaveBeenCalledTimes(1);
    expect(errorSpy).not.toHaveBeenCalled();
  });
});

describe('CounterWriteError', () => {
  it('renders the functional error as an alert', () => {
    const html = renderToStaticMarkup(
      React.createElement(CounterWriteError, { message: COUNTER_NOT_UPDATED_MESSAGE })
    );

    expect(html).toContain('role="alert"');
    expect(html).toContain('Counter not updated. Try again.');
  });

  it('renders nothing when there is no error', () => {
    expect(renderToStaticMarkup(React.createElement(CounterWriteError, { message: null }))).toBe('');
  });
});
