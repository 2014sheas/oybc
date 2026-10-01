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
  it('found: renders a button with title, total and aria-label', () => {
    const html = renderToStaticMarkup(
      React.createElement(LinkedCounterCaptionView, {
        sharedCounterId: 'root-1', isLoading: false, sourceTask: root, onOpenCounter: () => {},
      }),
    );
    expect(html).toContain('<button');
    expect(html).toContain('aria-label="Open Push-ups counter"');
    expect(html).toContain('Push-ups');
    expect(html).toContain('512 reps');
  });

  it('found: click calls onOpenCounter with the sharedCounterId', () => {
    const onOpenCounter = vi.fn();
    const el = LinkedCounterCaptionView({
      sharedCounterId: 'root-1', isLoading: false, sourceTask: root, onOpenCounter,
    }) as React.ReactElement<{ onClick: () => void }>;
    el.props.onClick();
    expect(onOpenCounter).toHaveBeenCalledWith('root-1');
  });

  it('not found: non-interactive caption, no button', () => {
    const html = renderToStaticMarkup(
      React.createElement(LinkedCounterCaptionView, {
        sharedCounterId: 'root-1', isLoading: false, sourceTask: null, onOpenCounter: () => {},
      }),
    );
    expect(html).not.toContain('<button');
    expect(html).toContain('deleted or not found');
  });

  it('loading: non-interactive caption', () => {
    const html = renderToStaticMarkup(
      React.createElement(LinkedCounterCaptionView, {
        sharedCounterId: 'root-1', isLoading: true, sourceTask: null, onOpenCounter: () => {},
      }),
    );
    expect(html).not.toContain('<button');
    expect(html).toContain('loading…');
  });
});
