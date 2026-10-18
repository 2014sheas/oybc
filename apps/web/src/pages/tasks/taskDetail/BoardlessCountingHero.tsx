import { useCallback, useRef, useState } from 'react';
import { formatCount, resolveCountKind, type Task } from '@oybc/shared';
import { LogControls } from '../../../components/boardPlay/squareSheet/LogControls';
import { heroCountSize, logStripText } from '../../../components/boardPlay/squareSheet/squareSheetModel';
import sheetStyles from '../../../components/boardPlay/squareSheet/SquareSheet.module.css';
import {
  decrementSharedCounter,
  incrementSharedCounter,
  setCounterDefaultLogAmount,
  undoLastCounterLog,
} from '../../../db/operations/tasks';
import { resolvePendingCount } from '../../../hooks/pendingCounts';
import { usePendingCounts } from '../../../hooks/usePendingCounts';
import { useBusyLook } from '../../../hooks/useBusyLook';

const ALL_TIME = 'All-time';

export interface BoardlessCountingHeroProps {
  /** The counting task the page shows. */
  task: Task;
  /** Its counter root when it is a linked row (the write and the count follow the root). */
  counterRoot: Task | null | undefined;
  trailing?: React.ReactNode;
}

interface Strip {
  text: string;
  undo: () => Promise<unknown>;
}

/**
 * The hero for a counting task with no square in play (docs/TASK_DETAIL_REDESIGN.md
 * binding decision 3 (4), 2026-10-18): the all-time count and the kind's
 * tap-to-log chips, writing "now" through the counter writes the Counters hub
 * uses — a linked row writes its root, anything else writes itself (a unit
 * task's counter credit follows from its own cascade). Every write raises an
 * Undo strip. iOS twin: `TaskDetailHeroView`'s board-less branch.
 *
 * @returns The hero body.
 */
export function BoardlessCountingHero({ task, counterRoot, trailing }: BoardlessCountingHeroProps): React.ReactElement {
  const source = task.sharedCounterId ? counterRoot ?? null : task;
  const kind = resolveCountKind(source ?? task);
  const unit = (source ?? task).unit ?? '';
  const live = source?.currentCount ?? 0;
  const [busy, setBusy] = useState(false);
  // The count moves on tap (pending), not when the live row re-emits; controls are inert for the
  // whole write and only LOOK busy if it runs long.
  const liveOf = useCallback(() => live, [live]);
  const { pending, withPending } = usePendingCounts(liveOf, source);
  const count = source ? resolvePendingCount(pending, source.id, live) : live;
  const dim = useBusyLook(busy);
  const [strip, setStrip] = useState<Strip | null>(null);
  const inFlight = useRef(false);

  const run = async (write: () => Promise<Strip | null>): Promise<void> => {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    try {
      setStrip(await write());
    } catch (e) {
      console.error('Board-less counter write failed:', e);
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };

  const onLog = (direction: 'add' | 'remove', amount: number, persist: boolean): void => {
    if (!source || amount <= 0) return;
    const id = source.id;
    void run(async () => {
      if (direction === 'add') {
        await withPending(id, amount, () => incrementSharedCounter(id, amount), () => true);
        if (persist) await setCounterDefaultLogAmount(id, amount);
        return {
          text: logStripText('logged', amount, kind, unit, ALL_TIME),
          undo: () => withPending(id, -amount, () => undoLastCounterLog(id), () => true),
        };
      }
      const { effectiveDelta } = await withPending(id, -amount, () => decrementSharedCounter(id, amount), (r) => r.effectiveDelta !== 0);
      const removed = Math.abs(effectiveDelta);
      if (removed <= 0) return null;
      return {
        text: logStripText('removed', removed, kind, unit, ALL_TIME),
        undo: () => withPending(id, removed, () => incrementSharedCounter(id, removed), () => true),
      };
    });
  };

  const onUndo = (): void => {
    const s = strip;
    if (!s) return;
    void run(async () => { await s.undo(); return null; });
  };

  return (
    <div className={`${sheetStyles.body} ${sheetStyles.onColor}`} style={{ marginTop: 18 }}>
      <div className={sheetStyles.heroRow}>
        <span className={`${sheetStyles.count} ${sheetStyles.countBlue}`} style={{ fontSize: heroCountSize(kind) }}>
          {formatCount(count, kind)}
        </span>
        <span className={sheetStyles.heroLine}>{ALL_TIME}</span>
      </div>
      <div className={sheetStyles.eyebrowRow}>
        <span className={sheetStyles.eyebrow}>Tap to log</span>
      </div>
      <LogControls
        kind={kind} unit={unit} goal={null} count={count} size="regular" busy={busy || !source} dim={dim || !source}
        stripText={strip?.text ?? null} removeDisabled={count <= 0} trailing={trailing}
        onLog={onLog} onUndo={onUndo}
      />
    </div>
  );
}
