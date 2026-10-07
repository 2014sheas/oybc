import {
  boardSheetChips, formatCount, formatCountForInput, formatCountWithUnit, initialLogSelection, parseCountInput,
  quantizeCount, resolveFamilyCountKind, type CountKind, type Task,
} from '@oybc/shared';
import type { QuickAmountProps } from '../interactiveTaskSquareUtils';

/**
 * The open DetailModal's log-amount state (docs/COUNTER_KINDS.md §5). iOS
 * twin: `CountingStepperModel.swift`.
 */
export interface CountingLogState {
  boardTaskId: string;
  /** The chosen chip / confirmed custom amount (Discrete shared). */
  amount: number;
  /** The amount is an explicit custom entry — persisted as the default on log. */
  isCustom: boolean;
  /** Discrete shared: the custom-amount row is open. */
  customOpen: boolean;
  /** Discrete shared: the custom-amount row's text. */
  customDraft: string;
  /** Continuous / Duration: the always-open amount field's text. */
  amountText: string;
}

/** Everything the model needs from the board for one counting square. */
export interface CountingLogContext {
  boardTaskId: string;
  task: Task;
  taskMap: Record<string, Task>;
  /** The shared counter's source task id, or null for a standalone square. */
  sourceId: string | null;
  /** The square's windowed count. */
  currentCount: number;
  isSealed: boolean;
  onIncrementShared(sourceId: string, amount: number, persist: boolean): void;
  onDecrementShared(sourceId: string, amount: number, persist: boolean): void;
  onSetStandaloneCount(boardTaskId: string, next: number): void;
  onPersistDefault(taskId: string, amount: number): void;
}

const kindOf = (ctx: CountingLogContext): CountKind => resolveFamilyCountKind(ctx.task, (id) => ctx.taskMap[id]);

/**
 * The state a square's modal opens with, or null for the plain Discrete
 * stepper (a standalone Discrete square).
 *
 * @param ctx - The square.
 * @returns The opening state, or null.
 */
export function initialCountingLogState(ctx: CountingLogContext): CountingLogState | null {
  const kind = kindOf(ctx);
  if (kind === 'discrete' && !ctx.sourceId) return null;
  const options = boardSheetChips(kind, ctx.task.maxCount ?? 0);
  const remembered = (ctx.sourceId ? ctx.taskMap[ctx.sourceId] : ctx.task)?.defaultLogAmount;
  const sel = initialLogSelection(kind, options, remembered);
  return {
    boardTaskId: ctx.boardTaskId, amount: sel.amount, isCustom: sel.isCustom,
    customOpen: false, customDraft: '', amountText: formatCountForInput(sel.amount, kind),
  };
}

/**
 * The DetailModal's quick-amount props for the current state. − and + apply
 * the field's amount (Continuous / Duration) or the chosen chip (Discrete
 * shared); only an explicit custom amount persists as the new default.
 *
 * @param state - The current state.
 * @param ctx - The square.
 * @param setState - Replaces the state.
 * @returns The props, or undefined for the plain Discrete stepper.
 */
export function buildQuickAmount(
  state: CountingLogState,
  ctx: CountingLogContext,
  setState: (next: CountingLogState) => void,
): QuickAmountProps | undefined {
  const kind = kindOf(ctx);
  if (kind === 'discrete' && !ctx.sourceId) return undefined;
  const options = boardSheetChips(kind, ctx.task.maxCount ?? 0);
  const unit = ctx.task.unit ?? '';
  const entry = kind !== 'discrete';
  const selected = entry ? parseCountInput(state.amountText, kind) : state.amount;
  const isLinked = ctx.task.sharedCounterId != null;
  const log = (direction: 1 | -1): void => {
    if (ctx.isSealed || selected === null) return;
    const persist = state.isCustom;
    if (ctx.sourceId) {
      if (direction === 1) ctx.onIncrementShared(ctx.sourceId, selected, persist);
      else ctx.onDecrementShared(ctx.sourceId, selected, persist);
      return;
    }
    ctx.onSetStandaloneCount(ctx.boardTaskId, Math.max(0, quantizeCount(ctx.currentCount + direction * selected)));
    if (persist) ctx.onPersistDefault(ctx.task.id, selected);
  };
  return {
    kind, options, selected, unit,
    isCustomActive: state.isCustom,
    customOpen: state.customOpen,
    customDraft: state.customDraft,
    amountText: state.amountText,
    busy: ctx.isSealed,
    removeDisabled: isLinked || ctx.currentCount <= 0 || selected === null,
    // An invalid field reads a plain "+" (iOS `addLabel(unit:)`), never "+ 0 mi".
    addLabel: selected === null ? '+' : `+ ${entry ? formatCountWithUnit(selected, kind, unit) : formatCount(selected, kind)}`,
    onSelectChip: (v) => setState({ ...state, amount: v, isCustom: false, customOpen: false, amountText: formatCountForInput(v, kind) }),
    // `#` alone clears the field for a typed amount; it becomes custom (and
    // persists on log) only once the user edits the field.
    onOpenCustom: () => setState(entry
      ? { ...state, amountText: '', isCustom: false }
      : { ...state, customOpen: true, customDraft: state.isCustom ? formatCountForInput(state.amount, kind) : '' }),
    onCustomDraftChange: (raw) => setState({ ...state, customDraft: raw }),
    onConfirmCustom: () => {
      const parsed = parseCountInput(state.customDraft, kind);
      if (parsed !== null) setState({ ...state, amount: parsed, isCustom: true, customOpen: false, customDraft: '' });
    },
    onAmountTextChange: (raw) => {
      const parsed = parseCountInput(raw, kind);
      setState({ ...state, amountText: raw, isCustom: parsed === null || !options.some((o) => o.value === parsed) });
    },
    onAdd: () => log(1),
    onRemove: () => { if (!isLinked) log(-1); },
  };
}
