import { useEffect, useMemo, useState } from 'react';
import { PARENT_TIMEFRAMES, TaskType, formatCounterName, isTaskExpired, type CompoundChild, type Task, type Timeframe } from '@oybc/shared';
import { useModalA11y } from '../../hooks/useModalA11y';
import { RisoChip, RisoTypeBadge } from '../riso';
import { renderTaskRow } from './TaskRow';
import stepStyles from './BoardWizardTasksStep.module.css';
import styles from './LibrarySheet.module.css';

export type LibraryFilter =
  | 'all'
  | TaskType
  | 'compound'
  | 'from-parents';

const BASE_FILTER_TABS: { value: LibraryFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: TaskType.NORMAL, label: 'Normal' },
  { value: TaskType.COUNTING, label: 'Counting' },
  // 'compound' matches ALL compound tasks (both ordered and unordered) —
  // the ordered/unordered distinction is an internal model detail; users
  // see a single "Compound" chip here and in the Tasks-tab filters.
  { value: 'compound', label: 'Compound' },
];

const FROM_PARENTS_TAB: { value: LibraryFilter; label: string } = {
  value: 'from-parents',
  label: 'From parent boards',
};

export interface LibrarySheetProps {
  /** Merged live + pending task pool (browse-filtered), already excluding
   *  wizard-orphaned drafts from OTHER sessions. */
  effectiveAllTasks: Task[];
  /** Child-task ids of every compound (for the "Group subtasks" filter). */
  childTaskIds: Set<string>;
  effectiveChildrenByCompound: Record<string, CompoundChild[]>;
  effectiveTaskMap: Record<string, Task>;
  taskBoardCounts: Record<string, number>;

  selectedTaskIds: Set<string>;
  /** Toggles a task's board selection. Already routes through the
   *  wizard's center-clearing + Bug #85 pending-purge logic. */
  onToggleSelection: (taskId: string) => void;
  centerTaskMode: boolean;
  centerTaskId: string | null;
  onCenterClick: (taskId: string) => void;

  /** Right-click / context-menu handler — shared with the pool list so
   *  there's one `RowContextMenu` implementation for both surfaces. */
  onContextMenu: (taskId: string, x: number, y: number) => void;
  currentTimeframe: Timeframe;
  /** Reactive list of tasks placed on currently-active PARENT boards
   *  (Phase 6.1). Empty when the current timeframe has no parents. */
  parentBoardTasks: Task[];
  /** Owner ruling 2026-09-22 — task ids that HEAD a shared-counter family
   *  (`useTaskLibrary().familyRootIds`). Such a row shows the generic
   *  `formatCounterName` label instead of its stored title; tapping it still
   *  adds the root itself, exactly as before. Passed in rather than derived
   *  here because it must be computed over the FULL library — the browse rule
   *  has already removed the members from `effectiveAllTasks`. */
  familyRootIds?: Set<string>;
}

/**
 * LibrarySheet — dashed "Add from your library" entry button + bottom
 * sheet (Web inline-editing port PR-1, porting iOS `RisoLibrarySheetView`).
 *
 * The library — search, type/parent filter chips, "Group
 * subtasks" toggle, and the rich row list (including compound expand) —
 * moves ENTIRELY into this sheet. It is no longer primary Step-2 content;
 * the pool list (`PoolList`) is.
 *
 * Cross-cutting overlays (right-click menu, derive-smaller modal,
 * task-detail sheet) stay owned by the parent `BoardWizardTasksStep`
 * — this component only requests them via callbacks — because the SAME
 * `RowContextMenu` instance also serves the pool list, and z-index
 * layering is simpler with a single modal instance per overlay type.
 */
export function LibrarySheet({
  effectiveAllTasks,
  childTaskIds,
  effectiveChildrenByCompound,
  effectiveTaskMap,
  taskBoardCounts,
  selectedTaskIds,
  onToggleSelection,
  centerTaskMode,
  centerTaskId,
  onCenterClick,
  onContextMenu,
  currentTimeframe,
  parentBoardTasks,
  familyRootIds,
}: LibrarySheetProps): React.ReactElement {
  const [isOpen, setIsOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [activeFilter, setActiveFilter] = useState<LibraryFilter>('all');
  const [expandedCompositeId, setExpandedCompositeId] = useState<string | null>(null);
  /** Default ON — hides compound children from the flat list; reachable by
   *  expanding the parent compound row instead (issue #73's rule, carried
   *  over verbatim). */
  const [groupByCompound, setGroupByCompound] = useState(true);

  // aria-modal, Escape → close, initial focus, Tab trap, focus restore —
  // the contract every modal in the app shares.
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: isOpen,
    onCancel: () => setIsOpen(false),
  });

  const hasParentTimeframes = PARENT_TIMEFRAMES[currentTimeframe].length > 0;

  const filterTabs = useMemo(
    () => (hasParentTimeframes ? [...BASE_FILTER_TABS, FROM_PARENTS_TAB] : BASE_FILTER_TABS),
    [hasParentTimeframes],
  );

  // Coerce back to 'all' if the timeframe lost its parents while
  // 'from-parents' was active (Step 1 → Step 2 → back → Step 1 change).
  useEffect(() => {
    if (!hasParentTimeframes && activeFilter === 'from-parents') {
      setActiveFilter('all');
    }
  }, [hasParentTimeframes, activeFilter]);

  const visible = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    // Match the stored title OR — for a counting task — the pair-derived
    // generic name, because a family root's row here reads "Read pages" rather
    // than its stored "Read 35 pages" (owner ruling 2026-09-22). Tested for
    // every counting task, not just roots: cheaper than threading the root set
    // through, and harmless for a standalone counter whose title already
    // contains the same `(action, unit)` pair. Twin of `useTasksFilters`'s
    // `matchesSearch` and iOS `RisoLibrarySheetView.matches`.
    const matches = (t: Task): boolean => {
      if (q.length === 0) return true;
      if (t.title.toLowerCase().includes(q)) return true;
      if (t.type === TaskType.COUNTING) {
        const generic = formatCounterName(t.action, t.unit);
        if (generic && generic.toLowerCase().includes(q)) return true;
      }
      return false;
    };
    const notExpired = (t: Task): boolean => !isTaskExpired(t);

    if (activeFilter === 'from-parents') {
      const filtered = parentBoardTasks.filter((t) => notExpired(t) && matches(t));
      return { tasks: filtered, composites: [] as Task[] };
    }

    const notGroupedChild = (t: Task): boolean => !groupByCompound || !childTaskIds.has(t.id);

    const tasks =
      activeFilter === 'all'
        ? effectiveAllTasks.filter(
            (t) => notExpired(t) && t.type !== TaskType.COMPOUND && notGroupedChild(t) && matches(t),
          )
        : activeFilter === 'compound'
          ? []
          : effectiveAllTasks.filter(
              (t) => notExpired(t) && t.type === activeFilter && notGroupedChild(t) && matches(t),
            );

    const composites =
      activeFilter === 'all' || activeFilter === 'compound'
        ? effectiveAllTasks.filter((t) => notExpired(t) && t.type === TaskType.COMPOUND && matches(t))
        : [];

    return { tasks, composites };
  }, [effectiveAllTasks, activeFilter, searchQuery, parentBoardTasks, groupByCompound, childTaskIds]);

  const compositeLeafPreviews = useMemo(() => {
    const previews: Record<string, { titles: string[]; totalLeaves: number }> = {};
    for (const [compoundId, children] of Object.entries(effectiveChildrenByCompound)) {
      const titles: string[] = [];
      for (const child of children.slice(0, 3)) {
        const t = effectiveTaskMap[child.childTaskId];
        if (t) titles.push(t.title);
      }
      previews[compoundId] = { titles, totalLeaves: children.length };
    }
    return previews;
  }, [effectiveChildrenByCompound, effectiveTaskMap]);

  const compositeLeafTasks = useMemo(() => {
    const byCompound: Record<string, Task[]> = {};
    for (const [compoundId, children] of Object.entries(effectiveChildrenByCompound)) {
      const tasks: Task[] = [];
      for (const child of children) {
        const t = effectiveTaskMap[child.childTaskId];
        if (!t || t.type === TaskType.COMPOUND) continue;
        tasks.push(t);
      }
      byCompound[compoundId] = tasks;
    }
    return byCompound;
  }, [effectiveChildrenByCompound, effectiveTaskMap]);

  function handleToggle(taskId: string): void {
    onToggleSelection(taskId);
  }

  return (
    <>
      <button
        type="button"
        className={styles.entryButton}
        onClick={() => setIsOpen(true)}
      >
        <span className={styles.entryIcon} aria-hidden="true">
          {/* RisoIcon has no magnifier glyph — inline stroke SVG per the
              handoff (§2 "Library entry button"). */}
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
            <circle cx="11" cy="11" r="7" />
            <line x1="21" y1="21" x2="16.65" y2="16.65" />
          </svg>
        </span>
        <span className={styles.entryLabel}>Add from your library</span>
        <span className={styles.entryCount}>{effectiveAllTasks.length}</span>
      </button>

      {isOpen && (
        <div className={styles.backdrop} onClick={() => setIsOpen(false)}>
          <div
            ref={modalRef}
            className={styles.sheet}
            role="dialog"
            aria-label="Your library"
            {...modalProps}
            onClick={(e) => e.stopPropagation()}
          >
            <div className={styles.grabHandle} aria-hidden="true" />
            <div className={styles.sheetHeader}>
              <span className={styles.sheetTitle}>Your library</span>
              <button
                type="button"
                className={styles.donePill}
                onClick={() => setIsOpen(false)}
              >
                {selectedTaskIds.size > 0 ? `Done · ${selectedTaskIds.size}` : 'Done'}
              </button>
            </div>

            <div className={styles.searchBar}>
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" aria-hidden="true">
                <circle cx="11" cy="11" r="7" />
                <line x1="21" y1="21" x2="16.65" y2="16.65" />
              </svg>
              <input
                type="search"
                className={styles.searchInput}
                placeholder="Search your library…"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                aria-label="Search your library"
              />
            </div>

            <div className={styles.filtersWrap}>
              <div className={stepStyles.filterChips} role="group" aria-label="Filter library">
                {filterTabs.map((t) => (
                  <RisoChip
                    key={t.value}
                    on={activeFilter === t.value}
                    onClick={() => {
                      setActiveFilter(t.value);
                      setExpandedCompositeId(null);
                    }}
                  >
                    {t.label}
                  </RisoChip>
                ))}
              </div>

              <div className={stepStyles.groupRow}>
                <button
                  type="button"
                  className={`${stepStyles.groupChip} ${groupByCompound ? stepStyles.groupChipActive : ''}`}
                  aria-pressed={groupByCompound}
                  onClick={() => {
                    setGroupByCompound((v) => !v);
                    setExpandedCompositeId(null);
                  }}
                  title={
                    groupByCompound
                      ? 'Grouping ON — subtasks hidden from flat list'
                      : 'Grouping OFF — show all tasks at top level'
                  }
                >
                  {groupByCompound ? 'Group subtasks ✓' : 'Group subtasks'}
                </button>
              </div>
            </div>

            <div className={styles.sheetBody}>
              {visible.tasks.length === 0 && visible.composites.length === 0 ? (
                <div className={stepStyles.emptyState}>
                  {searchQuery.trim().length > 0
                    ? `No tasks match "${searchQuery}".`
                    : activeFilter === 'from-parents'
                      ? 'No parent boards. Create a weekly/monthly/yearly board first.'
                      : 'Your library is empty. Add a task above to get started.'}
                </div>
              ) : (
                <ul className={stepStyles.list}>
                  {visible.tasks.map((task) => {
                    const isSelected = selectedTaskIds.has(task.id);
                    const isCenter = centerTaskId === task.id;
                    return (
                      <li key={task.id}>
                        {renderTaskRow({
                          task,
                          isSelected,
                          onToggle: () => handleToggle(task.id),
                          onContextMenu: (e) => {
                            e.preventDefault();
                            onContextMenu(task.id, e.clientX, e.clientY);
                          },
                          taskBoardCounts,
                          showCenterStar: centerTaskMode && isSelected,
                          isCenter,
                          onCenterClick: () => onCenterClick(task.id),
                          isFamilyRoot: familyRootIds?.has(task.id) ?? false,
                        })}
                      </li>
                    );
                  })}

                  {visible.composites.map((ct) => {
                    const isExpanded = expandedCompositeId === ct.id;
                    const isCompoundSelected = selectedTaskIds.has(ct.id);
                    const isCenter = centerTaskId === ct.id;
                    const leafCount = effectiveChildrenByCompound[ct.id]?.length ?? 0;
                    const preview = compositeLeafPreviews[ct.id];
                    const previewSubtitle =
                      preview && preview.titles.length > 0
                        ? preview.totalLeaves > preview.titles.length
                          ? `${preview.titles.join(', ')}, +${preview.totalLeaves - preview.titles.length} more`
                          : preview.titles.join(', ')
                        : '';
                    const leaves = compositeLeafTasks[ct.id] ?? [];
                    return (
                      <li key={ct.id}>
                        <div className={isCompoundSelected ? stepStyles.rowSelectedWrap : stepStyles.rowWrap}>
                          <button
                            type="button"
                            className={stepStyles.row}
                            onClick={() => handleToggle(ct.id)}
                            onContextMenu={(e) => {
                              e.preventDefault();
                              onContextMenu(ct.id, e.clientX, e.clientY);
                            }}
                            aria-pressed={isCompoundSelected}
                          >
                            <RisoTypeBadge type="compound" />
                            <div className={stepStyles.rowCenter}>
                              <span className={stepStyles.rowTitle}>{ct.title}</span>
                              {previewSubtitle && (
                                <span className={stepStyles.rowSubtitle}>{previewSubtitle}</span>
                              )}
                            </div>
                            <span className={stepStyles.rowUsage}>
                              {leafCount} subtask{leafCount === 1 ? '' : 's'}
                            </span>
                          </button>
                          {centerTaskMode && isCompoundSelected && (
                            <button
                              type="button"
                              className={`${stepStyles.centerRadio} ${isCenter ? stepStyles.centerRadioOn : ''}`}
                              onClick={() => onCenterClick(ct.id)}
                              aria-label={isCenter ? 'Center task' : 'Mark as center task'}
                              aria-pressed={isCenter}
                              title={isCenter ? 'Center task' : 'Mark as center task'}
                            >
                              {isCenter ? '★' : '☆'}
                            </button>
                          )}
                          <button
                            type="button"
                            className={stepStyles.disclosureButton}
                            onClick={() => setExpandedCompositeId((prev) => (prev === ct.id ? null : ct.id))}
                            aria-expanded={isExpanded}
                            aria-label={isExpanded ? 'Collapse subtasks' : 'Expand subtasks'}
                          >
                            <span
                              className={`${stepStyles.chevron} ${isExpanded ? stepStyles.chevronOpen : ''}`}
                              aria-hidden="true"
                            >
                              ▶
                            </span>
                          </button>
                        </div>

                        {isExpanded && (
                          <ul className={stepStyles.leafList}>
                            {leaves.length === 0 && (
                              <li className={stepStyles.leafEmpty}>
                                Sub-tasks are real tasks — add one on its own.
                              </li>
                            )}
                            {leaves.map((leafTask) => {
                              const leafIsSelected = selectedTaskIds.has(leafTask.id);
                              const leafIsCenter = centerTaskId === leafTask.id;
                              return (
                                <li key={leafTask.id} className={stepStyles.leafItem}>
                                  {renderTaskRow({
                                    task: leafTask,
                                    isSelected: leafIsSelected,
                                    onToggle: () => handleToggle(leafTask.id),
                                    onContextMenu: (e) => {
                                      e.preventDefault();
                                      onContextMenu(leafTask.id, e.clientX, e.clientY);
                                    },
                                    taskBoardCounts,
                                    showCenterStar: centerTaskMode && leafIsSelected,
                                    isCenter: leafIsCenter,
                                    onCenterClick: () => onCenterClick(leafTask.id),
                                  })}
                                </li>
                              );
                            })}
                          </ul>
                        )}
                      </li>
                    );
                  })}
                </ul>
              )}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
