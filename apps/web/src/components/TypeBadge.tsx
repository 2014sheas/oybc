import styles from './TypeBadge.module.css';

/**
 * Maps a task type string to its capitalised CSS class suffix.
 *
 * @param type - Task type string (e.g. 'normal', 'counting', 'progress', 'composite')
 * @returns Capitalised string matching the CSS module convention (e.g. 'Normal')
 */
function typeBadgeClass(type: string): string {
  return type.charAt(0).toUpperCase() + type.slice(1);
}

interface TypeBadgeProps {
  /** Task type string (e.g. 'normal', 'counting', 'progress', 'composite') */
  type: string;
  /** Optional size variant */
  size?: 'small' | 'default';
  /** Optional extra CSS class */
  className?: string;
}

/**
 * TypeBadge — Colored badge showing a task type label.
 *
 * Used across task library cards, derivation panels, pool items, and
 * composite subtask lists to display a consistent type indicator.
 *
 * @param type - The task type to display
 * @param size - Optional size variant ('small' renders a compact badge)
 * @param className - Optional extra CSS class
 */
export function TypeBadge({ type, size, className }: TypeBadgeProps): React.ReactElement {
  const sizeClass = size === 'small' ? styles.small : '';
  const typeClass = styles[`typeBadge${typeBadgeClass(type)}`] ?? '';
  const classes = [styles.typeBadge, typeClass, sizeClass, className]
    .filter(Boolean)
    .join(' ');

  return (
    <span className={classes}>
      {type.toUpperCase()}
    </span>
  );
}
