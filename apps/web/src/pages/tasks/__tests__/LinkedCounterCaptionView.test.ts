import { describe, expect, it, vi } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TaskType, type Task } from '@oybc/shared';
import { LinkedCounterCaptionView } from '../LinkedCounterCaptionView';

const root = {
  id: 'root-1',
  title: 'Push-ups',
  type: TaskType.COUNTING,
  unit: 'reps',
  currentCount: 512,
} as Task;

describe('LinkedCounterCaptionView', () => {
  it('found: renders a button with title, total and aria-label, no "Linked to" caption', () => {
    const html = renderToStaticMarkup(
      React.createElement(LinkedCounterCaptionView, {
        sharedCounterId: 'root-1', isLoading: false, sourceTask: root, onOpenCounter: () => {},
      }),
    );
    expect(html).toContain('<button');
    expect(html).toContain('aria-label="Open Push-ups counter"');
    expect(html).toContain('Push-ups');
    expect(html).toContain('512 reps');
    expect(html).not.toContain('Linked to');
  });

  it('found: a continuous root shows its grouped decimal total in the root kind', () => {
    const run = {
      ...root, title: 'Run', unit: 'miles', countKind: 'continuous', currentCount: 1250.5,
    } as Task;
    const html = renderToStaticMarkup(
      React.createElement(LinkedCounterCaptionView, {
        sharedCounterId: 'root-1', isLoading: false, sourceTask: run, onOpenCounter: () => {},
      }),
    );
    expect(html).toContain('1,250.5 miles');
  });

  it('found: a duration root shows h/m with no unit', () => {
    const practice = {
      ...root, title: 'Practice', unit: '', countKind: 'duration', currentCount: 6735,
    } as Task;
    const html = renderToStaticMarkup(
      React.createElement(LinkedCounterCaptionView, {
        sharedCounterId: 'root-1', isLoading: false, sourceTask: practice, onOpenCounter: () => {},
      }),
    );
    expect(html).toContain('112h 15m<');
  });

  it('found: click calls onOpenCounter with the sharedCounterId', () => {
    const onOpenCounter = vi.fn();
    const el = LinkedCounterCaptionView({
      sharedCounterId: 'root-1', isLoading: false, sourceTask: root, onOpenCounter,
    }) as React.ReactElement<{ onClick: () => void }>;
    el.props.onClick();
    expect(onOpenCounter).toHaveBeenCalledWith('root-1');
  });

  it('not found: renders nothing', () => {
    const html = renderToStaticMarkup(
      React.createElement(LinkedCounterCaptionView, {
        sharedCounterId: 'root-1', isLoading: false, sourceTask: null, onOpenCounter: () => {},
      }),
    );
    expect(html).toBe('');
  });

  it('loading: renders nothing', () => {
    const html = renderToStaticMarkup(
      React.createElement(LinkedCounterCaptionView, {
        sharedCounterId: 'root-1', isLoading: true, sourceTask: null, onOpenCounter: () => {},
      }),
    );
    expect(html).toBe('');
  });
});
