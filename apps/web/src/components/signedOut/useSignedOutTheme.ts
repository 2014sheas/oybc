import { useCallback, useEffect, useState } from 'react';

export type SignedOutTheme = 'light' | 'dark';

const STORAGE_KEY = 'oybc-web-theme';

/** Read the persisted choice, falling back to the OS color-scheme. */
function initialTheme(): SignedOutTheme {
  if (typeof window === 'undefined') return 'light';
  const stored = window.localStorage.getItem(STORAGE_KEY);
  if (stored === 'light' || stored === 'dark') return stored;
  return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

/**
 * Theme state for the signed-out marketing home, which renders BEFORE auth and
 * so can't use `useAppliedTheme` (that reads the signed-in user's preference).
 *
 * Mirrors the resolved theme to `data-theme` on `<html>` — the same attribute
 * `useAppliedTheme` drives — so the Riso tokens resolve correctly. Once the
 * user signs in, `AuthGate` swaps to the authenticated layout and
 * `useAppliedTheme` takes ownership of the attribute. Persists the explicit
 * choice to localStorage so a returning visitor keeps it.
 */
export function useSignedOutTheme(): [SignedOutTheme, (theme: SignedOutTheme) => void] {
  const [theme, setTheme] = useState<SignedOutTheme>(initialTheme);

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
  }, [theme]);

  const choose = useCallback((next: SignedOutTheme) => {
    setTheme(next);
    try {
      window.localStorage.setItem(STORAGE_KEY, next);
    } catch {
      // Private-mode / storage-disabled: keep the in-memory choice, skip persist.
    }
  }, []);

  return [theme, choose];
}
