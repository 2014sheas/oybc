import { formatCount } from '@oybc/shared';
import { RisoIcon, RisoTypeBadge, UndoStrip } from '../../riso';
import { StatusPill } from '../../StatusPill';
import type { CompoundChild } from '../../interactiveTaskSquareUtils';
import { LogControls } from './LogControls';
import { childMeta, progressPill, subtaskLine } from './squareSheetModel';
import styles from './SquareSheet.module.css';

const PILL_LABELS = { completed: 'DONE', inProgress: 'IN PROGRESS', notStarted: '' };

export interface CompoundBodyProps {
  children: ReadonlyArray<CompoundChild>;
  /** The compound itself is satisfied (operator-aware). */
  done: boolean;
  boardLabel: string;
  busy: boolean;
  closedRow: React.ReactNode | null;
  /** The counting child whose chips are unfolded (one at a time). */
  /** Completed plain children whose un-complete is blocked by a sealed window. */
  blockedChildIds: ReadonlySet<string>;
  openChildId: string | null;
  /** The unfolded child's Undo strip line. */
  stripText: string | null;
  /** The checklist's own Undo strip (a child toggle): "‹child› · done". */
  toggleStripText: string | null;
  onUndoToggle: () => void;
  onToggleChild: (childTaskId: string) => void;
  onUnfoldChild: (childTaskId: string | null) => void;
  onLogChild: (childTaskId: string, amount: number, persist: boolean) => void;
  onUndoChild: () => void;
  onOpenChild: (childTaskId: string) => void;
}

/**
 * The Compound square's sheet body: done-count, segmented bar and the
 * sub-task checklist. A counting child's box is a `+` that unfolds its
 * tap-to-log chips inline (it is driven, never toggled).
 *
 * @returns The body.
 */
export function CompoundBody(p: CompoundBodyProps): React.ReactElement {
  const doneCount = p.children.filter((c) => c.isCompleted).length;
  const pill = progressPill(p.done, doneCount > 0);
  return (
    <>
      <div className={styles.heroRow}>
        <span className={`${styles.count} ${styles.countTeal}`} style={{ fontSize: 52 }}>{doneCount}</span>
        <span className={styles.heroLine}>{subtaskLine(p.children.length, p.boardLabel)}</span>
        {pill && (
          <span className={styles.heroPill}>
            <StatusPill status={pill} dense labels={PILL_LABELS} />
          </span>
        )}
      </div>
      <div className={styles.segments} aria-hidden="true">
        {p.children.map((c) => (
          <div key={c.taskId} className={`${styles.segment} ${c.isCompleted ? styles.segmentDone : ''}`} />
        ))}
      </div>
      <div className={styles.checklist}>
        {p.children.map((child) => {
          const open = p.openChildId === child.taskId;
          return (
            <div key={child.taskId} className={styles.child}>
              <div className={styles.childRow}>
                {p.closedRow ? (
                  <span className={`${styles.box} ${child.isCompleted ? styles.boxDone : ''}`} aria-hidden="true">
                    {child.isCompleted ? <RisoIcon name="check" size={16} /> : null}
                  </span>
                ) : child.count ? (
                  <button
                    type="button"
                    className={`${styles.box} ${child.isCompleted ? styles.boxDone : ''}`}
                    aria-expanded={open}
                    aria-label={`Log ${child.title}`}
                    onClick={() => p.onUnfoldChild(open ? null : child.taskId)}
                  >
                    {child.isCompleted ? <RisoIcon name="check" size={16} /> : '+'}
                  </button>
                ) : (
                  <button
                    type="button"
                    role="checkbox"
                    aria-checked={child.isCompleted}
                    aria-label={child.title}
                    className={`${styles.box} ${child.isCompleted ? styles.boxDone : ''}`}
                    disabled={p.busy || (child.isCompleted && p.blockedChildIds.has(child.taskId))}
                    onClick={() => p.onToggleChild(child.taskId)}
                  >
                    {child.isCompleted && <RisoIcon name="check" size={16} />}
                  </button>
                )}
                <RisoTypeBadge type={child.taskType ?? 'normal'} size="small" />
                <button
                  type="button"
                  className={styles.childName}
                  aria-label={`Open ${child.title} in library`}
                  onClick={() => p.onOpenChild(child.taskId)}
                >
                  <span className={`${styles.childTitle} ${child.isCompleted ? styles.childTitleDone : ''}`}>{child.title}</span>
                  {child.count && <span className={styles.childMeta}>{childMeta(child.count.current, child.count.max, child.count.kind)}</span>}
                  <span className={styles.chevron}>
                    <RisoIcon name="chevron" size={12} />
                  </span>
                </button>
              </div>
              {child.count && open && !p.closedRow && (
                <div className={styles.childOpen}>
                  <div
                    className={`${styles.bar} ${styles.barSmall}`}
                    role="img"
                    aria-label={`${formatCount(child.count.current, child.count.kind)} of ${formatCount(child.count.max, child.count.kind)}`}
                  >
                    <div
                      className={`${styles.barFill} ${child.count.current > child.count.max ? styles.barFillOver : ''}`}
                      style={{ width: `${child.count.max > 0 ? Math.min(1, child.count.current / child.count.max) * 100 : 0}%` }}
                    />
                  </div>
                  <LogControls
                    kind={child.count.kind} unit={child.count.unit} goal={child.count.max} count={child.count.current}
                    size="compact" busy={p.busy} stripText={p.stripText}
                    onLog={(_dir, amount, persist) => p.onLogChild(child.taskId, amount, persist)} onUndo={p.onUndoChild}
                  />
                </div>
              )}
            </div>
          );
        })}
      </div>
      {p.toggleStripText && <UndoStrip text={p.toggleStripText} onUndo={p.onUndoToggle} disabled={p.busy} />}
      {p.closedRow}
    </>
  );
}
