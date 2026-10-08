import { useState } from 'react';
import {
  countUnitSuffix,
  customChipLabel,
  formatCount,
  formatCountForInput,
  formatCountWithUnit,
  hubChips,
  initialLogSelection,
  type CountKind,
} from '@oybc/shared';
import { GoalEntry } from './GoalEntry';
import { parseCustomLogAmount } from './amountChips';
import styles from './CounterDetailLogCard.module.css';

export interface CounterDetailLogCardProps {
  kind: CountKind;
  /** The counter's unit noun (null when it has none). */
  unit: string | null;
  /** The remembered last-used amount — pre-selects a matching chip, else rides on `#`. */
  defaultLogAmount: number | null | undefined;
  /** Lifetime total — "−" is disabled at 0. */
  lifetime: number;
  /** Tasks currently counting this counter. */
  activeCount: number;
  isLogging: boolean;
  /** Logs (or removes) the selected amount. */
  onLog: (direction: 'add' | 'remove', amount: number) => void;
}

/**
 * The Counter Detail Log card (docs/COUNTER_KINDS.md §5): fixed chips per
 * kind (`hubChips`), a decimal / h:m custom row with OK, and −/＋ Add. Seeds
 * its selection once on mount — mount it keyed by counter id. iOS twin:
 * `CounterDetailLogCard`.
 *
 * @returns The card.
 */
export function CounterDetailLogCard(props: CounterDetailLogCardProps): React.ReactElement {
  const { kind, unit, defaultLogAmount, lifetime, activeCount, isLogging, onLog } = props;
  const unitStr = unit ?? '';
  const logTitle = `Log${countUnitSuffix(kind, unitStr)}`;
  const chips = hubChips(kind);
  const [seed] = useState(() => initialLogSelection(kind, chips, defaultLogAmount));
  const [selectedAmount, setSelectedAmount] = useState(seed.amount);
  const [isCustomActive, setIsCustomActive] = useState(seed.isCustom);
  const [customOpen, setCustomOpen] = useState(false);
  const [customDraft, setCustomDraft] = useState('');

  const selectedChipIndex = isCustomActive ? chips.length - 1 : chips.findIndex((c) => c.value === selectedAmount);
  const parsedDraft = parseCustomLogAmount(customDraft, kind);
  const amountWithUnit = formatCountWithUnit(selectedAmount, kind, unitStr);

  function selectChip(value: number): void {
    setSelectedAmount(value);
    setIsCustomActive(false);
    setCustomOpen(false);
  }

  function openCustomInput(): void {
    setCustomDraft(isCustomActive ? formatCountForInput(selectedAmount, kind) : '');
    setCustomOpen(true);
  }

  function confirmCustomInput(): void {
    if (parsedDraft == null) return;
    setSelectedAmount(parsedDraft);
    setIsCustomActive(true);
    setCustomOpen(false);
  }

  return (
    <div className={styles.logCard} aria-label={logTitle}>
      <div className={styles.logHeader}>
        <span className={styles.logTitle}>{logTitle}</span>
        <span className={styles.logSub}>
          counts toward {activeCount} active task{activeCount !== 1 ? 's' : ''}
        </span>
      </div>

      <div className={styles.chipRow} role="group" aria-label="Log amount">
        {chips.map((chip, i) => {
          const selected = i === selectedChipIndex;
          const isCustomChip = chip.value === null;
          const text = isCustomChip && selected
            ? (kind === 'discrete' ? formatCount(selectedAmount, kind) : customChipLabel(selectedAmount, kind))
            : chip.label;
          return (
            <button
              key={isCustomChip ? 'custom' : `${i}-${chip.value}`}
              type="button"
              className={`${styles.chip} ${selected ? styles.chipSelected : ''}`}
              aria-pressed={selected}
              onClick={() => (isCustomChip ? openCustomInput() : selectChip(chip.value as number))}
            >
              {text}
            </button>
          );
        })}
      </div>

      {customOpen && (
        <div className={styles.customInputRow}>
          <div className={styles.customField}>
            <GoalEntry
              kind={kind}
              value={customDraft}
              onChange={setCustomDraft}
              aria-label="Custom amount"
              placeholder="Amount"
              suffix={kind === 'duration' || !unitStr ? undefined : unitStr}
              dense
              autoFocus
              onEnter={confirmCustomInput}
              onEscape={() => setCustomOpen(false)}
            />
          </div>
          <button type="button" className={styles.customConfirm} onClick={confirmCustomInput} disabled={parsedDraft == null}>
            OK
          </button>
        </div>
      )}

      <div className={styles.logActionsRow}>
        <button
          type="button"
          className={styles.minusBtn}
          onClick={() => onLog('remove', selectedAmount)}
          disabled={isLogging || lifetime === 0}
          aria-label={`Remove ${amountWithUnit}`}
        >
          −
        </button>
        <button
          type="button"
          className={styles.addBtn}
          onClick={() => onLog('add', selectedAmount)}
          disabled={isLogging}
          aria-label={`Add ${amountWithUnit}`}
        >
          ＋ Add {kind === 'discrete' ? formatCount(selectedAmount, kind) : amountWithUnit}
        </button>
      </div>
    </div>
  );
}
