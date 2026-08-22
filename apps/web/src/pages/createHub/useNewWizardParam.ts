import { useEffect } from 'react';
import { useSearchParams } from 'react-router-dom';

/**
 * Parse the `newBoard` URL search param into a mode-locked launch signal:
 * `'one-off'` → `false` (one-off wizard), `'recurring'` → `true` (recurring
 * wizard). Returns `undefined` when absent or malformed.
 */
function parseNewBoardParam(value: string | null): boolean | undefined {
  switch (value) {
    case 'one-off':
      return false;
    case 'recurring':
      return true;
    default:
      return undefined;
  }
}

/**
 * Board Creation Split (web PR C) — top-nav deep link:
 * `/create?newBoard=one-off` (or `=recurring`) opens the hub straight into
 * a fresh, mode-locked wizard. Watches the URL; when a valid value
 * appears, invokes `onConsumed(startRecurring)` once and clears the param
 * so a wizard cancel + manual re-entry doesn't re-arm it. Mirrors the
 * existing `useRecurringTimeframeParam` / `useResumeDraftParam` pattern.
 *
 * `onConsumed` should be stable (wrapped in `useCallback`) — it is in the
 * effect's dependency list.
 */
export function useNewWizardParam(onConsumed: (startRecurring: boolean) => void): void {
  const [searchParams, setSearchParams] = useSearchParams();

  useEffect(() => {
    const startRecurring = parseNewBoardParam(searchParams.get('newBoard'));
    if (startRecurring === undefined) return;
    onConsumed(startRecurring);
    setSearchParams(
      (prev) => {
        const next = new URLSearchParams(prev);
        next.delete('newBoard');
        return next;
      },
      { replace: true },
    );
  }, [searchParams, setSearchParams, onConsumed]);
}
