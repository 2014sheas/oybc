import { describe, expect, it, vi } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { DetailModal } from '../InteractiveTaskSquare';
import type { TaskSquareData, SquareState } from '../interactiveTaskSquareUtils';

const sq: TaskSquareData = {
  id: 'task-1', title: 'Push-ups', type: 'counting', action: 'Push', maxCount: 10, unit: 'reps',
};
const state = { isCompleted: false, currentCount: 3 } as SquareState;

function render(onOpenInLibrary?: (id: string) => void): string {
  return renderToStaticMarkup(
    React.createElement(DetailModal, {
      sq, state, onClose: () => {}, onToggleComplete: () => {},
      onIncrementCount: () => {}, onDecrementCount: () => {}, onOpenInLibrary,
    }),
  );
}

describe('DetailModal — Task details row', () => {
  it('renders for a counting square when onOpenInLibrary is provided', () => {
    const html = render(vi.fn());
    expect(html).toContain('aria-label="Task details"');
    expect(html).toContain('Task details');
  });

  it('is absent without onOpenInLibrary', () => {
    expect(render()).not.toContain('aria-label="Task details"');
  });
});
