import { TaskType } from '@oybc/shared';
import styles from './RisoTypeBadge.module.css';

/** Accepts the `TaskType` enum or its equivalent string literal (the enum
 *  values ARE the lowercase strings, so both call forms collapse to one). */
export type RisoTaskType = TaskType | 'normal' | 'counting' | 'compound' | 'achievement';

const LETTER: Record<string, string> = {
  normal: 'N',
  counting: 'C',
  compound: 'K', // K avoids colliding with Counting's C
  achievement: 'A',
};

const VARIANT: Record<string, string> = {
  normal: styles.normal,
  counting: styles.counting,
  compound: styles.compound,
  achievement: styles.achievement,
};

export interface RisoTypeBadgeProps {
  type: RisoTaskType;
}

/**
 * RisoTypeBadge — square type marker (N / C / K / A), color-coded by task type
 * (normal = paper, counting = blue, compound = green, achievement = purple).
 *
 * Decorative (`aria-hidden`): the task title carries identity and the row's
 * meta line names the type, so the letter is redundant to assistive tech.
 * Shared by the Tasks library and the board wizard's Tasks step.
 */
export function RisoTypeBadge({ type }: RisoTypeBadgeProps): React.ReactElement {
  return (
    <span className={`${styles.badge} ${VARIANT[type] ?? styles.normal}`} aria-hidden="true">
      {LETTER[type] ?? 'N'}
    </span>
  );
}
