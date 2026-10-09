import { useState } from 'react';
import { useSearchParams } from 'react-router-dom';

/**
 * The Counters hub's and Counter Detail's "Show expired tasks" setting
 * (§Member rules B3 RC9), carried in the URL as `?showExpired=1` — the one
 * cross-page mechanism available here — so the two screens agree: the hub's
 * card tap carries it into Detail, Detail's back link carries it home, and a
 * flip on either screen is what the other opens with. Session-only, default
 * OFF. Mirrors iOS, where the hub passes its `@State` into
 * `CounterDetailView` and Detail reports flips back (`onShowExpiredChange`).
 *
 * The returned value is a LOCAL mirror of the URL, set in the same event as
 * the click. React Router 7 commits `setSearchParams` inside a
 * `startTransition`, so a checkbox controlled straight off the URL snaps back
 * unchecked for a frame or more after the click (React restores a controlled
 * input synchronously; the transition lands later) — a visible flicker, and a
 * flaky `check()` in e2e. The mirror still follows the URL when it changes
 * from elsewhere (Back, a link).
 *
 * @returns `[showExpired, setShowExpired]` — the setter updates the mirror
 *   and replaces the URL param.
 */
export function useShowExpiredParam(): [boolean, (next: boolean) => void] {
  const [searchParams, setSearchParams] = useSearchParams();
  const urlShowExpired = searchParams.get('showExpired') === '1';
  const [showExpired, setShowExpiredState] = useState(urlShowExpired);
  const [mirroredUrlValue, setMirroredUrlValue] = useState(urlShowExpired);
  if (urlShowExpired !== mirroredUrlValue) {
    setMirroredUrlValue(urlShowExpired);
    setShowExpiredState(urlShowExpired);
  }

  function setShowExpired(next: boolean): void {
    setShowExpiredState(next);
    const params = new URLSearchParams(searchParams);
    if (next) params.set('showExpired', '1');
    else params.delete('showExpired');
    setSearchParams(params, { replace: true });
  }

  return [showExpired, setShowExpired];
}
