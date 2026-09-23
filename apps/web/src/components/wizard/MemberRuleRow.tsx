import { useEffect, useState } from 'react';
import {
  TaskType,
  compoundSummary,
  countingSummary,
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
 * per-member rule controls (docs/BOARD_SOURCES.md §Member rules + §Member
 * row at phone width; handoff "Expanded source panel" item 3).
 *
 * **B3.1: disclosure, not compression.** At 393pt the B3 row's inline
 * furniture (badge + stepper + caption + dice + ✕) left the title ~102pt
 * and ellipsised real ones. A row that HAS rule controls now opens
 * collapsed — `badge · title · summary chip · chevron · ✕`, ~194pt of
 * title — and reveals them on a second line at the 69pt indent:
 *
 * - **Counting** — a compact target stepper carrying the goal as a suffix
 *   INSIDE its pill (board sources only; a pool member has no window to
 *   pro-rate against, so it gets the dice alone), the dice, then the blue
 *   range INLINE beside them rather than on a third line.
 * - **Compound with parts** — the One square / Split up pill plus the
 *   "N squares" note (dice on that line only while One square), then one
 *   line per part: name · stepper · "of {goal}" · dice and ✕ while split.
 *   A part's range line still sits under that part's own line.
 * - **Anything else** (normal, achievement, childless compound) and every
 *   excluded or filtered-done member — the pre-B3.1 single line with its
 *   inline trailing control and NO disclosure: there is nothing to reveal,
 *   and the excluded state's ~60px UNDO pill does not fit the 28px gutter
 *   the overlaid ✕ uses (ruling C2).
 *
 * The collapsed chip is the row's current answer, never a second control,
 * and it comes from the shared `countingSummary` / `compoundSummary` — so
 * it can never disagree with the expanded row's own range line. A counting
 * chip that would merely restate an auto-generated title (vary off AND
 * target === goal) is suppressed entirely; `countingSummary` returns null
 * and the row renders no chip element at all.
 *
 * Owns the whole `<li>` (not just the rule strip) so `SourceRow` stays a
 * header + range-block renderer. iOS twin: `RisoMemberRuleRowView` (which
 * keeps the same decisions in a `MemberRuleRowModel` struct — web has no
 * twin struct, a pre-existing asymmetry).
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
   * avoid. Since B3.1 this is the single gate: it decides `isExpandable`,
   * and everything that was individually gated on it now lives behind the
   * disclosure.
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
  const partIds = parts.map((p) => p.childTaskId);
  const excludedPartIds = new Set(
    partIds.filter((id) => partRuleFor(rule, id).excluded === true),
  );

  /**
   * Does this row HAVE controls worth hiding? Exactly the rows that render
   * something on the second line — the same `isOn` gate every control
   * already carries, so an excluded member can never become expandable.
   */
  const isExpandable = isOn && (isCounting || isCompound);
  /** What the collapsed row says in place of its controls (null = say nothing). */
  const summary = !isExpandable
    ? null
    : isCompound
      ? compoundSummary(split, partIds, excludedPartIds, memberVary)
      : countingSummary(target, memberVary, goal, unit);

  const [isExpanded, setIsExpanded] = useState(false);
  // "Always collapsed on open" is a rule about the row's whole lifecycle,
  // not just its first render: a row that was open when it was excluded
  // must not spring back open on UNDO (iOS twin: the `onChange(of: state)`
  // reset in `RisoMemberRuleRowView`).
  useEffect(() => {
    if (state !== 'included') setIsExpanded(false);
  }, [state]);

  /**
   * The row's trailing control — ✕ while included, UNDO while excluded, a
   * dimmed ✓ while filtered out as done. Built once and placed twice: an
   * expandable row overlays it on its main line (so the disclosure keeps
   * the whole row rect), a non-expandable one renders it inline.
   */
  const trailingControl = (
    <>
      {state === 'included' && (
        <button
          type="button"
          className={`${styles.exclude} ${isExpandable ? styles.excludeOverlay : ''}`}
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
    </>
  );

  /**
   * The row's first line. Shared by both branches below so the collapsed
   * and expandable shapes can never drift apart; the trailing control is
   * inline here ONLY when the row is not expandable (ruling C2) — an
   * expandable row overlays it instead, so the whole line stays tappable.
   */
  const mainLineContent = (
    <>
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
      {summary !== null && !isExpanded && (
        <span className={`${styles.chip} ${summary.varying ? styles.chipVarying : ''}`}>
          {summary.text}
        </span>
      )}
      {isExpandable ? (
        <span
          className={`${styles.chevron} ${isExpanded ? styles.chevronOpen : ''}`}
          aria-hidden="true"
        >
          &rsaquo;
        </span>
      ) : (
        trailingControl
      )}
    </>
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
      {isExpandable ? (
        // `.mainLine` is the positioning context for the overlaid control,
        // so the control centres on THIS line — which grows to two lines on
        // a counter-clash row — and not on the row including its expanded
        // block.
        <div className={styles.mainLine}>
          <button
            type="button"
            className={styles.disclosure}
            data-testid="member-disclosure"
            aria-expanded={isExpanded}
            onClick={() => setIsExpanded((open) => !open)}
          >
            {mainLineContent}
          </button>
          {/* A SIBLING of the disclosure, never nested inside it — a button
              inside a button is invalid and swallows the inner click. */}
          {trailingControl}
        </div>
      ) : (
        // Paired with `member-disclosure` on the expandable branch: between
        // them, every member row exposes exactly one inner line element.
        // That is where the 42px uniform-height floor lives — the `<li>`
        // itself also carries the 1.5px hairline (absent on `:first-child`),
        // so measuring the row would compare 42px against 43.5px.
        <div className={styles.staticLine} data-testid="member-static-line">
          {mainLineContent}
        </div>
      )}

      {isExpandable && isExpanded && (
        // One block, one rhythm: 4px between lines, 8px under the whole
        // thing, all of it at the 69px indent — so a compound's last part
        // gets the same breathing room a counting row's controls line does
        // and never crowds the next row's hairline.
        <div className={styles.expanded}>
          <div className={styles.controlsLine}>
            {isCompound ? (
              <>
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
                  {/* One square puts the WHOLE compound on as a single
                      square — `splitSquaresNote` counts included parts,
                      which is the split-mode answer only. */}
                  {split ? splitSquaresNote(partIds, excludedPartIds) : '1 square'}
                </span>
                {!split && (
                  <DiceButton level={memberVary} onCycle={() => onSetVary(nextVary(memberVary))} />
                )}
              </>
            ) : (
              <>
                {fromBoard && (
                  <CounterStepper
                    size="compact"
                    value={target}
                    min={1}
                    max={goal}
                    onChange={(next) => onSetTarget(next)}
                    // The goal rides INSIDE the pill now — B3's separate
                    // "of 35 pages" caption restated what an auto-generated
                    // counting title already says, twice over.
                    suffix={`/ ${goal}${unit ? ` ${unit}` : ''}`}
                  />
                )}
                <DiceButton level={memberVary} onCycle={() => onSetVary(nextVary(memberVary))} />
                {/* Inline, not a third line: an expanded counting row is
                    exactly two lines. */}
                {memberRange !== null && <span className={styles.rangeInline}>{memberRange}</span>}
              </>
            )}
          </div>

          {isCompound &&
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
        </div>
      )}
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
 * split — One square rolls one dice for the whole compound (on the
 * controls line) and contributes one square, so a part has nothing to
 * exclude.
 *
 * Parts stay SINGLE-LINE at the 69px indent (B3.1): ~155px still fits a
 * part name, and splitting these too would make a 3-part compound seven
 * lines. So the part keeps the `of {goal}` caption and the separate range
 * line that the member row itself gave up.
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
    // The part line and its own range line are ONE flex child of
    // `.expanded`, so the range hugs the part it belongs to instead of
    // taking the block's 4px inter-line gap.
    <div className={styles.part}>
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
    </div>
  );
}
