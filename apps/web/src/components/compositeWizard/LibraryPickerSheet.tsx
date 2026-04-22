import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { CompositeTask, Task } from '@oybc/shared';
import { TaskType, generateCounterTaskTitle } from '@oybc/shared';
import { TypeBadge } from '../TypeBadge';
import { FilterTabs } from '../FilterTabs';
import styles from './LibraryPickerSheet.module.css';

/** Preview payload for a composite: first few leaf titles + total. Shared
 *  with `CompositeTaskWizard` so the subtitle line can preview a composite
 *  without expanding it. */
export interface CompositeLeafPreview {
  titles: string[];
  totalLeaves: number;
}

type SheetFilter = 'all' | 'normal' | 'counting' | 'progress' | 'composite';

const FILTER_TABS: { value: SheetFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'normal', label: 'Normal' },
  { value: 'counting', label: 'Counting' },
  { value: 'progress', label: 'Progress' },
  { value: 'composite', label: 'Composite' },
];

/** Add/remove diff produced when the user commits the sheet. */
export interface LibraryDiff {
  add: Array<{ id: string; kind: 'task' | 'composite' }>;
  remove: Set<string>;
}

export interface LibraryPickerSheetProps {
  /** Library feeds. */
  allTasks: Task[];
  allCompositeTasks: CompositeTask[];
  /** Ids currently members of this composite (existing-mode subtasks). Drives
   *  the initial checkbox state. */
  initialCheckedIds: Set<string>;
  /** Usage / metadata hints — same maps the old in-card picker consumed. */
  taskBoardCounts: Record<string, number>;
  taskStepCounts: Record<string, number>;
  compositeSubtaskCounts: Record<string, number>;
  compositeLeafPreviews: Record<string, CompositeLeafPreview>;
  /** User tapped Done — parent applies the diff to the wizard's `subtasks`. */
  onCommit: (diff: LibraryDiff) => void;
  /** User tapped Cancel or the backdrop / Escape. */
  onCancel: () => void;
}

interface SheetRow {
  id: string;
  title: string;
  type: 'normal' | 'counting' | 'progress' | 'composite';
  subtitle: string;
  usageHint: string;
  kind: 'task' | 'composite';
}

/**
 * LibraryPickerSheet — Modal sheet for picking multiple existing library
 * items to include as subtasks in a composite. Each row carries a checkbox
 * whose initial state reflects current membership; committing applies the
 * add/remove diff to the wizard's subtask list. Cancel discards pending
 * toggles.
 *
 * Replaces the per-card `ExistingTaskPicker` so users can add several
 * existing tasks in one session and so the card frame around an existing
 * selection can be flattened to a simple row.
 */
export function LibraryPickerSheet({
  allTasks,
  allCompositeTasks,
  initialCheckedIds,
  taskBoardCounts,
  taskStepCounts,
  compositeSubtaskCounts,
  compositeLeafPreviews,
  onCommit,
  onCancel,
}: LibraryPickerSheetProps): React.ReactElement {
  const [checkedIds, setCheckedIds] = useState<Set<string>>(() => new Set(initialCheckedIds));
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState<SheetFilter>('all');
  const sheetRef = useRef<HTMLDivElement | null>(null);
  const searchRef = useRef<HTMLInputElement | null>(null);
  // Captured in useLayoutEffect so we record the trigger BEFORE any
  // descendant autoFocus can move focus into the sheet. Without this,
  // previouslyFocused ends up pointing at the search input, and
  // restoring on close focuses a detached node (which silently noops).
  const previouslyFocusedRef = useRef<HTMLElement | null>(null);

  useLayoutEffect(() => {
    previouslyFocusedRef.current = document.activeElement as HTMLElement | null;
    // Move focus into the sheet ourselves (search input first).
    searchRef.current?.focus();
  }, []);

  useEffect(() => {
    function onKey(e: KeyboardEvent): void {
      if (e.key === 'Escape') onCancel();
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onCancel]);

  // Focus trap: keep Tab inside the sheet, and restore focus to the
  // trigger on close so keyboard users don't lose their place.
  useEffect(() => {
    const sheet: HTMLDivElement | null = sheetRef.current;
    if (sheet === null) return;

    function getFocusable(root: HTMLElement): HTMLElement[] {
      return Array.from(
        root.querySelectorAll<HTMLElement>(
          'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])',
        ),
      ).filter((el) => !el.hasAttribute('disabled') && el.tabIndex !== -1);
    }

    function onKey(e: KeyboardEvent): void {
      if (e.key !== 'Tab' || sheet === null) return;
      const focusable = getFocusable(sheet);
      if (focusable.length === 0) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement as HTMLElement | null;
      // Treat focus outside the sheet (e.g. browser chrome) as "send me back in".
      if (!active || !sheet.contains(active)) {
        e.preventDefault();
        first.focus();
        return;
      }
      if (e.shiftKey && active === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && active === last) {
        e.preventDefault();
        first.focus();
      }
    }

    sheet.addEventListener('keydown', onKey);
    return () => {
      sheet.removeEventListener('keydown', onKey);
      const previouslyFocused = previouslyFocusedRef.current;
      // Restore focus to the trigger element, if it's still in the DOM.
      if (previouslyFocused && document.contains(previouslyFocused)) {
        previouslyFocused.focus();
      }
    };
  }, []);

  const rows = useMemo<SheetRow[]>(() => {
    const taskRows: SheetRow[] = allTasks.map((t) => {
      const boards = taskBoardCounts[t.id] ?? 0;
      return {
        id: t.id,
        title: t.title,
        type: t.type as 'normal' | 'counting' | 'progress',
        subtitle: buildTaskSubtitle(t, taskStepCounts),
        usageHint: boards === 0 ? 'not on any board' : `on ${boards} board${boards === 1 ? '' : 's'}`,
        kind: 'task',
      };
    });
    const compositeRows: SheetRow[] = allCompositeTasks.map((ct) => {
      const leaves = compositeSubtaskCounts[ct.id] ?? 0;
      return {
        id: ct.id,
        title: ct.title,
        type: 'composite',
        subtitle: buildCompositeSubtitle(ct.id, compositeLeafPreviews),
        usageHint: `${leaves} subtask${leaves === 1 ? '' : 's'}`,
        kind: 'composite',
      };
    });
    return [...taskRows, ...compositeRows].sort((a, b) => a.title.localeCompare(b.title));
  }, [
    allTasks,
    allCompositeTasks,
    taskBoardCounts,
    taskStepCounts,
    compositeSubtaskCounts,
    compositeLeafPreviews,
  ]);

  const q = query.trim().toLowerCase();
  const visibleRows = rows.filter((row) => {
    if (filter !== 'all' && row.type !== filter) return false;
    if (q.length === 0) return true;
    return row.title.toLowerCase().includes(q) || row.subtitle.toLowerCase().includes(q);
  });

  // Diff summary for the Done button — only shown when non-zero.
  const addCount = [...checkedIds].filter((id) => !initialCheckedIds.has(id)).length;
  const removeCount = [...initialCheckedIds].filter((id) => !checkedIds.has(id)).length;
  const hasChanges = addCount > 0 || removeCount > 0;

  function toggle(id: string): void {
    setCheckedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  function handleDone(): void {
    const add: LibraryDiff['add'] = [];
    for (const row of rows) {
      if (checkedIds.has(row.id) && !initialCheckedIds.has(row.id)) {
        add.push({ id: row.id, kind: row.kind });
      }
    }
    const remove = new Set<string>();
    for (const id of initialCheckedIds) {
      if (!checkedIds.has(id)) remove.add(id);
    }
    onCommit({ add, remove });
  }

  const showEmptyLibrary = rows.length === 0;
  const showNoMatches = !showEmptyLibrary && visibleRows.length === 0;

  return (
    <div
      className={styles.backdrop}
      role="presentation"
      onClick={(e) => {
        // Only cancel when the user clicks the backdrop itself, not the sheet.
        if (e.target === e.currentTarget) onCancel();
      }}
    >
      <div
        ref={sheetRef}
        className={styles.sheet}
        role="dialog"
        aria-modal="true"
        aria-labelledby="library-sheet-title"
      >
        <div className={styles.header}>
          <h2 className={styles.title} id="library-sheet-title">
            Tasks in this composite
          </h2>
          <p className={styles.subtitle}>
            Check tasks to include them. Uncheck to remove.
          </p>
        </div>

        <div className={styles.searchRow}>
          <input
            ref={searchRef}
            type="search"
            className={styles.searchInput}
            placeholder="Search your tasks…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            aria-label="Search tasks"
          />
        </div>

        <FilterTabs
          tabs={FILTER_TABS}
          activeTab={filter}
          onTabChange={(v) => setFilter(v as SheetFilter)}
        />

        <div className={styles.listContainer}>
          {showEmptyLibrary && (
            <div className={styles.emptyState}>
              Your library is empty — create a task with <strong>+ Create new task</strong>.
            </div>
          )}
          {showNoMatches && (
            <div className={styles.emptyState}>
              {q.length > 0
                ? `No matches for "${query.trim()}" in ${filter === 'all' ? 'All' : filter}.`
                : `No ${filter} tasks available — try a different filter.`}
            </div>
          )}
          {!showEmptyLibrary && !showNoMatches && (
            <ul className={styles.rowList}>
              {visibleRows.map((row) => {
                const checked = checkedIds.has(row.id);
                return (
                  <li key={row.id}>
                    <button
                      type="button"
                      className={checked ? styles.rowButtonChecked : styles.rowButton}
                      onClick={() => toggle(row.id)}
                      aria-pressed={checked}
                    >
                      <span
                        className={checked ? styles.checkboxChecked : styles.checkbox}
                        aria-hidden="true"
                      >
                        {checked ? '✓' : ''}
                      </span>
                      <TypeBadge type={row.type} size="small" letterOnly />
                      <div className={styles.rowCenter}>
                        <span className={styles.rowTitle}>{row.title}</span>
                        {row.subtitle && (
                          <span className={styles.rowSubtitle}>{row.subtitle}</span>
                        )}
                      </div>
                      <span className={styles.rowUsage}>{row.usageHint}</span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </div>

        <div className={styles.footer}>
          <button type="button" className={styles.cancelButton} onClick={onCancel}>
            Cancel
          </button>
          <button
            type="button"
            className={styles.doneButton}
            onClick={handleDone}
            disabled={!hasChanges}
          >
            {hasChanges ? diffLabel(addCount, removeCount) : 'Done'}
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function diffLabel(addCount: number, removeCount: number): string {
  const parts: string[] = [];
  if (addCount > 0) parts.push(`+${addCount}`);
  if (removeCount > 0) parts.push(`−${removeCount}`);
  return `Done (${parts.join(', ')})`;
}

function buildTaskSubtitle(task: Task, taskStepCounts: Record<string, number>): string {
  if (task.type === TaskType.COUNTING) {
    const { action, maxCount, unit } = task;
    if (!action || !unit || maxCount === undefined) return '';
    const derived = generateCounterTaskTitle(action, maxCount, unit);
    return derived.toLowerCase() === task.title.trim().toLowerCase() ? '' : derived;
  }
  if (task.type === TaskType.PROGRESS) {
    const n = taskStepCounts[task.id] ?? 0;
    if (n === 0) return '';
    return `${n} step${n === 1 ? '' : 's'}`;
  }
  return '';
}

function buildCompositeSubtitle(
  compositeId: string,
  previews: Record<string, CompositeLeafPreview>,
): string {
  const preview = previews[compositeId];
  if (!preview) return '';
  const { titles, totalLeaves } = preview;
  if (titles.length === 0) return '';
  const visible = titles.join(', ');
  const hidden = totalLeaves - titles.length;
  return hidden > 0 ? `${visible}, +${hidden} more` : visible;
}
