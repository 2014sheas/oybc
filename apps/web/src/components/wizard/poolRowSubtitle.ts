import {
  AchievementTrigger,
  OperatorType,
  TaskType,
  formatCount,
  resolveCountKind,
  type CompoundChild,
  type Task,
} from '@oybc/shared';

/** Type-specific detail line — mirrors iOS
 *  `RisoPoolListView.typeDetailSubtitle`. (Board Sources P4 dropped the
 *  provenance suffix — the design's copy rule bans provenance subtitles;
 *  the counter-family "shares a counter" hint was dropped under #548.) */
export function buildPoolRowSubtitle(
  task: Task,
  children: CompoundChild[],
): string | undefined {
  let base: string | undefined;
  switch (task.type) {
    case TaskType.COUNTING: {
      // The title already reads "{action} {goal} {unit}" — the caption is the goal alone.
      const { maxCount } = task;
      if (maxCount != null && maxCount > 0) base = `goal ${formatCount(maxCount, resolveCountKind(task))}`;
      break;
    }
    case TaskType.COMPOUND: {
      const n = children.length;
      if (n > 0) {
        const op = task.operator;
        const ruleLabel =
          op === OperatorType.OR
            ? `any of ${n}`
            : op === OperatorType.M_OF_N
              ? `at least ${task.threshold ?? n} of ${n}`
              : `all of ${n}`;
        base = `${n} sub-task${n === 1 ? '' : 's'} · ${ruleLabel}`;
      }
      break;
    }
    case TaskType.ACHIEVEMENT: {
      const trigger = task.achievementTrigger === AchievementTrigger.BINGO ? 'First Bingo' : 'GREENLOG';
      const target = task.referencedBoardId ? 'a board' : 'a repeating board';
      base = `Watch ${target} · ${trigger}`;
      break;
    }
    default:
      base = undefined;
  }
  return base;
}
