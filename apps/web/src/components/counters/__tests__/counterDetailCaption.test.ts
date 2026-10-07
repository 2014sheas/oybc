import { describe, expect, it } from 'vitest';
import { buildTaskCardCaption } from '../counterDetailCaption';

const member = (o: object) => ({ taskId: 't', taskTitle: 'Run 26.2 mi', logged: 12.4, goal: 26.2, met: false, over: 0, window: undefined, ...o }) as never;

describe('buildTaskCardCaption', () => {
  it('continuous to go', () => expect(buildTaskCardCaption(member({}), 'mi', 'continuous')).toBe('13.8 mi to go'));
  it('continuous over', () => expect(buildTaskCardCaption(member({ logged: 28.4, met: true, over: 2.2 }), 'mi', 'continuous')).toBe('✓ Goal met · 2.2 over'));
  it('duration to go has no unit', () => expect(buildTaskCardCaption(member({ logged: 270, goal: 630 }), '', 'duration')).toBe('6h to go'));
  it('discrete unchanged', () => expect(buildTaskCardCaption(member({ logged: 3, goal: 10 }), 'pages', 'discrete')).toBe('7 pages to go'));
  it('window trails', () => expect(buildTaskCardCaption(member({ logged: 3, goal: 10, window: 'Sun' }), 'pages', 'discrete')).toBe('7 pages to go · ends Sun'));
});
