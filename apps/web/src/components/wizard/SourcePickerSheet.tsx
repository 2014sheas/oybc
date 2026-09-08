import { useEffect, useState } from 'react';
import type { Pool } from '@oybc/shared';
import type { SourceSheetBoardEntry } from '../../db/operations/boardSources';
import styles from './SourcePickerSheet.module.css';

export interface SourcePickerSheetProps {
  /** The user's non-deleted pools — the POOLS section. */
  pools: Pool[];
  /** ACTIVE boards + squares/done counts — the BOARDS section. */
  boardEntries: SourceSheetBoardEntry[];
  /** Currently-pulled source ids (pool AND board kinds). */
  pulledSourceIds: Set<string>;
  /** Tap a POOLS row — pull when not pulled, remove when pulled. */
  onTogglePool: (poolId: string) => void;
  /** Tap a BOARDS row — pull when not pulled, remove when pulled. */
  onToggleBoard: (boardId: string) => void;
}

/**
 * SourcePickerSheet — dashed "Add a pool or board" entry row + bottom
 * sheet (Board Sources P4 — docs/BOARD_SOURCES.md §Surfaces item 2;
 * handoff frames 2c/5c). Web port of iOS `RisoSourcePickerSheetView`,
 * following `LibrarySheet`'s entry-button + backdrop/sheet pattern.
 *
 * Search across POOLS and BOARDS sections (name match, case-insensitive;
 * a section with no matches is hidden), tap-to-toggle rows with a check
 * circle (ink fill + paper ✓ when pulled), and the empty state ("Nothing
 * to pull from yet" + dashed mini-grid) when neither pools nor boards
 * exist.
 */
export function SourcePickerSheet({
  pools,
  boardEntries,
  pulledSourceIds,
  onTogglePool,
  onToggleBoard,
}: SourcePickerSheetProps): React.ReactElement {
  const [isOpen, setIsOpen] = useState(false);
  const [query, setQuery] = useState('');

  useEffect(() => {
    if (!isOpen) return;
    function onKey(e: KeyboardEvent): void {
      if (e.key === 'Escape') setIsOpen(false);
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [isOpen]);

  const trimmedQuery = query.trim();
  const isEmptyStore = pools.length === 0 && boardEntries.length === 0;
  const matchingPools = trimmedQuery
    ? pools.filter((p) => p.name.toLowerCase().includes(trimmedQuery.toLowerCase()))
    : pools;
  const matchingBoards = trimmedQuery
    ? boardEntries.filter((e) =>
        e.board.name.toLowerCase().includes(trimmedQuery.toLowerCase()),
      )
    : boardEntries;

  return (
    <>
      <button type="button" className={styles.entryButton} onClick={() => setIsOpen(true)}>
        <span className={styles.entryIcon} aria-hidden="true">
          {/* 3×3 grid line icon (15pt, 2.5-stroke) per the handoff. */}
          <svg
            width="15"
            height="15"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2.5"
          >
            <rect x="3" y="3" width="18" height="18" rx="2" />
            <line x1="9" y1="3" x2="9" y2="21" />
            <line x1="15" y1="3" x2="15" y2="21" />
            <line x1="3" y1="9" x2="21" y2="9" />
            <line x1="3" y1="15" x2="21" y2="15" />
          </svg>
        </span>
        <span className={styles.entryLabel}>Add a pool or board</span>
        <span className={styles.entryCount}>{pools.length + boardEntries.length}</span>
      </button>

      {isOpen && (
        <div className={styles.backdrop} onClick={() => setIsOpen(false)}>
          <div
            className={styles.sheet}
            role="dialog"
            aria-modal="true"
            aria-label="Add a pool or board"
            onClick={(e) => e.stopPropagation()}
          >
            <div className={styles.grabHandle} aria-hidden="true" />
            <div className={styles.sheetHeader}>
              <span className={styles.sheetTitle}>Add a pool or board</span>
              <button type="button" className={styles.donePill} onClick={() => setIsOpen(false)}>
                Done
              </button>
            </div>

            <div className={`${styles.searchBar} ${isEmptyStore ? styles.searchDisabled : ''}`}>
              <svg
                width="15"
                height="15"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2.5"
                aria-hidden="true"
              >
                <circle cx="11" cy="11" r="7" />
                <line x1="21" y1="21" x2="16.65" y2="16.65" />
              </svg>
              <input
                type="text"
                className={styles.searchInput}
                placeholder="Search pools and boards"
                value={query}
                disabled={isEmptyStore}
                onChange={(e) => setQuery(e.target.value)}
                aria-label="Search pools and boards"
              />
              {query.length > 0 && (
                <button
                  type="button"
                  className={styles.searchClear}
                  onClick={() => setQuery('')}
                  aria-label="Clear search"
                >
                  ✕
                </button>
              )}
            </div>

            <div className={styles.sheetBody}>
              {isEmptyStore ? (
                <div className={styles.emptyState}>
                  <div className={styles.miniGrid} aria-hidden="true">
                    {Array.from({ length: 9 }, (_, i) => (
                      <span
                        key={i}
                        className={`${styles.miniCell} ${i === 4 ? styles.miniCellGold : ''}`}
                      />
                    ))}
                  </div>
                  <p className={styles.emptyTitle}>Nothing to pull from yet</p>
                  <p className={styles.emptySubtitle}>
                    Boards you make and pools you save will show up here.
                  </p>
                </div>
              ) : matchingPools.length === 0 && matchingBoards.length === 0 ? (
                <div className={styles.noMatches}>
                  <p className={styles.noMatchesTitle}>
                    No pools or boards match &ldquo;{trimmedQuery}&rdquo;
                  </p>
                  <p className={styles.noMatchesSubtitle}>
                    Try another word, or add tasks from your library.
                  </p>
                </div>
              ) : (
                <>
                  {matchingPools.length > 0 && (
                    <>
                      <span className={styles.sectionKicker}>Pools</span>
                      {matchingPools.map((pool) => (
                        <SheetRow
                          key={pool.id}
                          letter="P"
                          letterClass={styles.letterPool}
                          name={pool.name}
                          subtitle={`${pool.taskIds.length} task${pool.taskIds.length === 1 ? '' : 's'}`}
                          isOn={pulledSourceIds.has(pool.id)}
                          onToggle={() => onTogglePool(pool.id)}
                        />
                      ))}
                    </>
                  )}
                  {matchingBoards.length > 0 && (
                    <>
                      <span className={styles.sectionKicker}>Boards</span>
                      {matchingBoards.map((entry) => (
                        <SheetRow
                          key={entry.board.id}
                          letter="B"
                          letterClass={styles.letterBoard}
                          name={entry.board.name}
                          subtitle={`${entry.squares} square${entry.squares === 1 ? '' : 's'} · ${entry.done} done`}
                          isOn={pulledSourceIds.has(entry.board.id)}
                          onToggle={() => onToggleBoard(entry.board.id)}
                        />
                      ))}
                    </>
                  )}
                </>
              )}
            </div>
          </div>
        </div>
      )}
    </>
  );
}

interface SheetRowProps {
  letter: string;
  letterClass: string;
  name: string;
  subtitle: string;
  isOn: boolean;
  onToggle: () => void;
}

function SheetRow({
  letter,
  letterClass,
  name,
  subtitle,
  isOn,
  onToggle,
}: SheetRowProps): React.ReactElement {
  return (
    <button
      type="button"
      className={styles.sourceRow}
      onClick={onToggle}
      aria-pressed={isOn}
      aria-label={`${name}, ${subtitle}`}
    >
      <span className={letterClass} aria-hidden="true">
        {letter}
      </span>
      <span className={styles.rowText}>
        <span className={styles.rowName}>{name}</span>
        <span className={styles.rowSubtitle}>{subtitle}</span>
      </span>
      <span className={`${styles.checkCircle} ${isOn ? styles.checkCircleOn : ''}`} aria-hidden="true">
        {isOn ? '✓' : ''}
      </span>
    </button>
  );
}
