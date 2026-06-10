import styles from './TypeBadge.module.css';

/**
 * Maps a task type string to its capitalised CSS class suffix.
 *
 * @param type - Task type string (e.g. 'normal', 'counting', 'compound', 'achievement')
 * @returns Capitalised string matching the CSS module convention (e.g. 'Normal')
 */
function typeBadgeClass(type: string): string {
  return type.charAt(0).toUpperCase() + type.slice(1);
}

interface TypeBadgeProps {
  /** Task type string (e.g. 'normal', 'counting', 'compound', 'achievement') */
  type: string;
  /** Optional size variant */
  size?: 'small' | 'default';
  /** When true, renders a uniformly-sized 4-letter abbreviation instead
   *  of the full type name. Lets list layouts (e.g. the composite-task
   *  picker) stack rows without the badge width varying by type. The
   *  full type name is surfaced as a native tooltip. */
  letterOnly?: boolean;
  /** Optional extra CSS class */
  className?: string;
}

/** 4-letter abbreviation for each task type — kept uniform-width so
 *  stacked badges align row-to-row in list layouts. */
const TYPE_ABBREV: Record<string, string> = {
  normal: 'NORM',
  counting: 'COUN',
  compound: 'CMPD',
  // Phase 6.3 — ACHIEVEMENT (cross-board watcher). "ACHV" is the
  // 4-letter abbreviation; the full label "Achievement task" still
  // appears in `aria-label` and the hover tooltip.
  achievement: 'ACHV',
};

/**
 * TypeBadge — Colored badge showing a task type label.
 *
 * Used across task library cards, derivation panels, pool items, and
 * composite subtask lists to display a consistent type indicator.
 */
export function TypeBadge({
  type,
  size,
  letterOnly,
  className,
}: TypeBadgeProps): React.ReactElement {
  const sizeClass = size === 'small' ? styles.small : '';
  const typeClass = styles[`typeBadge${typeBadgeClass(type)}`] ?? '';
  const letterClass = letterOnly ? styles.letter : '';
  const classes = [styles.typeBadge, typeClass, sizeClass, letterClass, className]
    .filter(Boolean)
    .join(' ');

  const display = letterOnly
    ? (TYPE_ABBREV[type.toLowerCase()] ?? type.slice(0, 4).toUpperCase())
    : type.toUpperCase();
  // Full-type label surfaced to assistive tech. The 4-letter abbreviation
  // ("NORM", "COUN", …) is visual-only, so aria-label carries the
  // meaningful name ("Normal task", "Counting task"). Sighted tooltip
  // via `title` also carries the full type for mouse users.
  const fullType = type.charAt(0).toUpperCase() + type.slice(1);
  const accessibleLabel = `${fullType} task`;

  return (
    <span
      className={classes}
      title={letterOnly ? fullType : undefined}
      aria-label={letterOnly ? accessibleLabel : undefined}
    >
      {display}
    </span>
  );
}
