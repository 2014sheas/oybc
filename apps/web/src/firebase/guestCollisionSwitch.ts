/**
 * Guest-upgrade collision "switch to the existing account" — the ordering
 * decision, extracted pure so the **verify-before-destroy** invariant
 * (docs/GUEST_MODE.md §Upgrade) is under test. Mirrors iOS
 * `GuestCollisionSwitch.swift` 1:1.
 *
 * No imports on purpose: this module must stay free of Firebase/Dexie so the
 * decision table is unit-testable without either.
 */

/** How the sign-in to the pre-existing account turned out. */
export type CollisionSignInOutcome = 'success' | 'wrongPassword' | 'cancelled' | 'otherError';

/** One step of the collision switch, in the order it must happen. */
export type CollisionEffect =
  /** Sign into the pre-existing account (while still anonymous). */
  | 'signInExisting'
  /** Drop the discarded guest's anon-stamped pending pushes. */
  | 'clearAnonQueue'
  /** Leave the upgrade surface — the app is now on the existing account. */
  | 'switchSession'
  /** Stop: the guest session + local data stay exactly as they were. */
  | 'keepGuestData';

/**
 * The ordered effects of a collision switch for a given sign-in outcome.
 * Sign-in ALWAYS comes first; nothing destructive happens unless it succeeded.
 *
 * @param outcome - Result of the sign-in to the existing account
 * @returns The full ordered plan (including the sign-in step itself)
 */
export function collisionSwitchEffects(outcome: CollisionSignInOutcome): CollisionEffect[] {
  if (outcome === 'success') return ['signInExisting', 'clearAnonQueue', 'switchSession'];
  return ['signInExisting', 'keepGuestData'];
}

/**
 * Classify a sign-in failure. Only the decision table consumes this; every
 * failure keeps guest data, the split exists so the table reads by cause.
 *
 * @param error - The error thrown by the sign-in
 * @returns The failure outcome (never `'success'`)
 */
export function classifySignInOutcome(error: unknown): Exclude<CollisionSignInOutcome, 'success'> {
  const code = (error as { code?: string } | undefined)?.code;
  if (code === 'auth/wrong-password' || code === 'auth/invalid-credential') return 'wrongPassword';
  if (
    code === 'auth/popup-closed-by-user' ||
    code === 'auth/cancelled-popup-request' ||
    code === 'auth/user-cancelled'
  ) {
    return 'cancelled';
  }
  return 'otherError';
}

/** The side effects `runCollisionSwitch` drives. */
export interface CollisionSwitchDeps {
  signInExisting: () => Promise<void>;
  clearAnonQueue: () => Promise<void>;
  switchSession: () => void;
}

/**
 * Execute the collision switch strictly in `collisionSwitchEffects` order.
 * Effects the success plan puts before `signInExisting` run first (by the
 * invariant there are none); if the sign-in throws, the plan for that failure
 * outcome takes over from its sign-in step and the sign-in error is then
 * rethrown so the caller can surface it, having destroyed nothing.
 *
 * @param deps - The concrete side effects
 * @throws The sign-in error on any failed sign-in; any error from a later effect
 */
export async function runCollisionSwitch(deps: CollisionSwitchDeps): Promise<void> {
  const plan = collisionSwitchEffects('success');
  const signInAt = plan.indexOf('signInExisting');
  await runEffects(plan.slice(0, signInAt), deps);
  try {
    await deps.signInExisting();
  } catch (err) {
    const failurePlan = collisionSwitchEffects(classifySignInOutcome(err));
    await runEffects(failurePlan.slice(failurePlan.indexOf('signInExisting') + 1), deps);
    throw err;
  }
  await runEffects(plan.slice(signInAt + 1), deps);
}

/** Run each effect in order. `keepGuestData` is deliberately a no-op marker. */
async function runEffects(effects: CollisionEffect[], deps: CollisionSwitchDeps): Promise<void> {
  for (const effect of effects) {
    switch (effect) {
      case 'signInExisting':
        await deps.signInExisting();
        break;
      case 'clearAnonQueue':
        await deps.clearAnonQueue();
        break;
      case 'switchSession':
        deps.switchSession();
        break;
      case 'keepGuestData':
        break;
    }
  }
}
