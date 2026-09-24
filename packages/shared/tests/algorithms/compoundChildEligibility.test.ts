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

  it('exposes the five messages', () => {
    expect(Object.values(COMPOUND_CHILD_LINK_MESSAGES)).toHaveLength(5);
  });
});
