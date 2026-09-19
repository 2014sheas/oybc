import {
  TaskType,
  effectiveMemberTarget,
  partRuleFor,
  splitSquaresNote,
  varyRangeLabel,
  type BoardSourceMemberRule,
  type BoardWindow,
  type CompoundChild,
  type PlanMode,
  type Task,
  type VaryLevel,
} from '@oybc/shared';
import { CounterStepper } from '../CounterStepper';
import { DiceButton, RisoSegmented } from '../riso';
import { TypeBadge } from '../TypeBadge';
import styles from './MemberRuleRow.module.css';

/** How a pulled member currently participates in the board being assembled. */
export type MemberState = 'included' | 'excluded' | 'filteredDone';

/** off → a little → a lot → off (handoff §Interactions "Variation (dice)"). */
function nextVary(level: VaryLevel): VaryLevel {
  return level === 0 ? 1 : level === 1 ? 2 : 0;
}

interface MemberRuleRowProps {
  /** The member's task (staged-overlaid), or `undefined` mid-hydration. */
  task: Task | undefined;
  /** Title + type lookup, for compound part names. */
  taskById: Record<string, Task>;
  /** Whether the member is on the board, excluded, or filtered out as done. */
  state: MemberState;
  /** Counter-family exclusivity hint ("shares a counter with …"). */
  clashTitle?: string;
  /** This member's stored rule (`memberRuleFor`) — `{}` when it has none. */
  rule: BoardSourceMemberRule;
  /** The member's `compound_children`, `childIndex`-ordered. Empty = plain member. */
  parts: CompoundChild[];
  /** True when the supplying source is `kind: 'board'` — gates the target stepper. */
  fromBoard: boolean;
  /** The source board's own window, for pro-rating an auto target. */
  sourceWindow?: BoardWindow;
  /** The window of the board being assembled. */
  wizardWindow: BoardWindow;
  /** Whether the board being assembled is one-off or repeating. */
  mode: PlanMode;
  onToggleExclude: () => void;
  onSetTarget: (target: number | undefined) => void;
  onSetVary: (level: VaryLevel) => void;
  onSetSplit: (split: boolean) => void;
  onSetPartExcluded: (childId: string, excluded: boolean) => void;
  onSetPartTarget: (childId: string, target: number | undefined) => void;
  onSetPartVary: (childId: string, level: VaryLevel) => void;
}

/**
 * MemberRuleRow — one member row inside an expanded source panel, with the
 * per-member rule controls (docs/BOARD_SOURCES.md §Member rules; handoff
 * "Expanded source panel" item 3).
 *
 * Three shapes, all driven by the member's own type:
 *
 * - **Counting** — a compact target stepper (board sources only; a pool
 *   member has no window to pro-rate against, so it gets the dice alone),
 *   the "of {goal} {unit}" caption, then the dice. A dice that's on adds a
 *   blue range line under the row.
 * - **Compound with parts** — a One square / Split up pill plus the
 *   "N squares" note (dice on that line only while One square), then one
 *   line per part: name · stepper · "of {goal}" · dice and ✕ while split.
 *   A part's range line sits under that part's line.
 * - **Anything else** (normal, achievement, childless compound) — just the
 *   title and the shared exclude control.
 *
 * Owns the whole `<li>` (not just the rule strip) so `SourceRow` stays a
 * header + range-block renderer. iOS twin lands in B3 Task 6.
 *
 * @param props - See {@link MemberRuleRowProps}.
 * @returns The member row.
 */
export function MemberRuleRow({
  task,
  taskById,
  state,
  clashTitle,
  rule,
  parts,
  fromBoard,
  sourceWindow,
  wizardWindow,
  mode,
  onToggleExclude,
  onSetTarget,
  onSetVary,
  onSetSplit,
  onSetPartExcluded,
  onSetPartTarget,
  onSetPartVary,
}: MemberRuleRowProps): React.ReactElement {
  const title = task?.title || '(untitled task)';
  const memberVary: VaryLevel = rule.vary ?? 0;
  /**
   * Rule controls belong to members that are actually going on the board.
   * An excluded or filtered-out-as-done member renders exactly what it did
   * before B3 (struck + UNDO / dimmed ✓) — editing a target for a square
   * that isn't being placed is the same contradiction the part rows already
   * avoid. Design: `hasTarget`/`hasParts` are both gated on `!ex && !dOut`.
   */
  const isOn = state === 'included';

  const goal = task?.type === TaskType.COUNTING ? (task.maxCount ?? 0) : 0;
  const isCounting = goal > 0;
  const unit = task?.unit ?? '';
  const target = isCounting
    ? effectiveMemberTarget({
        goal,
        explicit: rule.target,
        mode,
        fromBoard,
        sourceWindow,
        targetWindow: wizardWindow,
      })
    : 0;
  const memberRange = isCounting ? varyRangeLabel(target, memberVary, goal, unit) : null;

  const isCompound = task?.type === TaskType.COMPOUND && parts.length > 0;
  const split = rule.split === true;
  const excludedPartIds = new Set(
    parts.map((p) => p.childTaskId).filter((id) => partRuleFor(rule, id).excluded === true),
  );

  return (
    // `data-testid` so an e2e locator can resolve ONE member row: both this
    // and its ancestor `SourceRow` card are `<li>`s, so a `listitem` filter
    // matches the card first and a strict-mode locator inside it sees every
    // member's stepper and dice at once.
    <li
      className={`${styles.row} ${state !== 'included' ? styles.dimmed : ''}`}
      data-testid="member-row"
    >
      <div className={styles.mainLine}>
        <TypeBadge type={task?.type ?? TaskType.NORMAL} letterOnly size="small" />
        <span className={styles.text}>
          <span className={`${styles.title} ${state === 'excluded' ? styles.struck : ''}`}>
            {title}
          </span>
          {clashTitle !== undefined && (
            <span className={styles.clashHint}>
              shares a counter with &ldquo;{clashTitle}&rdquo; &middot; one per board
            </span>
          )}
        </span>
        {isOn && isCounting && fromBoard && (
          <>
            <CounterStepper
              size="compact"
              value={target}
              min={1}
              max={goal}
              onChange={(next) => onSetTarget(next)}
            />
            <span className={styles.caption}>
              of {goal}
              {unit ? ` ${unit}` : ''}
            </span>
          </>
        )}
        {isOn && isCounting && (
          <DiceButton level={memberVary} onCycle={() => onSetVary(nextVary(memberVary))} />
        )}
        {state === 'included' && (
          <button
            type="button"
            className={styles.exclude}
            onClick={onToggleExclude}
            aria-label={`Exclude ${title} for this board`}
          >
            ✕
          </button>
        )}
        {state === 'excluded' && (
          <button
            type="button"
            className={styles.undo}
            onClick={onToggleExclude}
            aria-label={`Undo excluding ${title}`}
          >
            UNDO
          </button>
        )}
        {state === 'filteredDone' && (
          <span className={styles.doneCheck} aria-label={`${title} is done`}>
            ✓
          </span>
        )}
      </div>

      {isOn && memberRange !== null && <p className={styles.rangeLine}>{memberRange}</p>}

      {isOn && isCompound && (
        <div className={styles.splitLine}>
          <RisoSegmented
            options={[
              { value: 'one', label: 'One square' },
              { value: 'split', label: 'Split up' },
            ]}
            value={split ? 'split' : 'one'}
            onChange={(v) => onSetSplit(v === 'split')}
            variant="pill"
            size="compact"
            aria-label={`Squares for ${title}`}
          />
          <span className={styles.squaresNote}>
            {/* One square puts the WHOLE compound on as a single square —
                `splitSquaresNote` counts included parts, which is the
                split-mode answer only. */}
            {split
              ? splitSquaresNote(
                  parts.map((p) => p.childTaskId),
                  excludedPartIds,
                )
              : '1 square'}
          </span>
          {!split && (
            <DiceButton level={memberVary} onCycle={() => onSetVary(nextVary(memberVary))} />
          )}
        </div>
      )}

      {isOn &&
        isCompound &&
        parts.map((part) => (
          <PartLine
            key={part.id}
            childId={part.childTaskId}
            canExclude={parts.length - excludedPartIds.size > 1}
            task={taskById[part.childTaskId]}
            rule={rule}
            split={split}
            memberVary={memberVary}
            fromBoard={fromBoard}
            sourceWindow={sourceWindow}
            wizardWindow={wizardWindow}
            mode={mode}
            onSetPartExcluded={onSetPartExcluded}
            onSetPartTarget={onSetPartTarget}
            onSetPartVary={onSetPartVary}
          />
        ))}
    </li>
  );
}

interface PartLineProps {
  childId: string;
  /**
   * Whether this part may still be dropped — false for the last included
   * part, which the state layer would refuse anyway. The control is HIDDEN
   * rather than disabled: the design omits it (`canEx`), and an inert ✕
   * reads as a broken toggle.
   */
  canExclude: boolean;
  task: Task | undefined;
  rule: BoardSourceMemberRule;
  split: boolean;
  memberVary: VaryLevel;
  fromBoard: boolean;
  sourceWindow?: BoardWindow;
  wizardWindow: BoardWindow;
  mode: PlanMode;
  onSetPartExcluded: (childId: string, excluded: boolean) => void;
  onSetPartTarget: (childId: string, target: number | undefined) => void;
  onSetPartVary: (childId: string, level: VaryLevel) => void;
}

/**
 * One part of a compound member: name · target stepper · caption · dice ·
 * ✕, with its own range line. Dice and ✕ appear only while the member is
 * split — One square rolls one dice for the whole compound (on the toggle
 * line) and contributes one square, so a part has nothing to exclude.
 *
 * @param props - See {@link PartLineProps}.
 * @returns The part line (and its range line, when the dice is on).
 */
function PartLine({
  childId,
  canExclude,
  task,
  rule,
  split,
  memberVary,
  fromBoard,
  sourceWindow,
  wizardWindow,
  mode,
  onSetPartExcluded,
  onSetPartTarget,
  onSetPartVary,
}: PartLineProps): React.ReactElement {
  const partRule = partRuleFor(rule, childId);
  const excluded = split && partRule.excluded === true;
  const name = task?.title || '(untitled task)';
  const goal = task?.type === TaskType.COUNTING ? (task.maxCount ?? 0) : 0;
  const isCounting = goal > 0;
  const level: VaryLevel = split ? (partRule.vary ?? 0) : memberVary;
  const target = isCounting
    ? effectiveMemberTarget({
        goal,
        explicit: partRule.target,
        mode,
        fromBoard,
        sourceWindow,
        targetWindow: wizardWindow,
      })
    : 0;
  const range = isCounting ? varyRangeLabel(target, level, goal, '') : null;

  if (excluded) {
    return (
      <div className={`${styles.partLine} ${styles.dimmed}`}>
        <span className={`${styles.partName} ${styles.struck}`}>{name}</span>
        <button
          type="button"
          // PART scale, not member scale — iOS renders this one at
          // 10.5/extraBold on `risoPaper2` with the dense keyline
          // (`RisoMemberRuleRowView`). `.undo` is the member-row control.
          className={styles.partUndo}
          onClick={() => onSetPartExcluded(childId, false)}
          aria-label={`Undo excluding ${name}`}
        >
          UNDO
        </button>
      </div>
    );
  }

  return (
    <>
      <div className={styles.partLine}>
        <span className={styles.partName}>{name}</span>
        {isCounting && fromBoard && (
          <>
            <CounterStepper
              size="compact"
              value={target}
              min={1}
              max={goal}
              onChange={(next) => onSetPartTarget(childId, next)}
            />
            <span className={styles.caption}>of {goal}</span>
          </>
        )}
        {isCounting && split && (
          <DiceButton level={level} onCycle={() => onSetPartVary(childId, nextVary(level))} />
        )}
        {split && canExclude && (
          <button
            type="button"
            className={styles.partExclude}
            onClick={() => onSetPartExcluded(childId, true)}
            aria-label={`Exclude ${name} for this board`}
          >
            ✕
          </button>
        )}
      </div>
      {range !== null && <p className={styles.rangeLine}>{range}</p>}
    </>
  );
}
