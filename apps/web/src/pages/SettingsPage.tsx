import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import type { UserPreferences } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { SIGN_OUT_QUEUE_CLEAR_FAILED_MESSAGE } from '../firebase/authService';
import {
  EMPTY_PROVIDER_STATE,
  deleteAccount,
  friendlyError,
  getProviderState,
  type ProviderState,
} from '../firebase/accountSecurity';
import { usePreferences } from '../hooks';
import { RisoSegmented, RisoButton } from '../components/riso';
import { UpgradeModal } from '../components/signedOut/UpgradeModal';
import { useModalA11y } from '../hooks/useModalA11y';
import profileStyles from './ProfilePage.module.css';
import styles from './SettingsPage.module.css';

/**
 * Human-readable connected-providers fragment for the Account & security
 * caption, e.g. "Apple, Google connected". Password-only accounts (or a
 * guest with no providers yet) omit the fragment entirely.
 */
function connectedProvidersCaption(providers: ProviderState): string | null {
  const names: string[] = [];
  if (providers.hasApple) names.push('Apple');
  if (providers.hasGoogle) names.push('Google');
  if (names.length === 0) return null;
  return `${names.join(', ')} connected`;
}

/**
 * Board-renewal "prompt me" toggles (Phase 6.1) — moved here from
 * `/profile/board-settings` (Profile reorg PR1, owner decision 3). Web has
 * no Notifications page, so these live in a "BOARD RENEWALS" card on
 * Settings instead of iOS's Notifications sub-page. Same `recurring*Enabled`
 * prefs, same labels as before the move.
 */
const RENEWAL_TOGGLES: {
  key: 'recurringDailyEnabled' | 'recurringWeeklyEnabled' | 'recurringMonthlyEnabled' | 'recurringYearlyEnabled';
  label: string;
}[] = [
  { key: 'recurringDailyEnabled', label: 'Prompt for daily board' },
  { key: 'recurringWeeklyEnabled', label: 'Prompt for weekly board' },
  { key: 'recurringMonthlyEnabled', label: 'Prompt for monthly board' },
  { key: 'recurringYearlyEnabled', label: 'Prompt for yearly board' },
];

/**
 * SettingsPage — /profile/settings (Profile reorg PR1, `design_handoff_profile_reorg/README.md`
 * §Screens — Web, frame `#5b`). Pushed from the new Settings pill button on
 * `ProfilePage`. Hosts everything that used to live directly on Profile but
 * is touched rarely: Theme, Account & security, Help & getting started,
 * Board renewals, the dev-only Playground link, Sign Out, and the version
 * footer.
 *
 * Sync UI (`SyncStatusIndicator`) is NOT relocated here — it's deleted
 * entirely (owner decision 2, 2026-09-30): sync keeps running silently with
 * no user-facing status surface.
 */
export function SettingsPage(): React.ReactElement {
  const { user, signOut, isAnonymous } = useAuth();
  const [prefs, updatePrefs] = usePreferences();
  const [providers, setProviders] = useState<ProviderState>(EMPTY_PROVIDER_STATE);
  const [showSignOutConfirm, setShowSignOutConfirm] = useState(false);
  const [signOutError, setSignOutError] = useState<string | null>(null);
  const [showDiscardConfirm, setShowDiscardConfirm] = useState(false);
  const [discardBusy, setDiscardBusy] = useState(false);
  const [discardError, setDiscardError] = useState<string | null>(null);
  const [showUpgradeModal, setShowUpgradeModal] = useState(false);

  // Load linked-provider state for the Account & security caption. A guest
  // has none yet — EMPTY_PROVIDER_STATE covers that (getProviderState()
  // itself would also resolve empty for an anonymous user with no email
  // provider, so this is mostly for the signed-in case).
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const state = await getProviderState();
      if (!cancelled) setProviders(state);
    })();
    return () => {
      cancelled = true;
    };
  }, [user?.id]);

  const handleDiscardGuestData = useCallback(async () => {
    setDiscardBusy(true);
    setDiscardError(null);
    try {
      await deleteAccount();
    } catch (err) {
      setDiscardError(friendlyError(err));
      setDiscardBusy(false);
    }
  }, []);

  const handleSignOut = useCallback(async () => {
    setSignOutError(null);
    try {
      await signOut();
    } catch (err) {
      setSignOutError(
        err instanceof Error && err.message === SIGN_OUT_QUEUE_CLEAR_FAILED_MESSAGE
          ? err.message
          : friendlyError(err)
      );
    }
  }, [signOut]);

  const { ref: signOutModalRef, props: signOutModalProps } = useModalA11y<HTMLDivElement>({
    open: showSignOutConfirm,
    onCancel: () => setShowSignOutConfirm(false),
    initialFocus: 'cancel',
  });
  const { ref: discardModalRef, props: discardModalProps } = useModalA11y<HTMLDivElement>({
    open: showDiscardConfirm,
    onCancel: () => {
      if (!discardBusy) setShowDiscardConfirm(false);
    },
    initialFocus: 'cancel',
  });

  const providersCaption = connectedProvidersCaption(providers);
  const accountCaption = providersCaption
    ? `${user?.email ?? ''} · ${providersCaption}`
    : (user?.email ?? '');

  return (
    <div className={styles.content}>
      <div className={profileStyles.subPageHeader}>
        <Link to="/profile" className={profileStyles.backLink} aria-label="Back to Profile">
          &larr;
        </Link>
        <h1 className={profileStyles.header}>Settings</h1>
      </div>

      {/* Appearance */}
      <div className={profileStyles.sectionLabel}>Appearance</div>
      <div className={profileStyles.card}>
        <div className={profileStyles.settingsRow}>
          <span className={profileStyles.rowLabel}>Theme</span>
          <RisoSegmented<UserPreferences['theme']>
            aria-label="Theme"
            variant="pill"
            value={prefs.theme}
            onChange={(value) => updatePrefs({ theme: value })}
            options={[
              { value: 'system', label: 'System' },
              { value: 'light', label: 'Light' },
              { value: 'dark', label: 'Dark' },
            ]}
          />
        </div>
      </div>

      {/* Preferences */}
      <div className={profileStyles.sectionLabel}>Preferences</div>
      <div className={profileStyles.card}>
        {/* Guest mode: the "Save your account" CTA takes the Account &
            security row's place (docs/GUEST_MODE.md §In-app guest treatment) —
            a guest has no linked providers to manage yet. */}
        {isAnonymous ? (
          <div className={profileStyles.saveAccountRow}>
            <RisoButton kind="primary" fullWidth onClick={() => setShowUpgradeModal(true)}>
              Save your account
            </RisoButton>
          </div>
        ) : (
          <Link to="/profile/account-security" className={styles.prefRow}>
            <span className={styles.prefRowText}>
              <span className={styles.prefRowLabel}>Account &amp; security</span>
              <span className={styles.prefRowCaption}>{accountCaption}</span>
            </span>
            <span className={styles.prefRowArrow} aria-hidden="true">
              &rarr;
            </span>
          </Link>
        )}
        <Link to="/profile/help" className={styles.prefRow}>
          <span className={styles.prefRowText}>
            <span className={styles.prefRowLabel}>Help &amp; getting started</span>
            {/* Web has no tutorial (iOS-only) — placeholder caption, owner
                decision 1: a real design gap tracked pre-release, not a bug. */}
            <span className={styles.prefRowCaption}>Coming soon</span>
          </span>
          <span className={styles.prefRowArrow} aria-hidden="true">
            &rarr;
          </span>
        </Link>
      </div>

      {/* Board renewals — moved from /profile/board-settings (owner decision 3).
          Web has no Notifications page, so this "prompt me" group lives here
          instead of iOS's Notifications sub-page. */}
      <div className={profileStyles.sectionLabel}>Board renewals</div>
      <div className={profileStyles.card}>
        {RENEWAL_TOGGLES.map(({ key, label }) => (
          <div className={profileStyles.settingsRow} key={key}>
            <label className={profileStyles.rowLabel} htmlFor={`pref-${key}`}>
              {label}
            </label>
            <label className={styles.toggleSwitch}>
              <input
                id={`pref-${key}`}
                type="checkbox"
                checked={prefs[key]}
                onChange={(e) => updatePrefs({ [key]: e.target.checked } as Partial<UserPreferences>)}
              />
              <span className={styles.toggleTrack} />
            </label>
          </div>
        ))}
      </div>

      {/* Developer tools — dev builds only (the Playground can wipe the real
          local database, so this section, and the route it links to, must
          not be reachable in production). */}
      {import.meta.env.DEV && (
        <>
          <div className={profileStyles.sectionLabel}>Developer</div>
          <div className={profileStyles.card}>
            <Link to="/playground" className={`${profileStyles.settingsRow} ${profileStyles.rowLink}`}>
              <span className={profileStyles.rowLabel}>Playground</span>
              <span className={profileStyles.rowArrow}>&rarr;</span>
            </Link>
          </div>
        </>
      )}

      {/* Sign out — a guest gets the destructive "Discard guest data" in its
          place (docs/GUEST_MODE.md §Deletion). */}
      {isAnonymous ? (
        <button
          type="button"
          className={profileStyles.signOutButton}
          onClick={() => setShowDiscardConfirm(true)}
        >
          Discard guest data
        </button>
      ) : (
        <button
          type="button"
          className={profileStyles.signOutButton}
          onClick={() => {
            setSignOutError(null);
            setShowSignOutConfirm(true);
          }}
        >
          Sign Out
        </button>
      )}

      <p className={profileStyles.versionFooter}>OYBC · v{__APP_VERSION__}</p>

      {/* Sign-out confirmation modal */}
      {showSignOutConfirm && (
        <div
          className={profileStyles.confirmBackdrop}
          onClick={() => setShowSignOutConfirm(false)}
        >
          <div
            ref={signOutModalRef}
            className={profileStyles.confirmModal}
            onClick={(e) => e.stopPropagation()}
            role="dialog"
            aria-labelledby="sign-out-title"
            {...signOutModalProps}
          >
            <h2 id="sign-out-title" className={profileStyles.confirmTitle}>
              Sign out?
            </h2>
            <p className={profileStyles.confirmBody}>Are you sure you want to sign out?</p>
            {signOutError && <p className={profileStyles.nameError}>{signOutError}</p>}
            <div className={profileStyles.confirmActions}>
              <button
                type="button"
                className={profileStyles.confirmCancel}
                data-modal-cancel
                onClick={() => setShowSignOutConfirm(false)}
              >
                Cancel
              </button>
              <button
                type="button"
                className={profileStyles.confirmDestructive}
                onClick={() => void handleSignOut()}
              >
                Sign Out
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Discard-guest-data confirmation modal (docs/GUEST_MODE.md §Deletion) */}
      {showDiscardConfirm && (
        <div
          className={profileStyles.confirmBackdrop}
          onClick={() => !discardBusy && setShowDiscardConfirm(false)}
        >
          <div
            ref={discardModalRef}
            className={profileStyles.confirmModal}
            onClick={(e) => e.stopPropagation()}
            role="dialog"
            aria-labelledby="discard-guest-title"
            {...discardModalProps}
          >
            <h2 id="discard-guest-title" className={profileStyles.confirmTitle}>
              Discard guest data?
            </h2>
            <p className={profileStyles.confirmBody}>
              This permanently erases every board, streak, and GREENLOG on this device. Guest data
              isn’t backed up to an account, so this can’t be undone.
            </p>
            {discardError && <p className={profileStyles.nameError}>{discardError}</p>}
            <div className={profileStyles.confirmActions}>
              <button
                type="button"
                className={profileStyles.confirmCancel}
                data-modal-cancel
                onClick={() => setShowDiscardConfirm(false)}
                disabled={discardBusy}
              >
                Cancel
              </button>
              <button
                type="button"
                className={profileStyles.confirmDestructive}
                onClick={() => void handleDiscardGuestData()}
                disabled={discardBusy}
              >
                {discardBusy ? 'Discarding…' : 'Discard forever'}
              </button>
            </div>
          </div>
        </div>
      )}

      {showUpgradeModal && <UpgradeModal onClose={() => setShowUpgradeModal(false)} />}
    </div>
  );
}
