import styles from './CreateHubBoardCTA.module.css';

export type CreateHubBoardCTAVariant = 'primary' | 'secondary';

/** Which creation flow the card launches:
 *   - `oneOff`: a single board (the wizard's default flow).
 *   - `recurring`: a recurring-board template that auto-spawns a fresh
 *     board each window (#71 — its own deliberate entry point). */
export type CreateHubBoardCTAKind = 'oneOff' | 'recurring';

export interface CreateHubBoardCTAProps {
  /** Called when the user taps the card — parent is responsible for
   *  navigating to (or mounting) the wizard in the matching mode. */
  onClick: () => void;
  /** Phase 6.1d: when the parent renders `<CoreBoardsSection>` above
   *  this CTA, it passes `secondary` so this becomes a smaller
   *  affordance below the prominent core boards. Default `primary`
   *  keeps the original headline-card visual. */
  variant?: CreateHubBoardCTAVariant;
  /** Issue #71 — selects copy + icon for the one-off vs recurring
   *  entry point. Defaults to `oneOff`. */
  kind?: CreateHubBoardCTAKind;
}

const COPY: Record<
  CreateHubBoardCTAKind,
  { icon: string; secondaryIcon: string; title: string; subtitle: string }
> = {
  oneOff: {
    icon: '✨',
    secondaryIcon: '+',
    title: 'Start a new board',
    subtitle: 'Set it up, pick your tasks, and activate.',
  },
  recurring: {
    icon: '🔁',
    secondaryIcon: '🔁',
    title: 'Create a recurring board',
    subtitle: 'Auto-spawns a fresh board each window from a pool.',
  },
};

/**
 * CreateHubBoardCTA — Card that invites the user to start a new board.
 * Renders an action on the Create Hub; tapping it launches the 3-step
 * board-creation wizard. iOS twin: `CreateHubBoardCTAView`.
 *
 * Two axes:
 *   - `kind` (#71): `oneOff` (a single board) vs `recurring` (a template
 *     that auto-spawns each window). The recurring entry replaced the
 *     in-wizard "Make recurring" toggle.
 *   - `variant`: `primary` (large gradient headline card) vs `secondary`
 *     (smaller flat card) — same destination, different visual weight.
 */
export function CreateHubBoardCTA({
  onClick,
  variant = 'primary',
  kind = 'oneOff',
}: CreateHubBoardCTAProps): React.ReactElement {
  const copy = COPY[kind];
  if (variant === 'secondary') {
    return (
      <button type="button" className={styles.cardSecondary} onClick={onClick}>
        <div className={styles.iconSecondary} aria-hidden="true">
          {copy.secondaryIcon}
        </div>
        <div className={styles.text}>
          <span className={styles.titleSecondary}>{copy.title}</span>
          <span className={styles.subtitleSecondary}>{copy.subtitle}</span>
        </div>
        <div className={styles.chevronSecondary} aria-hidden="true">
          ›
        </div>
      </button>
    );
  }
  return (
    <button type="button" className={styles.card} onClick={onClick}>
      <div className={styles.icon} aria-hidden="true">
        {copy.icon}
      </div>
      <div className={styles.text}>
        <span className={styles.title}>{copy.title}</span>
        <span className={styles.subtitle}>{copy.subtitle}</span>
      </div>
      <div className={styles.chevron} aria-hidden="true">
        ›
      </div>
    </button>
  );
}
