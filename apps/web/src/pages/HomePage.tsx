import { useNavigate } from 'react-router-dom';
import { RisoButton, RisoCard, RisoIcon, RisoSectionLabel } from '../components/riso';
import styles from './HomePage.module.css';

/** "Saturday · June 20" — the greeting kicker date. */
function greetingDate(): string {
  return new Date().toLocaleDateString(undefined, {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
  });
}

/**
 * Home / Resume — the signed-in landing (the new default route).
 *
 * Phase 2a ships the greeting + a jump-to-boards prompt so the Home tab has a
 * real destination. Phase 2b fills in the streak pill, the "Jump back in"
 * resume panel with a live board poster, and the active-boards rail (which
 * need the boards/streaks data layer). The tutorial card from the prototype is
 * intentionally omitted — web has no tutorial system yet (iOS-only).
 */
export function HomePage(): React.ReactElement {
  const navigate = useNavigate();

  return (
    <div>
      <div className={styles.greet}>
        <div>
          <RisoSectionLabel variant="kicker">{greetingDate()}</RisoSectionLabel>
          <h1 className={styles.title}>Welcome back.</h1>
          <p className={styles.sub}>
            Pick up where you left off, or print something new. The press is warm.
          </p>
        </div>
      </div>

      <div className={styles.sectionHead}>
        <h2 className={styles.sectionTitle}>Jump back in</h2>
        <RisoButton kind="ghost" size="small" onClick={() => navigate('/boards')}>
          All boards
        </RisoButton>
      </div>
      <RisoCard padded className={styles.placeholder}>
        <p className={styles.placeholderText}>
          Your active boards live here. Open one to keep filling squares, or start a fresh board.
        </p>
        <RisoButton
          kind="primary"
          icon={<RisoIcon name="plus" size={16} />}
          onClick={() => navigate('/create')}
        >
          New board
        </RisoButton>
      </RisoCard>
    </div>
  );
}
