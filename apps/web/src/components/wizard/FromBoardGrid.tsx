import { useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  CenterSquareType,
  TaskType,
  getCenterDisplayText,
  isTaskExpired,
  type Board,
  type Task,
} from '@oybc/shared';
import { db } from '../../db/database';
import { createTask } from '../../db/operations/tasks';
import { useSourceBoardPlacements, type SourceBoardPlacement } from '../../hooks/useSourceBoardPlacements';
import { RowContextMenu, type RowContextMenuItem } from './RowContextMenu';
import { DeriveCounterModal } from './DeriveCounterModal';
import styles from './FromBoardGrid.module.css';

interface FromBoardGridProps {
  /** Source board to browse. */
  boardId: string;
  /** Authenticated user — passed to `createTask` for derived counters. */
  userId: string;
  /** Tasks already linked into the new board's selection (any source). */
  selectedTaskIds: Set<string>;
  /** Tasks already copied this session (amber tint indicator). */
  copiedTaskIds: Set<string>;
  /** Toggle Link/Unlink for the underlying Task. */
  onToggleSelection: (taskId: string) => void;
  /** Open the Copy modal for `⎘ Add a copy of this task…`. */
  onCopyTask: (sourceTask: Task) => void;
  /** Auto-add every non-deleted leaf of a compound. Grid passes the
   *  already-resolved leaf ids so the parent doesn't have to look
   *  them up in its own library — the source's compound may have
   *  children that aren't in the wizard's library yet, which would
   *  silently no-op a parent-side lookup. */
  onAddAllSubtasks: (compoundTask: Task, leafTaskIds: string[]) => void;
  /** Open the task in the library sheet (`↗ Open in library`). */
  onOpenInLibrary: (taskId: string) => void;
  /** Tap the source header `▾` to return to the picker. */
  onChangeSource: () => void;
  /** Fired after `Derive smaller version…` saves a new counting task —
   *  the parent should auto-add the new id to `selectedTaskIds`. */
  onTaskCreated: (task: Task) => void;
}

/**
 * Source-board grid for the wizard's `From a board…` filter.
 *
 * Renders the source board at its real geometry; each square is a
 * tap target. Tap = Link. Long-press / right-click = floating
 * context menu (reuses the existing `RowContextMenu`). Visual states
 * are color/border only — blue tint = linked, amber tint = copied,
 * 35% opacity = expired, orange border = source's center square.
 *
 * Achievement squares get full parity with other types — no dimming,
 * no menu restriction.
 */
export function FromBoardGrid({
  boardId,
  userId,
  selectedTaskIds,
  copiedTaskIds,
  onToggleSelection,
  onCopyTask,
  onAddAllSubtasks,
  onOpenInLibrary,
  onChangeSource,
  onTaskCreated,
}: FromBoardGridProps): React.ReactElement {
  // `undefined` while loading; `null` after a confirmed not-found
  // (board was soft-deleted or its row otherwise disappeared after we
  // opened the grid). Distinguishing those states lets us recover —
  // a stuck "Loading…" with no exit affordance is worse than bouncing
  // the user back to the picker.
  const board: Board | undefined | null = useLiveQuery(
    async () => {
      const row = await db.boards.get(boardId);
      if (!row) return null;
      if (row.isDeleted) return null;
      return row;
    },
    [boardId],
    undefined as Board | undefined | null
  );
  const placements = useSourceBoardPlacements(boardId);

  // Compound-leaf preview & resolved leaves are needed for the
  // context-menu's compound branch. Fetched once per source.
  //
  // The query's dep key is a STABLE sorted-joined string of compound
  // ids — NOT the `placements` array itself. `placements` comes from
  // `useSourceBoardPlacements`, which returns a fresh array reference
  // on every Dexie change (any table). Without this memo, every
  // unrelated DB write (e.g., a sync pull on `tasks`) would cascade
  // a re-render of all three chained live queries here.
  const compoundIdKey = useMemo(() => {
    return placements
      .filter((p) => p.task?.type === TaskType.COMPOUND)
      .map((p) => p.task!.id)
      .sort()
      .join(',');
  }, [placements]);

  // useLiveQuery returns `T | undefined`; the `?? []` fallback would
  // create a fresh array reference on every render, retriggering any
  // downstream memo keyed on this value. Memoise the fallback once so
  // the reference is stable until Dexie returns a new result.
  const compoundChildLinksRaw = useLiveQuery(
    async () => {
      if (compoundIdKey.length === 0) return [];
      const compoundIds = compoundIdKey.split(',');
      // Use the `compoundTaskId` index (declared in db/database.ts) so
      // Dexie hits only matching rows rather than scanning the whole
      // compoundChildren table. Filter !isDeleted in-process after.
      const matching = await db.compoundChildren
        .where('compoundTaskId')
        .anyOf(compoundIds)
        .toArray();
      return matching.filter((c) => !c.isDeleted);
    },
    [compoundIdKey],
    [],
  );
  const compoundChildLinks = useMemo(
    () => compoundChildLinksRaw ?? [],
    [compoundChildLinksRaw],
  );

  // Map compoundTaskId → ordered list of child Task[]. Drives `Add all
  // subtasks to board` (and could power an inline expand later).
  // `compoundChildLinks` is already memoised above, so depending on it
  // directly is stable — re-runs only when Dexie returns a new link
  // set, not on every unrelated DB write.
  const compoundLeavesByParentRaw = useLiveQuery(
    async () => {
      if (compoundChildLinks.length === 0)
        return new Map<string, Task[]>();
      const childIds = Array.from(
        new Set(compoundChildLinks.map((c) => c.childTaskId)),
      );
      const tasks = await db.tasks
        .where('id')
        .anyOf(childIds)
        .filter((t) => !t.isDeleted)
        .toArray();
      const tasksById = new Map<string, Task>();
      for (const t of tasks) tasksById.set(t.id, t);
      const byParent = new Map<string, Task[]>();
      const sorted = [...compoundChildLinks].sort(
        (a, b) => a.childIndex - b.childIndex,
      );
      for (const link of sorted) {
        const child = tasksById.get(link.childTaskId);
        if (!child) continue;
        // Skip nested compounds — only primitive leaves are boardable.
        if (child.type === TaskType.COMPOUND) continue;
        const arr = byParent.get(link.compoundTaskId) ?? [];
        arr.push(child);
        byParent.set(link.compoundTaskId, arr);
      }
      return byParent;
    },
    [compoundChildLinks],
    new Map<string, Task[]>(),
  );
  const compoundLeavesByParent = useMemo(
    () => compoundLeavesByParentRaw ?? new Map<string, Task[]>(),
    [compoundLeavesByParentRaw],
  );

  const [rowContextMenu, setRowContextMenu] = useState<
    { taskId: string; x: number; y: number } | null
  >(null);
  const [derivingFromTask, setDerivingFromTask] = useState<Task | null>(null);
  const [deriveMaxCountInput, setDeriveMaxCountInput] = useState('');
  const [deriveError, setDeriveError] = useState<string | null>(null);

  // Build a (row,col)-keyed lookup so we can render the geometry even
  // when placements come in a different order.
  const placementGrid = useMemo(() => {
    const size = board?.boardSize ?? 0;
    const grid: Array<SourceBoardPlacement | undefined> = Array(
      size * size,
    ).fill(undefined);
    for (const p of placements) {
      const idx = p.placement.row * size + p.placement.col;
      if (idx >= 0 && idx < grid.length) grid[idx] = p;
    }
    return grid;
  }, [board?.boardSize, placements]);

  if (board === undefined) {
    return <div className={styles.empty}>Loading board…</div>;
  }
  if (board === null) {
    // The source board was deleted while the grid was open (likely a
    // sync pull from another device). Bounce back to the picker so
    // the user isn't stuck on a stale view.
    return (
      <div className={styles.empty}>
        This board is no longer available.{' '}
        <button
          type="button"
          className={styles.changeSourceButton}
          onClick={onChangeSource}
        >
          Pick a different board
        </button>
      </div>
    );
  }

  const size = board.boardSize;
  // FREE / CUSTOM_FREE boards have NO BoardTask placement at the
  // geometric center — those center squares are virtual (rendered by
  // BoardPlaySurface from board metadata). Without a special case
  // here, the source grid would show a dashed "empty" hole where the
  // play view shows the FREE square, breaking the "render real
  // geometry" contract.
  const usesFreeCenter =
    size % 2 === 1 &&
    (board.centerSquareType === CenterSquareType.FREE ||
      board.centerSquareType === CenterSquareType.CUSTOM_FREE);
  const freeCenterIndex = usesFreeCenter
    ? Math.floor(size / 2) * size + Math.floor(size / 2)
    : -1;
  const freeCenterText = usesFreeCenter
    ? getCenterDisplayText(
        board.centerSquareType,
        board.centerSquareCustomName,
      )
    : '';

  return (
    <div className={styles.container}>
      <div className={styles.header}>
        <button
          type="button"
          className={styles.sourceLabel}
          onClick={onChangeSource}
          aria-label="Pick a different source board"
        >
          <span className={styles.sourcePrefix}>Source:</span>
          <span className={styles.sourceName}>{board.name || 'Untitled board'}</span>
          <span className={styles.sourceChevron} aria-hidden="true">
            ▾
          </span>
        </button>
      </div>

      {placements.length === 0 ? (
        <div className={styles.empty}>Nothing to add from this board.</div>
      ) : (
        <div
          className={styles.grid}
          style={{
            gridTemplateColumns: `repeat(${size}, 1fr)`,
            gridTemplateRows: `repeat(${size}, 1fr)`,
          }}
        >
          {placementGrid.map((entry, idx) => {
            // Render the virtual FREE / CUSTOM_FREE center cell when
            // the source board has no BoardTask placement at the
            // geometric center. Non-interactive — there's no real
            // Task to link or copy.
            if (!entry && idx === freeCenterIndex) {
              return (
                <div
                  key={`free-${idx}`}
                  className={`${styles.cell} ${styles.cellFree}`}
                  aria-label={freeCenterText}
                >
                  <span className={styles.cellTitle}>{freeCenterText}</span>
                </div>
              );
            }
            return (
              <SourceCell
                key={entry?.placement.id ?? `empty-${idx}`}
                entry={entry}
                isSelected={
                  entry?.task ? selectedTaskIds.has(entry.task.id) : false
                }
                isCopied={
                  entry?.task ? copiedTaskIds.has(entry.task.id) : false
                }
                onTap={() => {
                  if (!entry?.task) return;
                  if (isTaskExpired(entry.task)) return;
                  onToggleSelection(entry.task.id);
                }}
                onContextMenu={(e) => {
                  if (!entry?.task) return;
                  if (isTaskExpired(entry.task)) return;
                  e.preventDefault();
                  setRowContextMenu({
                    taskId: entry.task.id,
                    x: e.clientX,
                    y: e.clientY,
                  });
                }}
              />
            );
          })}
        </div>
      )}

      {rowContextMenu && (() => {
        const target = placements.find(
          (p) => p.task?.id === rowContextMenu.taskId,
        )?.task;
        if (!target) return null;
        const items = buildMenuItems({
          target,
          isSelected: selectedTaskIds.has(target.id),
          isCopied: copiedTaskIds.has(target.id),
          leaves: compoundLeavesByParent.get(target.id) ?? [],
          onToggleSelection,
          onCopyTask,
          onAddAllSubtasks,
          onOpenInLibrary,
          onDerive: (t) => {
            setDerivingFromTask(t);
            setDeriveMaxCountInput('');
            setDeriveError(null);
          },
          close: () => setRowContextMenu(null),
        });
        return (
          <RowContextMenu
            x={rowContextMenu.x}
            y={rowContextMenu.y}
            items={items}
            onClose={() => setRowContextMenu(null)}
          />
        );
      })()}

      {derivingFromTask && (
        <DeriveCounterModal
          source={derivingFromTask}
          maxCountInput={deriveMaxCountInput}
          onMaxCountChange={(v) => {
            setDeriveMaxCountInput(v);
            setDeriveError(null);
          }}
          error={deriveError}
          onCancel={() => setDerivingFromTask(null)}
          onSave={async () => {
            const parsed = parseInt(deriveMaxCountInput.trim(), 10);
            if (!Number.isFinite(parsed) || parsed <= 0) {
              setDeriveError('Goal must be a positive integer');
              return;
            }
            const action = (derivingFromTask.action ?? '').trim();
            const unit = (derivingFromTask.unit ?? '').trim();
            const title = `${action} ${parsed} ${unit}`;
            try {
              const newTask = await createTask(userId, {
                title,
                type: TaskType.COUNTING,
                action,
                unit,
                maxCount: parsed,
              });
              onTaskCreated(newTask);
              setDerivingFromTask(null);
            } catch (err) {
              setDeriveError(err instanceof Error ? err.message : 'Failed to save');
            }
          }}
        />
      )}
    </div>
  );
}

// ─── Cell renderer ────────────────────────────────────────────────────────────

function SourceCell({
  entry,
  isSelected,
  isCopied,
  onTap,
  onContextMenu,
}: {
  entry: SourceBoardPlacement | undefined;
  isSelected: boolean;
  isCopied: boolean;
  onTap: () => void;
  onContextMenu: (e: React.MouseEvent) => void;
}): React.ReactElement {
  // Empty cell — either the source had a hole or the placement points
  // at a soft-deleted task. Renders inert.
  if (!entry || !entry.task) {
    return <div className={styles.cellEmpty} aria-hidden="true" />;
  }

  const task = entry.task;
  const expired = isTaskExpired(task);
  const isCenter = entry.placement.isCenter;

  const classes = [
    styles.cell,
    isSelected ? styles.cellLinked : '',
    isCopied && !isSelected ? styles.cellCopied : '',
    expired ? styles.cellExpired : '',
    isCenter ? styles.cellCenter : '',
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <button
      type="button"
      className={classes}
      onClick={onTap}
      onContextMenu={onContextMenu}
      disabled={expired}
      aria-pressed={isSelected}
      aria-label={task.title}
    >
      <span className={styles.cellTitle}>{task.title}</span>
      {expired && <span className={styles.cellExpiredPill}>expired</span>}
    </button>
  );
}

// ─── Menu builder ─────────────────────────────────────────────────────────────

function buildMenuItems({
  target,
  isSelected,
  isCopied: _isCopied,
  leaves,
  onToggleSelection,
  onCopyTask,
  onAddAllSubtasks,
  onOpenInLibrary,
  onDerive,
  close,
}: {
  target: Task;
  isSelected: boolean;
  isCopied: boolean;
  leaves: Task[];
  onToggleSelection: (taskId: string) => void;
  onCopyTask: (task: Task) => void;
  onAddAllSubtasks: (task: Task, leafTaskIds: string[]) => void;
  onOpenInLibrary: (taskId: string) => void;
  onDerive: (task: Task) => void;
  close: () => void;
}): RowContextMenuItem[] {
  const isCompound = target.type === TaskType.COMPOUND;
  const isCountingTemplate =
    target.type === TaskType.COUNTING &&
    target.action != null &&
    target.unit != null &&
    target.maxCount != null;

  return [
    {
      label: isSelected ? 'Remove from board' : 'Add to board (link)',
      glyph: isSelected ? '−' : '+',
      action: () => {
        onToggleSelection(target.id);
        close();
      },
    },
    {
      label: 'Add a copy of this task…',
      glyph: '⎘',
      action: () => {
        onCopyTask(target);
        close();
      },
    },
    ...(isCountingTemplate
      ? [
          {
            label: 'Derive smaller version…',
            glyph: '⇣',
            action: () => {
              onDerive(target);
              close();
            },
          },
        ]
      : []),
    ...(isCompound && leaves.length > 0
      ? [
          {
            label: 'Add all subtasks to board',
            glyph: '⧉',
            action: () => {
              onAddAllSubtasks(
                target,
                leaves.map((leaf) => leaf.id),
              );
              close();
            },
          },
        ]
      : []),
    {
      label: 'Open in library',
      glyph: '↗',
      action: () => {
        onOpenInLibrary(target.id);
        close();
      },
    },
  ];
}
