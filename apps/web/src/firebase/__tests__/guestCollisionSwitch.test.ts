import { describe, it, expect } from 'vitest';
import {
  classifySignInOutcome,
  collisionSwitchEffects,
  runCollisionSwitch,
  type CollisionSwitchDeps,
} from '../guestCollisionSwitch';

/**
 * Guest-upgrade collision — **verify before destroy** (docs/GUEST_MODE.md
 * §Upgrade, CLAUDE.md §Guest Mode). Sign into the existing account FIRST;
 * only a successful sign-in may clear the anon sync queue. Mirrors iOS
 * `GuestCollisionSwitchTests`.
 */

/** Fake deps that record the order effects actually ran in. */
function recordingDeps(signIn: () => Promise<void>): { deps: CollisionSwitchDeps; log: string[] } {
  const log: string[] = [];
  return {
    log,
    deps: {
      signInExisting: async () => {
        log.push('signInExisting');
        await signIn();
      },
      clearAnonQueue: async () => {
        log.push('clearAnonQueue');
      },
      switchSession: () => {
        log.push('switchSession');
      },
    },
  };
}

describe('collisionSwitchEffects (decision table)', () => {
  it('success: sign in, THEN clear the anon queue, THEN switch', () => {
    expect(collisionSwitchEffects('success')).toEqual(['signInExisting', 'clearAnonQueue', 'switchSession']);
  });

  it.each(['wrongPassword', 'cancelled', 'otherError'] as const)(
    '%s: sign-in attempted, then stop with guest data intact',
    (outcome) => {
      expect(collisionSwitchEffects(outcome)).toEqual(['signInExisting', 'keepGuestData']);
    },
  );
});

describe('classifySignInOutcome', () => {
  it('maps Firebase codes to outcomes', () => {
    expect(classifySignInOutcome({ code: 'auth/wrong-password' })).toBe('wrongPassword');
    expect(classifySignInOutcome({ code: 'auth/invalid-credential' })).toBe('wrongPassword');
    expect(classifySignInOutcome({ code: 'auth/popup-closed-by-user' })).toBe('cancelled');
    expect(classifySignInOutcome({ code: 'auth/cancelled-popup-request' })).toBe('cancelled');
    expect(classifySignInOutcome({ code: 'auth/network-request-failed' })).toBe('otherError');
    expect(classifySignInOutcome(new Error('boom'))).toBe('otherError');
  });
});

describe('runCollisionSwitch (the executor confirmSwitchAccount uses)', () => {
  it('success runs sign-in → clear queue → switch, in that order', async () => {
    const { deps, log } = recordingDeps(async () => {});
    await runCollisionSwitch(deps);
    expect(log).toEqual(['signInExisting', 'clearAnonQueue', 'switchSession']);
  });

  it.each([
    ['wrong password', { code: 'auth/invalid-credential' }],
    ['cancelled OAuth', { code: 'auth/popup-closed-by-user' }],
    ['other error', { code: 'auth/network-request-failed' }],
  ])('%s: rethrows the sign-in error and never clears the queue or switches', async (_label, error) => {
    const { deps, log } = recordingDeps(async () => {
      throw error;
    });
    await expect(runCollisionSwitch(deps)).rejects.toBe(error);
    expect(log).toEqual(['signInExisting']);
  });
});
