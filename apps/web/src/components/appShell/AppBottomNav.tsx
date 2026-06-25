import { useLocation, useNavigate } from 'react-router-dom';
import { RisoIcon } from '../riso';
import { NAV_ITEMS, isNavItemActive } from './navItems';
import styles from './AppBottomNav.module.css';

export interface AppBottomNavProps {
  /** Active-board count for the Boards badge (subscribed once in AppShell). */
  activeBoardCount: number;
}

/**
 * Mobile bottom tab bar — the primary tabs (Home · Boards · Tasks · You),
 * rendered as a fixed bar at ≤760px and hidden on desktop (where `AppTopNav`
 * carries them). Shares `NAV_ITEMS` with the top nav; the active-board count is
 * passed from `AppShell` so there's a single live query.
 */
export function AppBottomNav({ activeBoardCount }: AppBottomNavProps): React.ReactElement {
  const navigate = useNavigate();
  const { pathname } = useLocation();

  return (
    <nav className={styles.bar} aria-label="Primary">
      {NAV_ITEMS.map((item) => {
        const active = isNavItemActive(pathname, item.path);
        return (
          <button
            key={item.path}
            type="button"
            className={[styles.tab, active ? styles.on : ''].filter(Boolean).join(' ')}
            aria-current={active ? 'page' : undefined}
            onClick={() => navigate(item.path)}
          >
            <RisoIcon name={item.icon} />
            <span>
              {item.label}
              {item.path === '/boards' && activeBoardCount > 0 && (
                <span className={styles.count}>{activeBoardCount}</span>
              )}
            </span>
          </button>
        );
      })}
    </nav>
  );
}
