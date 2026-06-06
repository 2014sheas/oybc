import { useEffect, useRef, useState } from 'react';
import { TaskType, type Task } from '@oybc/shared';
import { TypeBadge } from './TypeBadge';
import styles from './CellSwapModal.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

interface CellSwapModalProps {
  /**
   * The current task occupying the square being swapped (excluded from the
   * eligible list so the user cannot "swap" to the same task).
   */
  currentTaskId: string;
  /**
   * All non-deleted tasks in the user's library eligible for placement.
   * The modal filters to non-center types (NORMAL / COUNTING / COMPOUND /
   * ACHIEVEMENT) and excludes the current task.
   */
  candidateTasks: Task[];
  /** Dismiss without making a change. */
  onClose: () => void;
  /**
   * Confirm swap. Called with the selected Task's id.
   * The caller owns the DB write via `updateBoardTaskAndCascade`.
   */
  onConfirm: (newTaskId: string) => void;
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * CellSwapModal — full-screen modal that lets the user pick a replacement
 * task for a non-center square on an ACTIVE board (live-edit M3).
 *
 * Eligible tasks: any non-deleted Task of type NORMAL / COUNTING / COMPOUND /
 * ACHIEVEMENT, excluding the Task currently in the square.
 *
 * UX:
 *   - Search field filters by title (case-insensitive substring).
 *   - Single-select list (tap a row to highlight, tap again or tap Confirm).
 *   - Confirm is disabled until a task is selected.
 *   - Escape key or clicking the backdrop closes the modal.
 *
 * @param currentTaskId - Task currently occupying the square (excluded).
 * @param candidateTasks - Full library; modal filters internally.
 * @param onClose - Dismiss without changes.
 * @param onConfirm - Called with the chosen Task id.
 */
export function CellSwapModal({
  currentTaskId,
  candidateTasks,
  onClose,
  onConfirm,
}: CellSwapModalProps): React.ReactElement {
  const [query, setQuery] = useState('');
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const searchRef = useRef<HTMLInputElement>(null);

  // Auto-focus the search field when the modal opens.
  useEffect(() => {
    searchRef.current?.focus();
  }, []);

  // Close on Escape key.
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [onClose]);

  // Eligible task types for a non-center square.
  const ELIGIBLE_TYPES = new Set<string>([
    TaskType.NORMAL,
    TaskType.COUNTING,
    TaskType.COMPOUND,
    TaskType.ACHIEVEMENT,
  ]);

  const filtered = candidateTasks.filter((t) => {
    if (t.isDeleted) return false;
    if (t.id === currentTaskId) return false;
    if (!ELIGIBLE_TYPES.has(t.type)) return false;
    if (query.trim()) {
      return t.title.toLowerCase().includes(query.trim().toLowerCase());
    }
    return true;
  });

  const handleConfirm = () => {
    if (selectedId) onConfirm(selectedId);
  };

  return (
    <div
      className={styles.backdrop}
      onClick={onClose}
      role="presentation"
    >
      <div
        className={styles.modal}
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-labelledby="swap-modal-title"
      >
        {/* Header */}
        <div className={styles.header}>
          <div>
            <h3 id="swap-modal-title" className={styles.title}>
              Swap with another task…
            </h3>
            <p className={styles.subtitle}>
              Pick a task from your library to replace this square.
            </p>
          </div>
          <button
            type="button"
            className={styles.closeButton}
            onClick={onClose}
            aria-label="Close"
          >
            ✕
          </button>
        </div>

        {/* Search */}
        <input
          ref={searchRef}
          type="search"
          className={styles.searchInput}
          placeholder="Search tasks…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search tasks"
        />

        {/* Task list */}
        <div className={styles.taskList} role="listbox" aria-label="Eligible tasks">
          {filtered.length === 0 ? (
            <p className={styles.emptyState}>
              {query.trim() ? 'No tasks match your search.' : 'No eligible tasks found.'}
            </p>
          ) : (
            filtered.map((task) => {
              const isSelected = task.id === selectedId;
              return (
                <button
                  key={task.id}
                  type="button"
                  role="option"
                  aria-selected={isSelected}
                  className={`${styles.taskRow} ${isSelected ? styles.taskRowSelected : ''}`}
                  onClick={() => setSelectedId(isSelected ? null : task.id)}
                >
                  <span className={styles.taskRowTitle}>{task.title}</span>
                  <TypeBadge type={task.type} size="small" />
                </button>
              );
            })
          )}
        </div>

        {/* Footer */}
        <div className={styles.footer}>
          <button type="button" className={styles.cancelButton} onClick={onClose}>
            Cancel
          </button>
          <button
            type="button"
            className={styles.confirmButton}
            disabled={!selectedId}
            onClick={handleConfirm}
          >
            Swap
          </button>
        </div>
      </div>
    </div>
  );
}
