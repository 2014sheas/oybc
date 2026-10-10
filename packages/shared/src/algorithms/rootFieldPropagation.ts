import { TaskType } from '../constants/enums';
import type { Task } from '../types/task';
import { planCountKindSwitch, resolveCountKind, type CountKind } from './countValue';
import { isFrozenDerivedRow } from './memberRules';
import { renderCounterTitle } from './counterSettings';
import { isAutoCounterTitle, type CounterTitleSettings } from './taskTitle';

/**
 * rootFieldPropagation.ts — a counter ROOT's Task Detail edit reaching its
 * live per-board copies (docs/BOARD_SCOPED_TASK_EDITS.md §6, PR 3). Swift
 * twin: `Helpers/RootFieldPropagation.swift`; pinned by
 * `rootFieldPropagationVectors.json`.
 *
 * Title / action / unit propagate, and an edit of the root's NAME or title
 * TEMPLATES (docs/SHARED_COUNTER_SETTINGS.md §1) re-renders every live copy
 * whose title is auto (custom titles kept); the goal never does (each board scales
 * its own target) and the kind is written by the kind switch
 * (`countKindSwitch.ts`), which this planner only reads so an auto copy
 * title tracks the copy's switch-rounded goal. `description` is not
 * propagated: per-board counting copies are minted without one.
 */

/** The root as stored BEFORE the edit. */
export type RootPropagationRoot = Pick<
  Task,
  | 'id'
  | 'type'
  | 'title'
  | 'action'
  | 'unit'
  | 'maxCount'
  | 'countKind'
  | 'sharedCounterId'
  | 'counterName'
  | 'titleTemplateSingular'
  | 'titleTemplatePlural'
>;

/** The root's edit. An absent key is unchanged. */
export interface RootFieldEditPatch {
  title?: string;
  action?: string;
  unit?: string;
  /** The root's new goal — decides whether its new title is auto; never propagated. */
  maxCount?: number | null;
  /** The root's requested kind (applied by the kind switch, read here). */
  countKind?: CountKind;
  /** The root's new name; `null` clears it back to the derived default. */
  counterName?: string | null;
  /** The root's new singular template; `null` clears it to the default. */
  titleTemplateSingular?: string | null;
  /** The root's new plural template; `null` clears it to the default. */
  titleTemplatePlural?: string | null;
}

/**
 * The root's name + templates after `patch` (absent key = unchanged, `null` = cleared).
 *
 * @param root - The root before the edit.
 * @param patch - The root's edit.
 * @returns The post-edit settings.
 */
function settingsAfterPatch(root: RootPropagationRoot, patch: RootFieldEditPatch): CounterTitleSettings {
  const pick = (k: keyof CounterTitleSettings): string | undefined =>
    patch[k] === undefined ? (root[k] ?? undefined) : (patch[k] ?? undefined);
  return {
    counterName: pick('counterName'),
    titleTemplateSingular: pick('titleTemplateSingular'),
    titleTemplatePlural: pick('titleTemplatePlural'),
  };
}

/**
 * Whether two settings differ (each compared trimmed; blank = absent).
 *
 * @param a - Settings.
 * @param b - Settings.
 */
function settingsDiffer(a: CounterTitleSettings, b: CounterTitleSettings): boolean {
  const norm = (v: string | null | undefined): string => (v ?? '').trim();
  return (['counterName', 'titleTemplateSingular', 'titleTemplatePlural'] as const).some(
    (k) => norm(a[k]) !== norm(b[k]),
  );
}

/** A candidate copy (any row read by `sharedCounterId == root.id`), as stored BEFORE the edit. */
export type RootPropagationCopy = Pick<
  Task,
  | 'id'
  | 'type'
  | 'title'
  | 'action'
  | 'unit'
  | 'maxCount'
  | 'countKind'
  | 'sharedCounterId'
  | 'startDate'
  | 'endDate'
  | 'createdInWizard'
  | 'isDeleted'
> & {
  /** Placed on a sealed (closed) board — a permanent record, never rewritten. */
  onSealedBoard?: boolean;
};

/** The fields a copy write carries — only those that differ from the copy. */
export interface RootFieldPropagationPatch {
  title?: string;
  action?: string;
  unit?: string;
}

/** One planned copy write. */
export interface RootFieldPropagationEntry {
  copyId: string;
  patch: RootFieldPropagationPatch;
}

/**
 * Plan the copy writes a root edit implies.
 *
 * Rules (each copy judged on its own pre-edit fields):
 * - Only a live COUNTING row linked to this root (`sharedCounterId == root.id`,
 *   not deleted, not frozen by `isFrozenDerivedRow`, not on a sealed board)
 *   is a candidate; a root that is itself linked plans nothing.
 * - action / unit: a changed root value is copied verbatim.
 * - title: when the root's NEW title is custom and changed, every live copy
 *   carries it verbatim (the #542 mint rule — a fresh copy would carry it).
 *   Otherwise an AUTO copy title (auto against the root's PRE-edit templates,
 *   or the legacy formula) is re-rendered through the root's POST-edit
 *   templates from the copy's action / unit / own (switch-rounded) goal /
 *   kind, and a CUSTOM copy title is kept. A name / template edit alone
 *   triggers that re-render.
 * - The goal is never in a patch.
 *
 * @param root - The root before the edit.
 * @param patch - The root's edit.
 * @param copies - Candidate copies before the edit.
 * @param now - ISO8601 freeze clock.
 * @returns One entry per copy that changes, sorted by copy id.
 */
export function planRootFieldPropagation(
  root: RootPropagationRoot,
  patch: RootFieldEditPatch,
  copies: readonly RootPropagationCopy[],
  now: string,
): RootFieldPropagationEntry[] {
  if (root.type !== TaskType.COUNTING || root.sharedCounterId != null) return [];

  const rootKind = resolveCountKind(root);
  const rootKindPatch =
    patch.countKind !== undefined ? planCountKindSwitch(root, rootKind, patch.countKind) : null;
  const kindAfter = rootKindPatch && patch.countKind !== undefined ? patch.countKind : rootKind;
  const actionBefore = root.action ?? '';
  const unitBefore = root.unit ?? '';
  const titleAfter = (patch.title ?? root.title).trim();
  const actionAfter = patch.action ?? actionBefore;
  const unitAfter = patch.unit ?? unitBefore;
  const goalAfter =
    patch.maxCount !== undefined ? patch.maxCount : (rootKindPatch?.maxCount ?? root.maxCount);

  const titleChanged = titleAfter !== root.title.trim();
  const actionChanged = actionAfter !== actionBefore;
  const unitChanged = unitAfter !== unitBefore;
  const kindChanged = kindAfter !== rootKind;
  const settingsBefore: CounterTitleSettings = {
    counterName: root.counterName,
    titleTemplateSingular: root.titleTemplateSingular,
    titleTemplatePlural: root.titleTemplatePlural,
  };
  const settingsAfter = settingsAfterPatch(root, patch);
  const settingsChanged = settingsDiffer(settingsBefore, settingsAfter);
  if (!titleChanged && !actionChanged && !unitChanged && !kindChanged && !settingsChanged) return [];

  const carryRootTitle =
    titleChanged &&
    !isAutoCounterTitle(titleAfter, actionAfter, goalAfter, unitAfter, kindAfter, settingsAfter);

  const out: RootFieldPropagationEntry[] = [];
  for (const copy of copies) {
    if (!isLiveCopy(copy, root.id, now)) continue;
    const entry = planCopy(copy, {
      kindChanged, kindAfter, actionChanged, actionAfter, unitChanged, unitAfter,
      carriedTitle: carryRootTitle ? titleAfter : null,
      settingsBefore, settingsAfter,
    });
    if (entry) out.push(entry);
  }
  return out.sort((a, b) => (a.copyId < b.copyId ? -1 : a.copyId > b.copyId ? 1 : 0));
}

/** The root-level outcome {@link planCopy} applies to one copy. */
interface RootOutcome {
  kindChanged: boolean;
  kindAfter: CountKind;
  actionChanged: boolean;
  actionAfter: string;
  unitChanged: boolean;
  unitAfter: string;
  /** The root's new custom title every copy carries, or null. */
  carriedTitle: string | null;
  /** The root's name + templates before the edit (judge a copy's title auto against these). */
  settingsBefore: CounterTitleSettings;
  /** The root's name + templates after the edit (re-render an auto copy title through these). */
  settingsAfter: CounterTitleSettings;
}

/**
 * Whether `copy` is a live copy of `rootId` that a root edit may write.
 *
 * @param copy - The candidate.
 * @param rootId - The root's id.
 * @param now - ISO8601 freeze clock.
 * @returns True when the copy is live.
 */
function isLiveCopy(copy: RootPropagationCopy, rootId: string, now: string): boolean {
  return (
    copy.type === TaskType.COUNTING &&
    copy.sharedCounterId === rootId &&
    !copy.isDeleted &&
    copy.onSealedBoard !== true &&
    !isFrozenDerivedRow(copy, now)
  );
}

/**
 * One copy's patch under the root outcome, or null when nothing changes.
 *
 * @param copy - The live copy.
 * @param root - The root-level outcome.
 * @returns The entry, or null.
 */
function planCopy(copy: RootPropagationCopy, root: RootOutcome): RootFieldPropagationEntry | null {
  const actionBefore = copy.action ?? '';
  const unitBefore = copy.unit ?? '';
  const kindBefore = resolveCountKind(copy);
  const action = root.actionChanged ? root.actionAfter : actionBefore;
  const unit = root.unitChanged ? root.unitAfter : unitBefore;

  let title: string;
  if (root.carriedTitle !== null) {
    title = root.carriedTitle;
  } else if (isAutoCounterTitle(copy.title, actionBefore, copy.maxCount, unitBefore, kindBefore, root.settingsBefore)) {
    // The kind switch rounds the copy's goal; an auto title follows it.
    const switched = root.kindChanged ? planCountKindSwitch(copy, kindBefore, root.kindAfter) : null;
    const kind = switched ? root.kindAfter : kindBefore;
    const goal = switched?.maxCount ?? copy.maxCount;
    title = renderCounterTitle({ ...root.settingsAfter, action, unit, countKind: kind }, goal);
  } else {
    title = copy.title;
  }

  const patch: RootFieldPropagationPatch = {};
  if (title !== copy.title) patch.title = title;
  if (action !== actionBefore) patch.action = action;
  if (unit !== unitBefore) patch.unit = unit;
  return Object.keys(patch).length > 0 ? { copyId: copy.id, patch } : null;
}
