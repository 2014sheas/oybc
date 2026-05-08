import { useMemo, useState } from 'react';
import {
  CenterSquareType,
  Timeframe,
  type BoardSize,
  type RecurringBoardTemplate,
  type Task,
  type PoolStrategy,
  type CenterSquareType as CenterSquareTypeT,
} from '@oybc/shared';
import {
  createRecurringBoardTemplate,
  updateRecurringBoardTemplate,
} from '../../db/operations/recurringBoardTemplates';
import { TypeBadge } from '../TypeBadge';
import styles from './RecurringTemplateForm.module.css';

/**
 * RecurringTemplateForm — modal form to create or edit a
 * `RecurringBoardTemplate` (Phase 6.2).
 *
 * Supports two modes:
 * - Create: `template` is undefined; submit creates a new row via
 *   `createRecurringBoardTemplate`.
 * - Edit: `template` is set; submit updates via
 *   `updateRecurringBoardTemplate`. `lastSpawnedWindowKey` is NOT touched
 *   so the template won't re-spawn the current window after a non-pool
 *   edit.
 *
 * Validation: field-level synchronous checks gate the Save button
 * (disabled if any check fails). The DB operations
 * (`createRecurringBoardTemplate` / `updateRecurringBoardTemplate`)
 * trust their typed input — they don't run Zod themselves. The
 * schema-level checks in `CreateRecurringBoardTemplateInputSchema` /
 * `UpdateRecurringBoardTemplateInputSchema` are reused by the sync
 * pull path (`applyRemoteSubdoc`) for defense-in-depth against
 * malformed Firestore payloads, but local form input is gated only
 * by this component.
 *
 * MVP scope (locked): supports FREE / CUSTOM_FREE / NONE only — CHOSEN
 * is excluded (the Zod schema would reject it anyway).
 */

const TIMEFRAMES: { value: Timeframe; label: string }[] = [
  { value: Timeframe.DAILY, label: 'Daily' },
  { value: Timeframe.WEEKLY, label: 'Weekly' },
  { value: Timeframe.MONTHLY, label: 'Monthly' },
  { value: Timeframe.YEARLY, label: 'Yearly' },
];

const BOARD_SIZES: { value: BoardSize; label: string }[] = [
  { value: 3, label: '3 × 3' },
  { value: 4, label: '4 × 4' },
  { value: 5, label: '5 × 5' },
];

const CENTER_TYPES: { value: CenterSquareTypeT; label: string; hint: string }[] = [
  { value: CenterSquareType.FREE, label: 'Free space', hint: 'Auto-completed center cell' },
  { value: CenterSquareType.CUSTOM_FREE, label: 'Custom free space', hint: 'Auto-completed with your custom label' },
  { value: CenterSquareType.NONE, label: 'No special center', hint: 'Center cell behaves like the others' },
];

const POOL_STRATEGIES: { value: PoolStrategy; label: string; hint: string }[] = [
  { value: 'all', label: 'Use every task', hint: 'Pool size must exactly match the cells to fill' },
  { value: 'random_subset', label: 'Random subset', hint: 'Pool can be larger; spawn picks N each window' },
];

export interface RecurringTemplateFormProps {
  userId: string;
  /** Library tasks the user can pick from. */
  libraryTasks: Task[];
  /** Pass when editing; omit when creating. */
  template?: RecurringBoardTemplate;
  onClose: () => void;
}

/** Compute fillable cells (boardSize² minus the auto-completed center). */
function fillableCellCount(
  boardSize: BoardSize,
  centerSquareType: CenterSquareTypeT,
): number {
  const total = boardSize * boardSize;
  const hasCenter = boardSize % 2 === 1;
  const centerOmitsTask =
    hasCenter &&
    (centerSquareType === CenterSquareType.FREE ||
      centerSquareType === CenterSquareType.CUSTOM_FREE);
  return total - (centerOmitsTask ? 1 : 0);
}

export function RecurringTemplateForm({
  userId,
  libraryTasks,
  template,
  onClose,
}: RecurringTemplateFormProps): React.ReactElement {
  const isEdit = template !== undefined;
  const [name, setName] = useState(template?.name ?? '');
  const [timeframe, setTimeframe] = useState<Timeframe>(
    template?.timeframe ?? Timeframe.DAILY,
  );
  const [boardSize, setBoardSize] = useState<BoardSize>(
    template?.boardSize ?? 5,
  );
  const [centerSquareType, setCenterSquareType] = useState<CenterSquareTypeT>(
    (template?.centerSquareType as CenterSquareTypeT | undefined) ??
      CenterSquareType.FREE,
  );
  const [centerSquareCustomName, setCenterSquareCustomName] = useState(
    template?.centerSquareCustomName ?? '',
  );
  const [poolStrategy, setPoolStrategy] = useState<PoolStrategy>(
    template?.poolStrategy ?? 'all',
  );
  const [isRandomized, setIsRandomized] = useState(template?.isRandomized ?? true);
  const [isActive, setIsActive] = useState(template?.isActive ?? true);
  const [seedTaskIds, setSeedTaskIds] = useState<string[]>(
    template?.seedTaskIds ?? [],
  );
  const [searchQuery, setSearchQuery] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  const fillableCells = useMemo(
    () => fillableCellCount(boardSize, centerSquareType),
    [boardSize, centerSquareType],
  );

  const filteredLibraryTasks = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    if (!q) return libraryTasks;
    return libraryTasks.filter((t) => t.title.toLowerCase().includes(q));
  }, [libraryTasks, searchQuery]);

  const trimmedName = name.trim();
  const isCustomFree = centerSquareType === CenterSquareType.CUSTOM_FREE;
  const customNameOk =
    !isCustomFree || centerSquareCustomName.trim().length > 0;

  const poolSizeOk =
    poolStrategy === 'all'
      ? seedTaskIds.length === fillableCells
      : seedTaskIds.length >= fillableCells;

  const formValid =
    trimmedName.length > 0 &&
    trimmedName.length <= 120 &&
    seedTaskIds.length > 0 &&
    customNameOk &&
    poolSizeOk &&
    !submitting;

  const togglePoolMember = (taskId: string) => {
    setSeedTaskIds((prev) =>
      prev.includes(taskId) ? prev.filter((id) => id !== taskId) : [...prev, taskId],
    );
  };

  const handleSubmit = async () => {
    if (!formValid) return;
    setSubmitting(true);
    setSubmitError(null);
    try {
      if (isEdit && template) {
        await updateRecurringBoardTemplate(template.id, {
          name: trimmedName,
          timeframe,
          boardSize,
          centerSquareType,
          centerSquareCustomName: isCustomFree
            ? centerSquareCustomName.trim()
            : undefined,
          isRandomized,
          seedTaskIds,
          poolStrategy,
          isActive,
        });
      } else {
        await createRecurringBoardTemplate(userId, {
          name: trimmedName,
          timeframe,
          boardSize,
          centerSquareType,
          centerSquareCustomName: isCustomFree
            ? centerSquareCustomName.trim()
            : undefined,
          isRandomized,
          seedTaskIds,
          poolStrategy,
          isActive,
        });
      }
      onClose();
    } catch (err) {
      console.error('[recurring-template] save failed', err);
      setSubmitError(err instanceof Error ? err.message : 'Failed to save template');
      setSubmitting(false);
    }
  };

  return (
    <div className={styles.overlay} role="dialog" aria-modal="true">
      <div className={styles.sheet}>
        <header className={styles.header}>
          <h2 className={styles.title}>
            {isEdit ? 'Edit recurring template' : 'New recurring template'}
          </h2>
          <button
            type="button"
            className={styles.closeButton}
            onClick={onClose}
            aria-label="Close"
          >
            ×
          </button>
        </header>

        <div className={styles.body}>
          {/* Name */}
          <label className={styles.field}>
            <span className={styles.fieldLabel}>Template name</span>
            <input
              className={styles.input}
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              maxLength={120}
              placeholder="e.g., Daily Workout"
            />
          </label>

          {/* Timeframe */}
          <fieldset className={styles.field}>
            <legend className={styles.fieldLabel}>Timeframe</legend>
            <div className={styles.chipRow}>
              {TIMEFRAMES.map((t) => (
                <button
                  key={t.value}
                  type="button"
                  className={`${styles.chip} ${timeframe === t.value ? styles.chipActive : ''}`}
                  onClick={() => setTimeframe(t.value)}
                  aria-pressed={timeframe === t.value}
                >
                  {t.label}
                </button>
              ))}
            </div>
          </fieldset>

          {/* Board size */}
          <fieldset className={styles.field}>
            <legend className={styles.fieldLabel}>Board size</legend>
            <div className={styles.chipRow}>
              {BOARD_SIZES.map((s) => (
                <button
                  key={s.value}
                  type="button"
                  className={`${styles.chip} ${boardSize === s.value ? styles.chipActive : ''}`}
                  onClick={() => setBoardSize(s.value)}
                  aria-pressed={boardSize === s.value}
                >
                  {s.label}
                </button>
              ))}
            </div>
          </fieldset>

          {/* Center type */}
          <fieldset className={styles.field}>
            <legend className={styles.fieldLabel}>Center cell</legend>
            <div className={styles.optionList}>
              {CENTER_TYPES.map((c) => (
                <label
                  key={c.value}
                  className={`${styles.optionRow} ${centerSquareType === c.value ? styles.optionRowActive : ''}`}
                >
                  <input
                    type="radio"
                    name="centerSquareType"
                    checked={centerSquareType === c.value}
                    onChange={() => setCenterSquareType(c.value)}
                  />
                  <span className={styles.optionMain}>
                    <span className={styles.optionLabel}>{c.label}</span>
                    <span className={styles.optionHint}>{c.hint}</span>
                  </span>
                </label>
              ))}
            </div>
            {isCustomFree && (
              <input
                className={styles.input}
                type="text"
                value={centerSquareCustomName}
                onChange={(e) => setCenterSquareCustomName(e.target.value)}
                maxLength={100}
                placeholder="Center cell label (e.g., 'Win!')"
              />
            )}
          </fieldset>

          {/* Pool strategy */}
          <fieldset className={styles.field}>
            <legend className={styles.fieldLabel}>Pool strategy</legend>
            <div className={styles.optionList}>
              {POOL_STRATEGIES.map((p) => (
                <label
                  key={p.value}
                  className={`${styles.optionRow} ${poolStrategy === p.value ? styles.optionRowActive : ''}`}
                >
                  <input
                    type="radio"
                    name="poolStrategy"
                    checked={poolStrategy === p.value}
                    onChange={() => setPoolStrategy(p.value)}
                  />
                  <span className={styles.optionMain}>
                    <span className={styles.optionLabel}>{p.label}</span>
                    <span className={styles.optionHint}>{p.hint}</span>
                  </span>
                </label>
              ))}
            </div>
          </fieldset>

          {/* Toggles */}
          <div className={styles.toggleRow}>
            <label className={styles.toggleField}>
              <input
                type="checkbox"
                checked={isRandomized}
                onChange={(e) => setIsRandomized(e.target.checked)}
              />
              <span>Randomize task placement on each spawn</span>
            </label>
            <label className={styles.toggleField}>
              <input
                type="checkbox"
                checked={isActive}
                onChange={(e) => setIsActive(e.target.checked)}
              />
              <span>Active (spawn boards on rollover)</span>
            </label>
          </div>

          {/* Pool picker */}
          <fieldset className={styles.field}>
            <legend className={styles.fieldLabel}>
              Task pool
              <span className={styles.poolMeta}>
                {' '}
                — {seedTaskIds.length} selected /{' '}
                {poolStrategy === 'all'
                  ? `${fillableCells} required`
                  : `${fillableCells} minimum`}
              </span>
            </legend>
            <input
              className={styles.input}
              type="search"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder="Search your library..."
            />
            <div className={styles.poolList}>
              {filteredLibraryTasks.length === 0 ? (
                <p className={styles.poolEmpty}>
                  {libraryTasks.length === 0
                    ? 'Your library is empty. Add tasks first, then come back to build a template.'
                    : 'No tasks match your search.'}
                </p>
              ) : (
                filteredLibraryTasks.map((t) => {
                  const checked = seedTaskIds.includes(t.id);
                  return (
                    <label
                      key={t.id}
                      className={`${styles.poolItem} ${checked ? styles.poolItemChecked : ''}`}
                    >
                      <input
                        type="checkbox"
                        checked={checked}
                        onChange={() => togglePoolMember(t.id)}
                      />
                      <span className={styles.poolItemTitle}>{t.title}</span>
                      <TypeBadge type={t.type} size="small" />
                    </label>
                  );
                })
              )}
            </div>
          </fieldset>

          {!poolSizeOk && (
            <p className={styles.validationMsg}>
              {poolStrategy === 'all'
                ? `Select exactly ${fillableCells} tasks (currently ${seedTaskIds.length}).`
                : `Select at least ${fillableCells} tasks (currently ${seedTaskIds.length}).`}
            </p>
          )}
          {!customNameOk && (
            <p className={styles.validationMsg}>
              Custom free spaces need a label.
            </p>
          )}
          {submitError && <p className={styles.validationMsg}>{submitError}</p>}
        </div>

        <footer className={styles.footer}>
          <button
            type="button"
            className={styles.cancelButton}
            onClick={onClose}
          >
            Cancel
          </button>
          <button
            type="button"
            className={styles.saveButton}
            onClick={() => void handleSubmit()}
            disabled={!formValid}
          >
            {submitting ? 'Saving...' : isEdit ? 'Save changes' : 'Create template'}
          </button>
        </footer>
      </div>
    </div>
  );
}
