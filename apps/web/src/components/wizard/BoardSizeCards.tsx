import styles from './BoardSizeCards.module.css';

export interface BoardSizeCardsProps {
  /** Currently-selected board size. */
  selectedSize: 3 | 4 | 5;
  /** Sizes to render, in order. Defaults to the standard 3×3/4×4/5×5 set. */
  sizes?: readonly (3 | 4 | 5)[];
  onSelect: (size: 3 | 4 | 5) => void;
}

const DEFAULT_SIZES: readonly (3 | 4 | 5)[] = [3, 4, 5];

/**
 * BoardSizeCards — dot-matrix board-size picker (3×3 / 4×4 / 5×5).
 *
 * Board Creation Split (web PR C) — extracted as a standalone reusable
 * component (mirrors iOS `RisoBoardSizeCards`, `Views/Components/
 * RisoBoardSizeCards.swift`) so both the one-off and recurring Setup
 * forms render the identical control (CLAUDE.md "Build real components,
 * not demos" — a control used by more than one surface belongs in its
 * own file, not inlined in a single caller).
 *
 * Selected card = gold fill + red dots + hard shadow; unselected = flat
 * paper-2 fill + paper dots, no shadow.
 */
export function BoardSizeCards({
  selectedSize,
  sizes = DEFAULT_SIZES,
  onSelect,
}: BoardSizeCardsProps): React.ReactElement {
  return (
    <div className={styles.row}>
      {sizes.map((n) => {
        const isSelected = n === selectedSize;
        return (
          <button
            key={n}
            type="button"
            className={`${styles.card} ${isSelected ? styles.cardSelected : ''}`}
            onClick={() => onSelect(n)}
            aria-pressed={isSelected}
          >
            <div
              className={styles.dotMatrix}
              style={{ gridTemplateColumns: `repeat(${n}, 1fr)` }}
              aria-hidden="true"
            >
              {Array.from({ length: n * n }).map((_, i) => (
                <span key={i} className={isSelected ? styles.dotSelected : styles.dot} />
              ))}
            </div>
            <span className={styles.label}>
              {n}×{n}
            </span>
          </button>
        );
      })}
    </div>
  );
}
