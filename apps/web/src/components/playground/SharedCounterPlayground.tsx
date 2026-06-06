/**
 * SharedCounterPlayground — Phase 1 spike (math only).
 *
 * Validates the deriveDisplayedCount() helper + the no-overshoot-clamp
 * invariant end-to-end in an in-memory harness. No DB writes, no real
 * Task rows, no sync. Synthetic fixtures only.
 *
 * See ARCHITECTURE.md § "Shared counters (Issue #84 — Phase 0 design)"
 * for the locked model, derivation rules, and phasing plan.
 *
 * Phase 2 will wire the real UI in CountingTemplatePicker. Phase 3 will
 * extend runBoardCascadeForTask with the derivation sub-pass.
 */

import { useState, useCallback } from 'react';
import { deriveDisplayedCount, generateCounterTaskTitle } from '@oybc/shared';
import { DerivedCounterRow } from '../DerivedCounterRow';
import type { DerivedCounterRowData } from '../DerivedCounterRow';
import styles from './SharedCounterPlayground.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

/** In-memory fixture representing the shared-counter source task. */
interface SourceFixture {
  action: string;
  unit: string;
  maxCount: number;
  currentCount: number;
}

/** Baseline mode choices — mirrors the Phase 2 picker tab design. */
type BaselineMode = 'Inherit' | 'Start from zero';

/** In-memory fixture for one derived task — alias for the row data shape. */
type DerivedFixture = DerivedCounterRowData;

// ─── Default source fixture ───────────────────────────────────────────────────

const DEFAULT_SOURCE: SourceFixture = {
  action: 'Read',
  unit: 'pages',
  maxCount: 500,
  currentCount: 0,
};

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * SharedCounterPlayground — in-memory harness for the Phase 1 spike.
 *
 * Controls:
 *   - Source task: +1 / -1 on currentCount.
 *   - Add derived task: choose baseline mode (Inherit / Start from zero)
 *     and enter a maxCount. Title autofills via generateCounterTaskTitle().
 *   - Each derived row shows live displayed/maxCount and completion badge
 *     via DerivedCounterRow (a real reusable component).
 */
export function SharedCounterPlayground(): React.ReactElement {
  const [source, setSource] = useState<SourceFixture>(DEFAULT_SOURCE);
  const [derived, setDerived] = useState<DerivedFixture[]>([]);

  // Form state for "Add derived task"
  const [addMode, setAddMode] = useState<BaselineMode>('Inherit');
  const [addMaxCount, setAddMaxCount] = useState<string>('');
  const [addMaxCountError, setAddMaxCountError] = useState<string>('');

  // ── Source controls ────────────────────────────────────────────────────────

  const incrementSource = useCallback(() => {
    setSource((s) => ({ ...s, currentCount: s.currentCount + 1 }));
  }, []);

  const decrementSource = useCallback(() => {
    setSource((s) => ({ ...s, currentCount: Math.max(0, s.currentCount - 1) }));
  }, []);

  // ── Add derived task ───────────────────────────────────────────────────────

  const handleAddDerived = useCallback(() => {
    const parsed = parseInt(addMaxCount, 10);
    if (isNaN(parsed) || parsed < 1) {
      setAddMaxCountError('Enter a positive integer target count.');
      return;
    }
    setAddMaxCountError('');

    // Decision 6: "Inherit" → baseline 0; "Start from zero" → baseline = source.currentCount at add-time.
    const baseline = addMode === 'Start from zero' ? source.currentCount : 0;

    // Decision 2 (title): autofill from generateCounterTaskTitle() using source action/unit + the derived maxCount.
    const title = generateCounterTaskTitle(source.action, parsed, source.unit);

    const newDerived: DerivedFixture = {
      id: `derived-${Date.now()}`,
      title,
      maxCount: parsed,
      baseline,
      baselineMode: addMode,
    };

    setDerived((prev) => [...prev, newDerived]);
    setAddMaxCount('');
  }, [addMode, addMaxCount, source]);

  const handleRemoveDerived = useCallback((id: string) => {
    setDerived((prev) => prev.filter((d) => d.id !== id));
  }, []);

  return (
    <div className={styles.container}>
      {/* ── Header note ── */}
      <div className={styles.note}>
        <strong>Phase 1 spike — math only.</strong> No DB writes. All data is in-memory.
        See <em>ARCHITECTURE.md § Shared counters</em> for the design.
      </div>

      {/* ── Source task panel ── */}
      <section className={styles.section}>
        <h4 className={styles.sectionTitle}>Source task (shared accumulator)</h4>

        <div className={styles.sourceCard}>
          <div className={styles.sourceHeader}>
            <div className={styles.sourceMeta}>
              <span className={styles.sourceLabel}>Action</span>
              <span className={styles.sourceValue}>{source.action}</span>
            </div>
            <div className={styles.sourceMeta}>
              <span className={styles.sourceLabel}>Unit</span>
              <span className={styles.sourceValue}>{source.unit}</span>
            </div>
            <div className={styles.sourceMeta}>
              <span className={styles.sourceLabel}>Target</span>
              <span className={styles.sourceValue}>{source.maxCount}</span>
            </div>
          </div>

          <div className={styles.sourceCountRow}>
            <span className={styles.sourceCountLabel}>currentCount</span>
            <div className={styles.sourceCountControl}>
              <button
                type="button"
                className={styles.countButton}
                onClick={decrementSource}
                disabled={source.currentCount <= 0}
                aria-label="Decrement source count"
              >
                −1
              </button>
              <span className={styles.currentCount} aria-live="polite">
                {source.currentCount}
              </span>
              <button
                type="button"
                className={styles.countButton}
                onClick={incrementSource}
                aria-label="Increment source count"
              >
                +1
              </button>
            </div>
            <span className={styles.sourceProgress}>
              {source.currentCount} / {source.maxCount} (source threshold — informational only)
            </span>
          </div>

          {source.currentCount > source.maxCount && (
            <p className={styles.overshootNote}>
              Source is past its own threshold ({source.currentCount} &gt; {source.maxCount}).
              Derived tasks will show the full overshoot — no high-end clamp.
            </p>
          )}
        </div>
      </section>

      {/* ── Add derived task form ── */}
      <section className={styles.section}>
        <h4 className={styles.sectionTitle}>Add derived task</h4>

        <div className={styles.addForm}>
          {/* Baseline mode picker — mirrors Phase 2's CountingTemplatePicker tab design */}
          <div className={styles.formRow}>
            <label className={styles.formLabel}>Baseline mode</label>
            <div className={styles.modeButtons}>
              {(['Inherit', 'Start from zero'] as BaselineMode[]).map((mode) => (
                <button
                  key={mode}
                  type="button"
                  className={`${styles.modeButton} ${addMode === mode ? styles.modeButtonActive : ''}`}
                  onClick={() => setAddMode(mode)}
                >
                  {mode}
                </button>
              ))}
            </div>
            <p className={styles.modeHint}>
              {addMode === 'Inherit'
                ? 'Derived task counts from 0 — source progress is credited from the start (baseline = 0).'
                : `Derived task counts from the current source value (baseline = ${source.currentCount} at add time).`}
            </p>
          </div>

          {/* maxCount input */}
          <div className={styles.formRow}>
            <label className={styles.formLabel} htmlFor="derived-max-count">
              Target count for derived task
            </label>
            <div className={styles.maxCountRow}>
              <input
                id="derived-max-count"
                type="number"
                className={`${styles.maxCountInput} ${addMaxCountError ? styles.inputError : ''}`}
                value={addMaxCount}
                min={1}
                onChange={(e) => {
                  setAddMaxCount(e.target.value);
                  if (addMaxCountError) setAddMaxCountError('');
                }}
                placeholder="e.g. 100"
              />
              {addMaxCount && !isNaN(parseInt(addMaxCount, 10)) && parseInt(addMaxCount, 10) >= 1 && (
                <span className={styles.titlePreview}>
                  Title: <em>{generateCounterTaskTitle(source.action, parseInt(addMaxCount, 10), source.unit)}</em>
                </span>
              )}
            </div>
            {addMaxCountError && (
              <p className={styles.fieldError}>{addMaxCountError}</p>
            )}
          </div>

          <button
            type="button"
            className={styles.addButton}
            onClick={handleAddDerived}
          >
            Add derived task
          </button>
        </div>
      </section>

      {/* ── Derived tasks list ── */}
      <section className={styles.section}>
        <h4 className={styles.sectionTitle}>
          Derived tasks ({derived.length})
        </h4>

        {derived.length === 0 ? (
          <p className={styles.emptyState}>
            No derived tasks yet. Use the form above to add one.
          </p>
        ) : (
          <div className={styles.derivedList}>
            {derived.map((d) => {
              const result = deriveDisplayedCount(
                { baseline: d.baseline, maxCount: d.maxCount },
                { currentCount: source.currentCount },
              );
              return (
                <DerivedCounterRow
                  key={d.id}
                  data={d}
                  result={result}
                  onRemove={handleRemoveDerived}
                />
              );
            })}
          </div>
        )}

        {/* Overshoot invariant callout — visible when at least one derived is completed and source keeps climbing */}
        {derived.some((d) => {
          const r = deriveDisplayedCount(
            { baseline: d.baseline, maxCount: d.maxCount },
            { currentCount: source.currentCount },
          );
          return r.isCompleted && r.displayed > d.maxCount;
        }) && (
          <p className={styles.invariantNote}>
            No-clamp invariant in effect: displayed counts exceed maxCount above.
            This is intentional — the source keeps accumulating.
          </p>
        )}
      </section>

      {/* ── Dev: raw state dump (collapsed by default) ── */}
      <details className={styles.rawState}>
        <summary>Raw state (debug)</summary>
        <pre className={styles.rawStateCode}>
          {JSON.stringify(
            {
              source,
              derived: derived.map((d) => ({
                ...d,
                result: deriveDisplayedCount(
                  { baseline: d.baseline, maxCount: d.maxCount },
                  { currentCount: source.currentCount },
                ),
              })),
            },
            null,
            2,
          )}
        </pre>
      </details>
    </div>
  );
}
