import { useEffect, useState } from 'react';
import { usePreferences } from './usePreferences';

/**
 * Resolved concrete theme — what actually gets applied to the DOM.
 */
export type AppliedTheme = 'light' | 'dark';

const MEDIA_QUERY = '(prefers-color-scheme: dark)';

/**
 * Resolves the user's `theme` preference (`'light' | 'dark' | 'system'`) to
 * a concrete applied theme and mirrors it to the `data-theme` attribute on
 * `<html>`. When the preference is `'system'`, follows the OS colour-scheme
 * and live-updates when the OS setting changes.
 *
 * Must be mounted inside an authenticated layout because `usePreferences`
 * reads from the signed-in user row.
 */
export function useAppliedTheme(): AppliedTheme {
  const [preferences] = usePreferences();

  // Track the OS setting so `system` mode reacts live.
  const [osPrefersDark, setOsPrefersDark] = useState<boolean>(() =>
    typeof window !== 'undefined'
      ? window.matchMedia?.(MEDIA_QUERY).matches ?? false
      : false
  );

  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return;
    const mq = window.matchMedia(MEDIA_QUERY);
    const handler = (e: MediaQueryListEvent): void => setOsPrefersDark(e.matches);
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, []);

  const applied: AppliedTheme =
    preferences.theme === 'system'
      ? osPrefersDark ? 'dark' : 'light'
      : preferences.theme;

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', applied);
  }, [applied]);

  return applied;
}
