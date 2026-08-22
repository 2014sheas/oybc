import { RisoIcon, type RisoIconName } from '../riso';
import styles from './CreateHubBoardCTA.module.css';

/**
 * Which of the two board-creation entry points this card represents.
 * Board Creation Split (web PR C) — mode is fixed per card; there is no
 * shared "decide later" CTA anymore. Mirrors iOS `CreateHubBoardCTAKind`.
 */
export type CreateHubBoardCTAKind = 'oneOff' | 'recurring';

export interface CreateHubBoardCTAProps {
  /** Which entry point this card launches. */
  kind: CreateHubBoardCTAKind;
  /** Called when the user taps the card — parent is responsible for
   *  navigating to (or mounting) the wizard in the matching mode. */
  onClick: () => void;
}

const COPY: Record<CreateHubBoardCTAKind, { title: string; subtitle: string; icon: RisoIconName }> = {
  oneOff: {
    title: 'Start a one-off board',
    subtitle: 'Pick a timeframe, fill the grid, play it once.',
    icon: 'grid',
  },
  recurring: {
    title: 'Start a recurring board',
    subtitle: 'A fresh board every day, week, month, or year.',
    icon: 'repeat',
  },
};

/**
 * CreateHubBoardCTA — Riso-styled full-width card that launches ONE of the
 * two board-creation wizards, mode locked at the tap. iOS twin:
 * `CreateHubBoardCTAView`.
 *
 * Board Creation Split (web PR C) replaced the single "Start a new board"
 * CTA — whose Step-1 "Repeats" segmented silently morphed the rest of the
 * wizard (Timeframe hidden, "Choose" center suppressed, task counts flip
 * to "at least N") — with two entry points: a RED one-off card and a BLUE
 * recurring card, always shown together at full strength. The retired
 * `variant` (`primary`/`secondary` demotion when core boards need
 * attention) is gone with it — only `CoreBoardsSection` above these cards
 * changes prominence, never the cards themselves.
 */
export function CreateHubBoardCTA({ kind, onClick }: CreateHubBoardCTAProps): React.ReactElement {
  const { title, subtitle, icon } = COPY[kind];
  return (
    <button
      type="button"
      className={`${styles.card} ${kind === 'recurring' ? styles.cardRecurring : styles.cardOneOff}`}
      onClick={onClick}
    >
      <div className={styles.iconBadge} aria-hidden="true">
        <RisoIcon name={icon} size={20} />
      </div>
      <div className={styles.text}>
        <span className={styles.title}>{title}</span>
        <span className={styles.subtitle}>{subtitle}</span>
      </div>
      <div className={styles.chevron} aria-hidden="true">
        <RisoIcon name="chevron" size={18} />
      </div>
    </button>
  );
}
