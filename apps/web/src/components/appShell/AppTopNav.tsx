import { useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '../../firebase/useAuth';
import { usePreferences } from '../../hooks/usePreferences';
import type { AppliedTheme } from '../../hooks/useAppliedTheme';
import { RisoBrandMark, RisoButton, RisoIcon, RisoSegmented } from '../riso';
import { NAV_ITEMS, isNavItemActive } from './navItems';
import styles from './AppTopNav.module.css';

/** Day/Night — the nav's quick toggle (the full System/Light/Dark control
 *  lives on the Profile screen). */
type NavTheme = 'light' | 'dark';

export interface AppTopNavProps {
  /** Active-board count for the Boards badge (subscribed once in AppShell). */
  activeBoardCount: number;
  /** Resolved theme (light/dark), threaded from AuthenticatedLayout's single
   *  `useAppliedTheme` so the toggle reflects the applied state without
   *  re-subscribing. */
  appliedTheme: AppliedTheme;
}

/**
 * Riso top nav — the sticky billboard bar for the signed-in app. Brand +
 * primary tabs (desktop) + theme toggle + New board + avatar. At ≤760px the
 * tabs detach into `AppBottomNav` and this collapses to icon-only controls.
 */
export function AppTopNav({ activeBoardCount, appliedTheme }: AppTopNavProps): React.ReactElement {
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const { user } = useAuth();
  const [, updatePrefs] = usePreferences();
  // Display the RESOLVED theme (never 'system') so the toggle's selected state
  // matches what's actually applied; the full System control lives on Profile.
  const theme: NavTheme = appliedTheme;

  const initial = (user?.displayName || user?.email || 'O').trim().charAt(0).toUpperCase();

  return (
    <header className={styles.nav}>
      <div className={styles.inner}>
        <RisoBrandMark size={38} />
        <div className={styles.word}>OYBC</div>

        <nav className={styles.tabs} aria-label="Primary">
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
                {item.label}
                {item.path === '/boards' && activeBoardCount > 0 && (
                  <span className={styles.count}>{activeBoardCount}</span>
                )}
              </button>
            );
          })}
        </nav>

        <div className={styles.right}>
          <RisoSegmented<NavTheme>
            variant="pill"
            aria-label="Theme"
            value={theme}
            onChange={(v) => updatePrefs({ theme: v })}
            options={[
              { value: 'light', label: <><RisoIcon name="sun" size={13} /> <span className={styles.segLabel}>Day</span></> },
              { value: 'dark', label: <><RisoIcon name="moon" size={13} /> <span className={styles.segLabel}>Night</span></> },
            ]}
          />
          <RisoButton
            kind="primary"
            aria-label="New board"
            icon={<RisoIcon name="plus" size={16} />}
            // Board Creation Split (web PR C) — opens the ONE-OFF wizard
            // directly (mode fixed at entry); `useNewWizardParam` on
            // `CreateHubPage` consumes the deep link. The recurring
            // entry point is the hub's own BLUE card.
            onClick={() => navigate('/create?newBoard=one-off')}
          >
            <span className={styles.newBoardLabel}>New board</span>
          </RisoButton>
          <button
            type="button"
            className={styles.avatar}
            style={{ background: 'var(--riso-gold)' }}
            aria-label="You"
            onClick={() => navigate('/profile')}
          >
            {initial}
          </button>
        </div>
      </div>
    </header>
  );
}
