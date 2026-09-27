import { useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  TaskType,
  formatWindowLabel,
  isEventOwningTask,
  type Board,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import {
  fetchLiveEventsForTaskIds,
  previewLateLogCompoundRule,
  readClosedBoardSquareState,
  type LateLogCompoundAction,
} from '../../db/operations/lateLog';
import { useLateLog } from '../../hooks/useLateLog';
import { useModalA11y } from '../../hooks/useModalA11y';
import { parseCustomLogAmount } from '../counters/amountChips';
import { RisoButton, RisoChip } from '../riso';
import styles from './LateLogSheet.module.css';

/** Fixed late-log chip amounts (handoff frame p8c: "+1 +2 +5 Custom…"). */
const LATE_LOG_CHIP_AMOUNTS = [1, 2, 5] as const;

export interface LateLogSheetProps {
  /** The CLOSED board the log is made from. */
  board: Board;
  /** The tapped task (NORMAL / COUNTING / COMPOUND). */
  task: Task;
  /** The full workspace task map (compound child resolution). */
  taskMap: Record<string, Task>;
  /** Compound children by parent compound id. */
  compoundChildrenByCompound: Record<string, CompoundChild[]>;
  onClose: () => void;
}

/** Whole-instant bound `min(endDate, sealedAt)` as epoch ms — same bound the
 *  sealed snapshot uses. `null` when unparseable (open-ended). */
function sealedBoundMs(board: Board): number | null {
  const sealedMs = board.sealedAt ? new Date(board.sealedAt).getTime() : NaN;
  const endMs = board.endDate ? new Date(board.endDate).getTime() : NaN;
  if (Number.isNaN(sealedMs)) return Number.isNaN(endMs) ? null : endMs;
  if (Number.isNaN(endMs)) return sealedMs;
  return Math.min(endMs, sealedMs);
}

/** A direct event-owning child's sealed-bounded window count (increments
 *  for COUNTING; completions count as 1 for NORMAL). */
function childWindowSum(
  child: Task,
  events: ReadonlyArray<{ isDeleted: boolean; kind: string; occurredAt: string; delta?: number }>,
  board: Board,
): number {
  const startMs = new Date(board.startDate).getTime();
  const boundMs = sealedBoundMs(board);
  const kind = child.type === TaskType.NORMAL ? 'completion' : 'increment';
  const sum = events
    .filter((e) => {
      if (e.isDeleted || e.kind !== kind) return false;
      const t = new Date(e.occurredAt).getTime();
      return t >= startMs && (boundMs == null || t <= boundMs);
    })
    .reduce((acc, e) => acc + (kind === 'completion' ? 1 : (e.delta ?? 0)), 0);
  return Math.max(0, sum);
}

/** A direct child's CURRENT (sealed-bounded) completion — event-owning
 *  children resolve windowed; everything else reads its lifetime cache
 *  (read-only rows, per the WC compound-child-fallback rule). */
function childIsCurrentlyComplete(
  child: Task,
  events: ReadonlyArray<{ isDeleted: boolean; kind: string; occurredAt: string; delta?: number }>,
  board: Board,
): boolean {
  if (!isEventOwningTask(child)) return child.isCompleted;
  const sum = childWindowSum(child, events, board);
  if (child.type === TaskType.NORMAL) return sum > 0;
  return child.maxCount != null && sum >= child.maxCount;
}

/**
 * LateLogSheet — Board Edit redesign slice 4 (D15): the closed-board
 * direct-log sheet. Bottom sheet on phone, 460px modal on desktop. Each
 * committed amount / completion is one undoable event (R2) — the web
 * counting body STAGES an amount then commits it with "Log" (unlike iOS's
 * per-tap stepper), per the handoff frames (p8c vs i10).
 */
export function LateLogSheet({
  board,
  task,
  taskMap,
  compoundChildrenByCompound,
  onClose,
}: LateLogSheetProps): React.ReactElement {
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({ open: true, onCancel: onClose });
  const { commitCompletion, commitIncrement, commitCompoundParts, undo } = useLateLog(board.id);
  const [busy, setBusy] = useState(false);

  const windowLabel = formatWindowLabel(board.timeframe, board.startDate);

  return (
    <div className={styles.backdrop} onClick={onClose} role="presentation">
      <div
        ref={modalRef}
        className={styles.sheet}
        role="dialog"
        aria-label={`${windowLabel}: ${task.title}`}
        {...modalProps}
        onClick={(e) => e.stopPropagation()}
      >
        <div className={styles.header}>
          <div className={styles.headerText}>
            <div className={styles.window}>{windowLabel}</div>
            <div className={styles.title}>{task.title}</div>
          </div>
          <span className={styles.closedPill}>Closed</span>
          <button type="button" className={styles.closeButton} onClick={onClose} aria-label="Close">
            ✕
          </button>
        </div>

        {task.type === TaskType.NORMAL && (
          <NormalBody
            board={board}
            task={task}
            busy={busy}
            setBusy={setBusy}
            commitCompletion={commitCompletion}
            undo={undo}
            onClose={onClose}
          />
        )}

        {task.type === TaskType.COUNTING && (
          <CountingBody
            board={board}
            task={task}
            busy={busy}
            setBusy={setBusy}
            commitIncrement={commitIncrement}
            undo={undo}
            onClose={onClose}
          />
        )}

        {task.type === TaskType.COMPOUND && (
          <CompoundBody
            board={board}
            task={task}
            taskMap={taskMap}
            compoundChildrenByCompound={compoundChildrenByCompound}
            busy={busy}
            setBusy={setBusy}
            commitCompoundParts={commitCompoundParts}
            onClose={onClose}
          />
        )}

        {(task.type === TaskType.ACHIEVEMENT || task.type !== TaskType.NORMAL && task.type !== TaskType.COUNTING && task.type !== TaskType.COMPOUND) && (
          <p className={styles.noop}>This square can&rsquo;t be logged directly.</p>
        )}
      </div>
    </div>
  );
}

// ─── NORMAL ─────────────────────────────────────────────────────────────────

function NormalBody({
  board,
  task,
  busy,
  setBusy,
  commitCompletion,
  undo,
  onClose,
}: {
  board: Board;
  task: Task;
  busy: boolean;
  setBusy: (b: boolean) => void;
  commitCompletion: (taskId: string) => Promise<void>;
  undo: (taskId: string) => Promise<boolean>;
  onClose: () => void;
}): React.ReactElement {
  const state = useLiveQuery(() => readClosedBoardSquareState(board.id, task.id), [board.id, task.id]);
  const hasLateLog = (state?.lateLogs.length ?? 0) > 0;
  const isGreen = state?.isGreen ?? false;

  if (isGreen && !hasLateLog) {
    return <p className={styles.noop}>Already complete — this record can&rsquo;t be undone.</p>;
  }

  const handleClick = async (): Promise<void> => {
    setBusy(true);
    try {
      if (isGreen && hasLateLog) {
        await undo(task.id);
      } else {
        await commitCompletion(task.id);
      }
      onClose();
    } finally {
      setBusy(false);
    }
  };

  return (
    <RisoButton kind={isGreen ? 'neutral' : 'primary'} fullWidth onClick={() => void handleClick()} disabled={busy}>
      {isGreen ? 'Undo late log' : 'Mark done on board'}
    </RisoButton>
  );
}

// ─── COUNTING ───────────────────────────────────────────────────────────────

function CountingBody({
  board,
  task,
  busy,
  setBusy,
  commitIncrement,
  undo,
  onClose,
}: {
  board: Board;
  task: Task;
  busy: boolean;
  setBusy: (b: boolean) => void;
  commitIncrement: (taskId: string, delta: number) => Promise<void>;
  undo: (taskId: string) => Promise<boolean>;
  onClose: () => void;
}): React.ReactElement {
  const state = useLiveQuery(() => readClosedBoardSquareState(board.id, task.id), [board.id, task.id]);
  const [selected, setSelected] = useState<number>(1);
  const [customOpen, setCustomOpen] = useState(false);
  const [customDraft, setCustomDraft] = useState('');

  if (state === undefined) return <p className={styles.noop}>Loading…</p>;
  if (state === null) {
    return <p className={styles.noop}>This counter can&rsquo;t be logged directly here.</p>;
  }

  const max = task.maxCount ?? 0;
  const pct = max > 0 ? Math.min(100, (state.count / max) * 100) : 0;
  const hasLateLog = state.lateLogs.length > 0;

  const handleLog = async (amount: number): Promise<void> => {
    setBusy(true);
    try {
      await commitIncrement(task.id, amount);
      onClose();
    } finally {
      setBusy(false);
    }
  };

  const handleUndo = async (): Promise<void> => {
    setBusy(true);
    try {
      await undo(task.id);
    } finally {
      setBusy(false);
    }
  };

  const customAmount = parseCustomLogAmount(customDraft);

  return (
    <>
      <div className={styles.readout}>
        <div className={styles.count}>
          {state.count}
          {max > 0 && <span className={styles.countMax}>/{max}</span>}
        </div>
        <div className={styles.bar}>
          <div className={styles.barFill} style={{ width: `${pct}%` }} />
        </div>
        {task.unit && <span className={styles.unit}>{task.unit}</span>}
      </div>

      <div className={styles.chipRow}>
        {LATE_LOG_CHIP_AMOUNTS.map((amount) => (
          <RisoChip
            key={amount}
            on={!customOpen && selected === amount}
            onClick={() => {
              setCustomOpen(false);
              setSelected(amount);
            }}
          >
            +{amount}
          </RisoChip>
        ))}
        <RisoChip on={customOpen} onClick={() => setCustomOpen(true)}>
          Custom…
        </RisoChip>
      </div>

      {customOpen && (
        <div className={styles.customRow}>
          <input
            className={styles.customInput}
            type="text"
            inputMode="numeric"
            placeholder="Amount"
            value={customDraft}
            onChange={(e) => setCustomDraft(e.target.value)}
            aria-label="Custom amount"
          />
        </div>
      )}

      <RisoButton
        kind="blue"
        fullWidth
        disabled={busy || (customOpen && customAmount == null)}
        onClick={() => {
          // Read the amount to commit directly (never through `selected`
          // state) — `setSelected` inside this same handler wouldn't be
          // visible to a `handleLog` closed over the CURRENT render yet.
          const amount = customOpen ? customAmount : selected;
          if (amount == null) return;
          void handleLog(amount);
        }}
      >
        Log
      </RisoButton>

      {hasLateLog && (
        <button type="button" className={styles.undoLink} onClick={() => void handleUndo()} disabled={busy}>
          Undo late log
        </button>
      )}
    </>
  );
}

// ─── COMPOUND ───────────────────────────────────────────────────────────────

function CompoundBody({
  board,
  task,
  taskMap,
  compoundChildrenByCompound,
  busy,
  setBusy,
  commitCompoundParts,
  onClose,
}: {
  board: Board;
  task: Task;
  taskMap: Record<string, Task>;
  compoundChildrenByCompound: Record<string, CompoundChild[]>;
  busy: boolean;
  setBusy: (b: boolean) => void;
  commitCompoundParts: (
    compoundTaskId: string,
    actions: Array<{ childTaskId: string; kind: 'completion' | 'increment'; delta?: number }>,
  ) => Promise<void>;
  onClose: () => void;
}): React.ReactElement {
  const links = useMemo(
    () =>
      (compoundChildrenByCompound[task.id] ?? [])
        .filter((c) => !c.isDeleted)
        .sort((a, b) => a.childIndex - b.childIndex),
    [compoundChildrenByCompound, task.id],
  );
  const childIds = useMemo(() => links.map((l) => l.childTaskId), [links]);

  const events = useLiveQuery(() => fetchLiveEventsForTaskIds(childIds), [childIds], []) ?? [];

  const [stagedComplete, setStagedComplete] = useState<Set<string>>(new Set());
  const [stagedIncrement, setStagedIncrement] = useState<Set<string>>(new Set());

  const rows = links.map((link) => {
    const child = taskMap[link.childTaskId];
    const childEvents = events.filter((e) => e.taskId === link.childTaskId);
    const isCurrentlyComplete = child ? childIsCurrentlyComplete(child, childEvents, board) : false;
    return { link, child, isCurrentlyComplete, childEvents };
  });

  const stagedActions = useMemo<LateLogCompoundAction[]>(() => {
    const out: LateLogCompoundAction[] = [];
    for (const id of stagedComplete) out.push({ childTaskId: id, kind: 'completion' });
    for (const id of stagedIncrement) out.push({ childTaskId: id, kind: 'increment', delta: 1 });
    return out;
  }, [stagedComplete, stagedIncrement]);
  // The DB's own rule check (same planning + windowed `evaluateCompound` the
  // commit enforces), so the button never enables for a commit that would be
  // rejected — a staged +1 that finishes a counting child counts.
  const ruleMet =
    useLiveQuery(
      () => previewLateLogCompoundRule(board.id, task.id, stagedActions),
      [board.id, task.id, stagedActions],
      false,
    ) ?? false;

  const handleCommit = async (): Promise<void> => {
    setBusy(true);
    try {
      const actions: Array<{ childTaskId: string; kind: 'completion' | 'increment'; delta?: number }> = [];
      for (const { link, child, isCurrentlyComplete } of rows) {
        if (!child || isCurrentlyComplete) continue;
        if (stagedComplete.has(link.childTaskId) && child.type === TaskType.NORMAL) {
          actions.push({ childTaskId: link.childTaskId, kind: 'completion' });
        } else if (stagedIncrement.has(link.childTaskId) && child.type === TaskType.COUNTING) {
          actions.push({ childTaskId: link.childTaskId, kind: 'increment', delta: 1 });
        }
      }
      await commitCompoundParts(task.id, actions);
      onClose();
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className={styles.partsList}>
        {rows.map(({ link, child, isCurrentlyComplete, childEvents }) => {
          if (!child) return null;
          const readOnly = !isEventOwningTask(child) || isCurrentlyComplete;
          const staged =
            child.type === TaskType.NORMAL ? stagedComplete.has(link.childTaskId) : stagedIncrement.has(link.childTaskId);
          const on = isCurrentlyComplete || staged;
          return (
            <button
              key={link.id}
              type="button"
              className={styles.partRow}
              disabled={readOnly}
              onClick={() => {
                if (readOnly) return;
                if (child.type === TaskType.NORMAL) {
                  setStagedComplete((prev) => {
                    const next = new Set(prev);
                    if (next.has(link.childTaskId)) next.delete(link.childTaskId);
                    else next.add(link.childTaskId);
                    return next;
                  });
                } else if (child.type === TaskType.COUNTING) {
                  setStagedIncrement((prev) => {
                    const next = new Set(prev);
                    if (next.has(link.childTaskId)) next.delete(link.childTaskId);
                    else next.add(link.childTaskId);
                    return next;
                  });
                }
              }}
            >
              <span className={`${styles.partCheck} ${on ? styles.partCheckOn : styles.partCheckOff}`}>
                {on ? '✓' : ''}
              </span>
              <span className={styles.partLabel}>{child.title}</span>
              {child.type === TaskType.COUNTING && isEventOwningTask(child) && (
                <span className={styles.partMeta}>
                  {childWindowSum(child, childEvents, board) + (stagedIncrement.has(link.childTaskId) ? 1 : 0)}/
                  {child.maxCount ?? 0}
                </span>
              )}
            </button>
          );
        })}
      </div>

      <RisoButton kind="primary" fullWidth disabled={busy || !ruleMet} onClick={() => void handleCommit()}>
        Mark done on board
      </RisoButton>
    </>
  );
}
