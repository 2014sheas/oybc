import { Link } from 'react-router-dom';
import profileStyles from './ProfilePage.module.css';
import styles from './HelpPage.module.css';

/**
 * HelpPage — /profile/help (Profile reorg PR1, `design_handoff_profile_reorg/README.md`
 * §Screens — iOS #3 / Web §5b "Help & getting started" link target).
 *
 * Web has no onboarding tutorial (iOS-only, `docs/RISO_...`/CLAUDE.md
 * "Onboarding tutorial is iOS-only") — the owner's 2026-09-30 ruling
 * (owner decision 1) treats that as a real pre-release design gap rather
 * than something to fake, so this page shows a clearly-marked "Coming soon"
 * placeholder in its place. "Contact support" is likewise a placeholder
 * (owner decision 4) until a real support address exists. Nothing else
 * belongs on this page — do not add FAQ content.
 */
export function HelpPage(): React.ReactElement {
  return (
    <div className={styles.content}>
      <div className={profileStyles.subPageHeader}>
        <Link to="/profile/settings" className={profileStyles.backLink} aria-label="Back to Settings">
          &larr;
        </Link>
        <div>
          <div className={styles.kicker}>Settings</div>
          <h1 className={profileStyles.header}>Help</h1>
        </div>
      </div>

      <div className={styles.card}>
        <h2 className={styles.cardTitle}>Getting started</h2>
        <p className={styles.cardBody}>Coming soon</p>
      </div>

      <div className={styles.card}>
        <div className={styles.disabledRow} aria-disabled="true">
          <span className={styles.disabledLabel}>Contact support</span>
          <span className={styles.disabledCaption}>Coming soon</span>
        </div>
      </div>
    </div>
  );
}
