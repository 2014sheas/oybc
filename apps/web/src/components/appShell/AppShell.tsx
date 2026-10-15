import type { ReactNode } from 'react';
import { isBoardActiveForList } from '@oybc/shared';
import { useAuth } from '../../firebase/useAuth';
import { useBoards } from '../../hooks/useBoards';
import { useBackstopAutoSeal } from '../../hooks/useBackstopAutoSeal';
import type { AppliedTheme } from '../../hooks/useAppliedTheme';
import { AppTopNav } from './AppTopNav';
import { AppBottomNav } from './AppBottomNav';
import styles from './AppShell.module.css';

/**
 * Riso app shell for the signed-in app — sticky top nav, a centered paper
 * canvas for the routed screen, and a mobile bottom tab bar. Replaces the old
 * bottom-only `TabBar`. Screen content is re-skinned phase-by-phase; this is
 * the chrome it sits inside. See docs/RISO_WEB.md.
 *
 * Owns the single active-boards subscription and passes the count to both nav
 * bars (which both render the Boards badge) so there's only one live query.
 * `appliedTheme` is resolved once by `AuthenticatedLayout` and threaded to the
 * top nav so the theme toggle reflects the applied state without re-subscribing.
 */
export function AppShell({
  children,
  appliedTheme,
}: {
  children: ReactNode;
  appliedTheme: AppliedTheme;
}): React.ReactElement {
  const { user } = useAuth();
  const boards = useBoards(user?.id);
  // The Boards badge counts boards still in play — the Boards tab's own
  // rule, not the stored status (which stays ACTIVE on an ended board).
  const activeCount = boards.filter((b) => isBoardActiveForList(b)).length;

  // Windowed Completion — backstop auto-seal + stale-stats self-heal on ANY
  // authenticated surface, not just the Boards tab. A deep link straight to
  // `/boards/:id` (or /tasks, /profile, …) previously never healed because the
  // hook only mounted on `BoardsPage`. Mounting it here (the shell wraps every
  // authenticated route) closes that hole; `BoardsPage` keeps its own mount so
  // navigating to Boards still re-runs the pass. Both `sealBoard` and
  // `reDeriveActiveBoards` are idempotent, so the double mount is harmless.
  useBackstopAutoSeal(user?.id);

  return (
    <div className={`${styles.app} riso-grain`}>
      <AppTopNav activeBoardCount={activeCount} appliedTheme={appliedTheme} />
      <main className={styles.main}>
        <div className={styles.canvas}>{children}</div>
      </main>
      <AppBottomNav activeBoardCount={activeCount} />
    </div>
  );
}
