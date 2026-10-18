import { AchievementTrigger, TaskType, countUnitSuffix, counterDisplayName, formatCountTotal, resolveCountKind, type Task } from '@oybc/shared';
import { RisoBadge, RisoIcon, RisoSegmented, RisoTypeBadge, type RisoTaskType } from '../../../components/riso';
import type { TaskDetailData } from '../../../hooks/useTaskDetail';
import { formatRelativeTime } from '../../../utils/relativeTime';
import { activityDot, activityWhen, segmentOptions, subtasksHeading, type BoardRow, type DetailSegment } from './taskDetailModel';
import styles from './TaskDetail.module.css';

export interface TaskDetailSectionsProps {
  task: Task;
  data: TaskDetailData;
  segment: DetailSegment;
  onSegment: (segment: DetailSegment) => void;
  onOpenTask: (taskId: string) => void;
  onOpenBoard: (boardId: string) => void;
  onOpenCounter: (counterId: string) => void;
}

const typeOf = (t: Task): RisoTaskType => t.type as RisoTaskType;

/** A card with a heading and an optional "›" jump into another segment. */
function Card({ heading, jump, onJump, children }: { heading: string; jump?: string; onJump?: () => void; children: React.ReactNode }): React.ReactElement {
  return (
    <section className={styles.card}>
      <div className={styles.cardHead}>
        <h2 className={styles.cardHeading}>{heading}</h2>
        {jump && onJump && (
          <button type="button" className={styles.jump} onClick={onJump}>
            {jump}
            <RisoIcon name="chevron" size={12} />
          </button>
        )}
      </div>
      {children}
    </section>
  );
}

function Ring({ row }: { row: BoardRow }): React.ReactElement {
  const style = row.done
    ? { background: 'var(--riso-green)', borderColor: 'var(--riso-green)' }
    : row.draft ? { borderStyle: 'dashed' as const }
      : { background: `conic-gradient(var(--riso-gold) ${Math.round(row.fraction * 360)}deg, transparent 0)` };
  return (
    <span className={styles.ring} style={style} aria-hidden="true">
      {row.done && <RisoIcon name="check" size={12} />}
    </span>
  );
}

function BoardRowButton({ row, onOpen }: { row: BoardRow; onOpen: () => void }): React.ReactElement {
  return (
    <button type="button" className={styles.boardRow} aria-label={`Open board ${row.name}`} onClick={onOpen}>
      <Ring row={row} />
      <span className={styles.boardText}>
        <span className={styles.boardName}>
          <span className={styles.boardNameText}>{row.name}</span>
          {row.badge && <span className={styles.coreBadge}>{row.badge}</span>}
        </span>
        <span className={styles.boardCaption}>{row.caption}</span>
      </span>
      {row.draft && <RisoBadge kind="draft">Draft</RisoBadge>}
      {row.value && <span className={styles.boardValue}>{row.value}</span>}
      <RisoIcon name="chevron" size={12} />
    </button>
  );
}

function BoardsCard({ data, segment, onSegment, onOpenBoard }: { data: TaskDetailData; segment: DetailSegment; onSegment: (s: DetailSegment) => void; onOpenBoard: (id: string) => void }): React.ReactElement {
  const active = data.rows.filter((r) => r.active);
  const past = data.rows.filter((r) => !r.active);
  const all = segment === 'all';
  return (
    <Card heading={`On boards now · ${active.length}`} jump={all ? 'All boards' : undefined} onJump={() => onSegment('boards')}>
      {active.length === 0 && <p className={styles.empty}>Not on a board</p>}
      {active.map((r) => <BoardRowButton key={r.boardId} row={r} onOpen={() => onOpenBoard(r.boardId)} />)}
      {!all && past.length > 0 && (
        <>
          <div className={styles.subHead}>{`Past & drafts · ${past.length}`}</div>
          {past.map((r) => <BoardRowButton key={r.boardId} row={r} onOpen={() => onOpenBoard(r.boardId)} />)}
        </>
      )}
    </Card>
  );
}

function ActivityCard({ task, data, full, onSegment }: { task: Task; data: TaskDetailData; full: boolean; onSegment: (s: DetailSegment) => void }): React.ReactElement {
  const rows = data.activity?.rows ?? [];
  const updated = formatRelativeTime(task.updatedAt);
  return (
    <Card heading="Activity" jump={full ? undefined : 'Full activity'} onJump={() => onSegment('activity')}>
      {full ? (
        <>
          {rows.map((r) => (
            <div key={r.key} className={styles.activityRow}>
              <span className={styles.dot} style={{ background: activityDot(r.kind) }} aria-hidden="true" />
              <span className={styles.activityText}>{r.text}</span>
              <span className={styles.activityWhen}>{activityWhen(r.at)}</span>
            </div>
          ))}
          <div className={styles.activityFoot}>
            {`Completed ${data.activity?.completionCount ?? 0}× all-time${updated ? ` · updated ${updated}` : ''}`}
          </div>
        </>
      ) : (
        <div className={styles.recent}>
          <span className={styles.recentLine}>{rows[0]?.text ?? ''}</span>
          {rows[1] && <span className={styles.recentSub}>{rows[1].text}</span>}
        </div>
      )}
    </Card>
  );
}

function ParentsCard({ data, onOpenTask, onJump }: { data: TaskDetailData; onOpenTask: (id: string) => void; onJump?: () => void }): React.ReactElement | null {
  if (data.parentCompounds.length === 0) return null;
  return (
    <Card heading="Subtask of" jump={onJump ? 'All links' : undefined} onJump={onJump}>
      <div className={styles.chips}>
        {data.parentCompounds.map((p) => (
          <button key={p.id} type="button" className={styles.chip} aria-label={`Open parent task: ${p.title || '(untitled task)'}`} onClick={() => onOpenTask(p.id)}>
            <RisoTypeBadge type={typeOf(p)} size="small" />
            <span className={styles.chipText}>{p.title || '(untitled task)'}</span>
            <RisoIcon name="chevron" size={11} />
          </button>
        ))}
      </div>
    </Card>
  );
}

function LinksSection({ task, data, onOpenTask, onOpenBoard, onOpenCounter }: Omit<TaskDetailSectionsProps, 'segment' | 'onSegment'>): React.ReactElement {
  const root = data.counterRoot;
  const children = data.children;
  const triggerWord = task.achievementTrigger === AchievementTrigger.BINGO ? 'First bingo' : 'Greenlog';
  const nothing = !root && data.parentCompounds.length === 0 && children.length === 0 && data.templates.length === 0
    && task.type !== TaskType.ACHIEVEMENT;
  return (
    <div className={styles.stack}>
      {root && (
        <Card heading={task.type === TaskType.COUNTING ? 'Shared counter' : 'Counts toward'}>
          <button type="button" className={styles.linkRow} onClick={() => onOpenCounter(root.id)} aria-label={`Open ${counterDisplayName(root)} counter`}>
            <span className={styles.hashBadge} aria-hidden="true">#</span>
            <span className={styles.linkText}>
              <span className={styles.linkName}>{counterDisplayName(root)}</span>
            </span>
            <span className={styles.linkTotal}>{`${formatCountTotal(root.currentCount ?? 0, resolveCountKind(root))}${countUnitSuffix(resolveCountKind(root), root.unit)}`}</span>
            <RisoIcon name="chevron" size={12} />
          </button>
        </Card>
      )}
      <ParentsCard data={data} onOpenTask={onOpenTask} />
      {task.type === TaskType.COMPOUND && children.length > 0 && (
        <Card heading={subtasksHeading(task, children.length)}>
          {children.map(({ link, task: child }) => (
            <button key={link.id} type="button" className={styles.linkRow} aria-label={`Open subtask: ${child.title || '(untitled task)'}`} onClick={() => onOpenTask(child.id)}>
              <RisoTypeBadge type={typeOf(child)} size="small" />
              <span className={styles.linkText}><span className={styles.linkName}>{child.title || '(untitled task)'}</span></span>
              {data.childDone[child.id] && <span className={styles.doneTick}><RisoIcon name="check" size={14} /></span>}
              <RisoIcon name="chevron" size={11} />
            </button>
          ))}
        </Card>
      )}
      {task.type === TaskType.ACHIEVEMENT && (
        <Card heading={task.referencedTemplateId ? 'Watches repeating board' : 'Watches board'}>
          {task.referencedBoardId ? (
            <button type="button" className={styles.linkRow} disabled={!data.watchedBoard} onClick={() => task.referencedBoardId && onOpenBoard(task.referencedBoardId)}>
              <RisoIcon name="grid" size={14} />
              <span className={styles.linkText}>
                <span className={styles.linkName}>{data.watchedBoard?.name ?? 'Board unavailable'}</span>
                <span className={styles.linkMeta}>{triggerWord}</span>
              </span>
              <RisoIcon name="chevron" size={11} />
            </button>
          ) : (
            <div className={styles.linkRow}>
              <RisoIcon name="repeat" size={14} />
              <span className={styles.linkText}>
                <span className={styles.linkName}>{data.watchedTemplate?.name ?? 'Board unavailable'}</span>
                <span className={styles.linkMeta}>{triggerWord}</span>
              </span>
            </div>
          )}
        </Card>
      )}
      {data.templates.length > 0 && (
        <Card heading="Part of repeating board">
          {data.templates.map((t) => (
            <div key={t.id} className={styles.linkRow} aria-label={`Part of repeating board: ${t.name}`} role="group">
              <RisoIcon name="repeat" size={12} />
              <span className={styles.linkText}><span className={styles.linkName}>{t.name}</span></span>
            </div>
          ))}
        </Card>
      )}
      {nothing && <p className={styles.empty}>No links</p>}
    </div>
  );
}

/**
 * The segmented pill and the section it selects: All (overview cards with "›"
 * jumps) · Boards · N · Links · Activity (docs/TASK_DETAIL_REDESIGN.md §A).
 * The segment is controlled so the sheet can keep it across task swaps.
 *
 * @returns The body.
 */
export function TaskDetailSections(props: TaskDetailSectionsProps): React.ReactElement {
  const { task, data, segment, onSegment, onOpenTask, onOpenBoard } = props;
  return (
    <div className={styles.body}>
      <div className={styles.segmentRow}>
        <RisoSegmented variant="pill" aria-label="Task detail section" value={segment} onChange={onSegment} options={segmentOptions(data.rows.length)} />
      </div>
      {segment === 'all' && (
        <div className={styles.stack}>
          <BoardsCard data={data} segment={segment} onSegment={onSegment} onOpenBoard={onOpenBoard} />
          <ParentsCard data={data} onOpenTask={onOpenTask} onJump={() => onSegment('links')} />
          <ActivityCard task={task} data={data} full={false} onSegment={onSegment} />
        </div>
      )}
      {segment === 'boards' && <BoardsCard data={data} segment={segment} onSegment={onSegment} onOpenBoard={onOpenBoard} />}
      {segment === 'links' && <LinksSection {...props} />}
      {segment === 'activity' && <ActivityCard task={task} data={data} full onSegment={onSegment} />}
    </div>
  );
}
