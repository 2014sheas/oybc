import { TaskType, canPromoteToCounter, counterDisplayName, formatCountTotal, resolveCountKind, type Task } from '@oybc/shared';
import { RisoButton, RisoIcon, RisoReturnPill, RisoToolbarPill, type RisoTaskType } from '../../../components/riso';
import type { TaskDetailData } from '../../../hooks/useTaskDetail';
import { AnchoredHero } from './AnchoredHero';
import { BoardlessCountingHero } from './BoardlessCountingHero';
import { DetailMenu } from './DetailMenu';
import { WatchedBoardHero } from './WatchedBoardHero';
import { heroKicker, heroTone } from './taskDetailModel';
import styles from './TaskDetail.module.css';

/** What the nav row's leading slot and Done pill do — route vs sheet. */
export type DetailChrome =
  | { kind: 'route'; onBack: () => void }
  | { kind: 'sheet'; onDone: () => void; returnTo?: { title: string; type: RisoTaskType; onReturn: () => void } };

export interface TaskDetailHeroProps {
  task: Task;
  data: TaskDetailData;
  chrome: DetailChrome;
  onEdit: () => void;
  onDelete: () => void;
  /** ⋯ › "Use as shared counter" — offered only when `canPromoteToCounter(task)`. */
  onUseAsCounter: () => void;
  onOpenTask: (taskId: string) => void;
  onOpenBoard: (boardId: string) => void;
  onOpenCounter: (counterId: string) => void;
}

/** The counter row under the hero: "Shared counter" (linked) / "Counts toward" (unit task), lifetime total, chevron. */
function CounterRow({ task, root, onOpen }: { task: Task; root: Task; onOpen: () => void }): React.ReactElement {
  const kind = resolveCountKind(root);
  const label = task.type === TaskType.COUNTING ? 'Shared counter' : 'Counts toward';
  return (
    <button type="button" className={styles.counterRow} aria-label={`Open ${counterDisplayName(root)} counter`} onClick={onOpen}>
      <span className={styles.counterText}>
        <span className={styles.counterEyebrow}>{label}</span>
        <span className={styles.counterName}>{counterDisplayName(root)}</span>
      </span>
      <span className={styles.counterTotal}>
        {formatCountTotal(root.currentCount ?? 0, kind)} <span className={styles.counterSub}>all-time</span>
      </span>
      <RisoIcon name="chevron" size={13} />
    </button>
  );
}

/**
 * The type-coloured hero band: nav row (back / return pill · ⋯ · Done), kicker,
 * title, description and the type's one live control (docs/TASK_DETAIL_REDESIGN.md
 * §A). No square in play → a counting task gets the board-less control; any
 * other type shows kicker, title, description and Edit only.
 *
 * @returns The band.
 */
export function TaskDetailHero({ task, data, chrome, onEdit, onDelete, onUseAsCounter, onOpenTask, onOpenBoard, onOpenCounter }: TaskDetailHeroProps): React.ReactElement {
  const tone = heroTone(task);
  const edit = <RisoButton kind="neutral" onClick={onEdit}>Edit</RisoButton>;
  const root = data.counterRoot;
  const counterName = root ? counterDisplayName(root) : null;
  const counterId = task.sharedCounterId ?? task.countsTowardCounterId ?? (task.isCounter ? task.id : null);
  const anchored = data.anchor && task.type !== TaskType.ACHIEVEMENT;
  return (
    <div className={`${styles.hero} ${styles[`tone_${tone}`]}`} data-tone={tone}>
      {chrome.kind === 'sheet' && <div className={styles.grabber} aria-hidden="true" />}
      <div className={styles.nav}>
        {chrome.kind === 'route' ? (
          <button type="button" className={styles.back} onClick={chrome.onBack}>
            <RisoIcon name="back" size={14} />
            Tasks
          </button>
        ) : chrome.returnTo ? (
          <RisoReturnPill title={chrome.returnTo.title} type={chrome.returnTo.type} onClick={chrome.returnTo.onReturn} />
        ) : <span />}
        <div className={styles.navRight}>
          <DetailMenu
            onDelete={onDelete}
            onOpenCounterSettings={counterId && task.type === TaskType.COUNTING ? () => onOpenCounter(counterId) : undefined}
            onUseAsCounter={canPromoteToCounter(task) ? onUseAsCounter : undefined}
          />
          {chrome.kind === 'sheet' && <RisoToolbarPill onBand onClick={chrome.onDone}>Done</RisoToolbarPill>}
        </div>
      </div>
      <div className={styles.heroBody}>
        <div className={styles.kicker}>{heroKicker(task, counterName, data.children.length)}</div>
        <h1 className={styles.title}>{task.title || '(untitled task)'}</h1>
        {task.description && <p className={styles.description}>{task.description}</p>}

        {task.type === TaskType.ACHIEVEMENT ? (
          <WatchedBoardHero
            task={task} userId={task.userId} board={data.watchedBoard} template={data.watchedTemplate}
            onOpenBoard={onOpenBoard} trailing={edit}
          />
        ) : anchored && data.anchor ? (
          <AnchoredHero anchor={data.anchor} userId={task.userId} trailing={edit} onOpenTask={onOpenTask} />
        ) : data.placementsLoaded && task.type === TaskType.COUNTING ? (
          <BoardlessCountingHero key={task.id} task={task} counterRoot={root} trailing={edit} />
        ) : (
          data.placementsLoaded && <div className={styles.editOnly}>{edit}</div>
        )}

        {root && counterId && (
          <CounterRow task={task} root={root} onOpen={() => onOpenCounter(root.id)} />
        )}
      </div>
    </div>
  );
}
