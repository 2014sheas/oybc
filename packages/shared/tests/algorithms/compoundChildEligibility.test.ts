/**
 * compoundChildEligibility.test.ts — may an EXISTING library task be linked
 * as a sub-task of a compound?
 *
 * Mirror of the iOS `CompoundChildEligibilityTests`. One refusal per check,
 * each built so every EARLIER check passes (pins the check order), plus the
 * allowed case: a nested compound that forms no loop.
 */

import {
  compoundChildLinkProblem,
  COMPOUND_CHILD_LINK_MESSAGES,
  type CompoundChildCandidate,
} from '../../src/algorithms/compoundChildEligibility';
import { TaskType } from '../../src/constants/enums';
import type { CompoundChild } from '../../src/types/compoundChild';

function link(parent: string, child: string, overrides: Partial<CompoundChild> = {}): CompoundChild {
  return {
    id: `${parent}->${child}`,
    compoundTaskId: parent,
    childTaskId: child,
    childIndex: 0,
    createdAt: '2026-09-01T12:00:00.000Z',
    updatedAt: '2026-09-01T12:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function candidate(id: string, overrides: Partial<CompoundChildCandidate> = {}): CompoundChildCandidate {
  return { id, type: TaskType.NORMAL, isDeleted: false, ...overrides };
}

// P contains Q contains R.
const chain: CompoundChild[] = [link('P', 'Q'), link('Q', 'R')];

describe('compoundChildLinkProblem', () => {
  it('refuses a compound containing itself', () => {
    expect(compoundChildLinkProblem('P', candidate('P', { type: TaskType.COMPOUND }), chain, new Set())).toBe(
      'A compound can’t contain itself.',
    );
  });

  it('refuses a task that is already a sub-task here', () => {
    expect(compoundChildLinkProblem('P', candidate('X'), [], new Set(['X']))).toBe(
      'That task is already a sub-task here.',
    );
  });

  it('refuses an achievement', () => {
    expect(
      compoundChildLinkProblem('P', candidate('A', { type: TaskType.ACHIEVEMENT }), [], new Set(['X'])),
    ).toBe('Achievements can’t be sub-tasks.');
  });

  it('refuses a deleted task', () => {
    expect(compoundChildLinkProblem('P', candidate('D', { isDeleted: true }), [], new Set(['X']))).toBe(
      'That task was deleted.',
    );
  });

  it('refuses a goal-less counter', () => {
    expect(
      compoundChildLinkProblem(
        'P',
        candidate('G', { type: TaskType.COUNTING, isCounter: true, maxCount: undefined }),
        [],
        new Set(['X']),
      ),
    ).toBe('Counters without a goal can’t be sub-tasks.');
  });

  it('allows a counter that has a goal', () => {
    expect(
      compoundChildLinkProblem(
        'P',
        candidate('G', { type: TaskType.COUNTING, isCounter: true, maxCount: 10 }),
        [],
        new Set(['X']),
      ),
    ).toBeNull();
  });

  it('refuses a link that would create a loop (P→Q→R; P under R)', () => {
    expect(
      compoundChildLinkProblem('R', candidate('P', { type: TaskType.COMPOUND }), chain, new Set()),
    ).toBe('That would create a loop — it already contains this compound.');
  });

  it('ignores soft-deleted links when looking for a loop', () => {
    const dead = [link('P', 'Q'), link('Q', 'R', { isDeleted: true })];
    expect(compoundChildLinkProblem('R', candidate('P', { type: TaskType.COMPOUND }), dead, new Set())).toBeNull();
  });

  it('allows a nested compound that forms no loop', () => {
    // Link Q (itself a compound containing R) under a fresh compound Z.
    expect(
      compoundChildLinkProblem('Z', candidate('Q', { type: TaskType.COMPOUND }), chain, new Set(['X'])),
    ).toBeNull();
  });

  it('exposes the six messages', () => {
    expect(Object.values(COMPOUND_CHILD_LINK_MESSAGES)).toHaveLength(6);
  });
});

// Check ORDER: each candidate trips its own check AND every later one, so
// swapping any adjacent pair of checks changes the returned message.
describe('compoundChildLinkProblem — check order', () => {
  // R's ancestors are Q and P (chain P→Q→R), so linking P or Q under R loops.
  const everything = { type: TaskType.ACHIEVEMENT, isDeleted: true } as const;

  it('self wins over duplicate / achievement / deleted / loop', () => {
    // R is its own candidate, in currentChildIds, an achievement, deleted —
    // and (with a self-link R→R) its own ancestor.
    const links = [...chain, link('R', 'R')];
    expect(compoundChildLinkProblem('R', candidate('R', everything), links, new Set(['R']))).toBe(
      'A compound can’t contain itself.',
    );
  });

  it('duplicate wins over achievement / deleted / loop', () => {
    expect(compoundChildLinkProblem('R', candidate('P', everything), chain, new Set(['P']))).toBe(
      'That task is already a sub-task here.',
    );
  });

  it('achievement wins over deleted / loop', () => {
    expect(compoundChildLinkProblem('R', candidate('P', everything), chain, new Set())).toBe(
      'Achievements can’t be sub-tasks.',
    );
  });

  it('deleted wins over goal-less / loop', () => {
    expect(
      compoundChildLinkProblem(
        'R',
        candidate('P', { type: TaskType.COUNTING, isCounter: true, isDeleted: true }),
        chain,
        new Set(),
      ),
    ).toBe('That task was deleted.');
  });

  it('goal-less wins over loop', () => {
    expect(
      compoundChildLinkProblem(
        'R',
        candidate('P', { type: TaskType.COUNTING, isCounter: true }),
        chain,
        new Set(),
      ),
    ).toBe('Counters without a goal can’t be sub-tasks.');
  });
});
