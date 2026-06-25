import type { ReactNode } from 'react';
import { BoardStatus } from '@oybc/shared';
import { useAuth } from '../../firebase/useAuth';
import { useBoards } from '../../hooks/useBoards';
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
 */
export function AppShell({ children }: { children: ReactNode }): React.ReactElement {
  const { user } = useAuth();
  const boards = useBoards(user?.id);
  const activeCount = boards.filter((b) => b.status === BoardStatus.ACTIVE).length;

  return (
    <div className={`${styles.app} riso-grain`}>
      <AppTopNav activeBoardCount={activeCount} />
      <main className={styles.main}>
        <div className={styles.canvas}>{children}</div>
      </main>
      <AppBottomNav activeBoardCount={activeCount} />
    </div>
  );
}
