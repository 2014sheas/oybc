import { useRef, useState, useMemo, useEffect } from 'react';
import {
  TaskType,
  generateCounterTaskTitle,
  findLinkableCounter,
  type Task,
  type LinkableCounter,
} from '@oybc/shared';
import { useTaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { DerivedCounterRow } from '../DerivedCounterRow';
import { deriveDisplayedCount } from '@oybc/shared';
import styles from './CountingTemplatePicker.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

/** Which mode the picker is in. */
type PickerMode = 'template' | 'link';

/** Baseline mode for "Link to existing counter". */
export type BaselineMode = 'inherit' | 'startFromZero';

/**
 * Result emitted by the "Link to existing counter" create flow.
 */
export interface LinkedCounterInput {
  /** The source counting task the new task will derive from. */
  source: Task;
  /**
   * The user-supplied threshold for the new linked task.
   * Validated: integer >= 1.
   */
  maxCount: number;
  /** Title for the new task. Auto-generated via generateCounterTaskTitle() but editable. */
  title: string;
  /** Baseline mode chosen by the user. */
  baselineMode: BaselineMode;
  /**
   * Computed baseline value:
   *   - "inherit" → 0
   *   - "startFromZero" → source.currentCount at link time
   */
  baseline: number;
}

export interface CountingTemplatePickerProps {
  /** Authenticated user id — used to load the task library. */
  userId: string | undefined;
  /** The task currently used as a template, or null if none (template mode). */
  selectedTemplate: Task | null;
  /** Called when the user picks a source counting task in template mode. */
  onSelect: (task: Task) => void;
  /** Called when the user clears the current template selection. */
  onClear: () => void;
  /**
   * Called when the user finishes the "Link to existing counter" flow and
   * presses Create (either via the suggestion card → link panel, or by
   * manually switching to the Link tab). The parent form should use this to
   * initiate a `createTask` call with `sharedCounterId` + `baseline` set.
   *
   * When omitted the "Link" mode tab is still rendered but the Create button
   * is disabled — useful for contexts where linking is not yet wired.
   */
  onCreateLinked?: (input: LinkedCounterInput) => void;
  /**
   * The current Action field value from the parent form. When action + unit
   * together match an existing counter, a one-tap link suggestion is shown.
   * Pass an empty string (or omit) if the suggestion is not applicable.
   */
  action?: string;
  /**
   * The current Unit field value from the parent form. See `action`.
   */
  unit?: string;
  /**
   * Exclude this task id from link suggestions — pass the id of the task
   * being edited so it can't be suggested as its own source.
   */
  excludeTaskId?: string;
}

/**
 * CountingTemplatePicker — Compact "derive from existing" affordance for
 * the counting-type variant of CreateNewTaskForm / CreateNewTaskFormView.
 *
 * ## Modes
 *
 * A segmented mode toggle at the top switches between:
 *   - **Use as template** (default): pre-fills action/unit from the picked
 *     source; `maxCount` is left blank. Same as original behaviour.
 *   - **Link to existing counter** (Phase 2): picks a source, sets a personal
 *     threshold, chooses an Inherit / Start-from-zero baseline, previews the
 *     `DerivedCounterRow`, and calls `onCreateLinked` on commit.
 *
 * ## Template mode (unchanged from Phase 1)
 *
 * When no template is selected: renders a dashed "Use existing counting task
 * as template..." button. Clicking opens an inline dropdown listing counting
 * tasks. When a template is selected: renders a compact banner
 * "Template: <title>" with a clear (×) button.
 *
 * ## Link mode (Phase 2)
 *
 * Shows the source picker (same list, relabelled), a Threshold input, a
 * baseline radio (Inherit / Start from zero), and a live `DerivedCounterRow`
 * preview. "Create linked task" calls `onCreateLinked`.
 */
export function CountingTemplatePicker({
  userId,
  selectedTemplate,
  onSelect,
  onClear,
  onCreateLinked,
  action = '',
  unit = '',
  excludeTaskId,
}: CountingTemplatePickerProps): React.ReactElement {
  // ─── Mode state ────────────────────────────────────────────────────────────
  const [mode, setMode] = useState<PickerMode>('template');

  // ─── Template-mode state ───────────────────────────────────────────────────
  const [open, setOpen] = useState(false);
  const buttonRef = useRef<HTMLButtonElement>(null);

  // ─── Link-mode state ───────────────────────────────────────────────────────
  const [linkSource, setLinkSource] = useState<Task | null>(null);
  const [linkOpen, setLinkOpen] = useState(false);
  const [thresholdStr, setThresholdStr] = useState('');
  const [baselineMode, setBaselineMode] = useState<BaselineMode>('inherit');
  const [linkedTitle, setLinkedTitle] = useState('');
  const [linkError, setLinkError] = useState<string | null>(null);

  // ─── Library ───────────────────────────────────────────────────────────────
  const library = useTaskLibrary(userId);
  const countingTasks = library.allTasks.filter(
    (t) => t.type === TaskType.COUNTING && !t.isDeleted,
  );

  // ─── Link suggestion ───────────────────────────────────────────────────────
  // Match the typed action+unit against the existing counter pool. Returns the
  // best source task to suggest joining, or null (no suggestion shown).
  const suggestion = useMemo<LinkableCounter | null>(
    () => findLinkableCounter({ action, unit, excludeTaskId }, library.allTasks),
    [action, unit, excludeTaskId, library.allTasks],
  );

  // Track whether the user has dismissed the suggestion for the current
  // action+unit pair. Reset whenever action or unit changes so a fresh type
  // re-surfaces the card automatically.
  const [suggestionDismissed, setSuggestionDismissed] = useState(false);
  useEffect(() => {
    setSuggestionDismissed(false);
  }, [action, unit]);

  // ─── Template-mode handlers ────────────────────────────────────────────────

  function handleTemplateSelect(task: Task): void {
    onSelect(task);
    setOpen(false);
  }

  // ─── Link-mode handlers ────────────────────────────────────────────────────

  function handleLinkSourceSelect(task: Task): void {
    setLinkSource(task);
    setLinkOpen(false);
    // Auto-generate title only when a valid threshold already exists.
    // Without the guard, selecting a source before entering a threshold
    // would generate titles like "Read 0 pages" (maxCount = 0 fallback).
    const maxCountNum = parseInt(thresholdStr, 10);
    const thresholdIsValid = Number.isInteger(maxCountNum) && maxCountNum >= 1;
    if (thresholdIsValid) {
      const autoTitle = generateCounterTaskTitle(
        task.action ?? '',
        maxCountNum,
        task.unit ?? '',
      );
      setLinkedTitle(autoTitle);
    }
    // If no valid threshold yet, leave linkedTitle empty so the placeholder
    // ("Auto-generated from source") shows and autogen fires in handleThresholdChange.
  }

  function handleThresholdChange(val: string): void {
    setThresholdStr(val);
    if (linkSource) {
      const num = parseInt(val, 10);
      if (!isNaN(num) && num >= 1) {
        const autoTitle = generateCounterTaskTitle(
          linkSource.action ?? '',
          num,
          linkSource.unit ?? '',
        );
        setLinkedTitle(autoTitle);
      }
    }
  }

  function handleCreateLinked(): void {
    setLinkError(null);

    if (!linkSource) {
      setLinkError('Select a source counter.');
      return;
    }
    const maxCount = parseInt(thresholdStr, 10);
    if (!Number.isInteger(maxCount) || maxCount < 1) {
      setLinkError('Threshold must be a positive integer.');
      return;
    }

    const sourceCount = linkSource.currentCount ?? 0;
    const baseline = baselineMode === 'inherit' ? 0 : sourceCount;

    const finalTitle =
      linkedTitle.trim() ||
      generateCounterTaskTitle(linkSource.action ?? '', maxCount, linkSource.unit ?? '');

    if (onCreateLinked) {
      onCreateLinked({
        source: linkSource,
        maxCount,
        title: finalTitle,
        baselineMode,
        baseline,
      });
    }
  }

  // ─── Mode toggle ───────────────────────────────────────────────────────────

  function handleModeChange(next: PickerMode): void {
    setMode(next);
    // Clear link state when switching back to template mode so a partial
    // link setup doesn't bleed into the template flow.
    if (next === 'template') {
      setLinkSource(null);
      setThresholdStr('');
      setBaselineMode('inherit');
      setLinkedTitle('');
      setLinkError(null);
    }
    // When switching to template mode also clear the template selection if
    // the user already had one — the fields will be pre-filled by the parent.
    if (next === 'link' && selectedTemplate !== null) {
      onClear();
    }
  }

  // ─── Suggestion card handler ───────────────────────────────────────────────

  function handleSuggestionLink(): void {
    if (!suggestion) return;
    const sourceTask = library.allTasks.find((t) => t.id === suggestion.counterId);
    if (!sourceTask) return;
    // Pre-populate the link panel with the suggested source and the spec's
    // default baseline (start-at-zero — the new task begins fresh while the
    // all-time counter keeps climbing).
    setLinkSource(sourceTask);
    setBaselineMode('startFromZero');
    setLinkOpen(false);
    setMode('link');
  }

  // ─── Link mode preview ─────────────────────────────────────────────────────

  const thresholdNum = parseInt(thresholdStr, 10);
  const hasValidThreshold = Number.isInteger(thresholdNum) && thresholdNum >= 1;
  const sourceCount = linkSource?.currentCount ?? 0;
  const baseline = baselineMode === 'inherit' ? 0 : sourceCount;
  const previewTitle =
    linkedTitle.trim() ||
    (linkSource && hasValidThreshold
      ? generateCounterTaskTitle(linkSource.action ?? '', thresholdNum, linkSource.unit ?? '')
      : '');
  const showPreview = linkSource !== null && hasValidThreshold;
  const previewResult = showPreview
    ? deriveDisplayedCount(
        { baseline, maxCount: thresholdNum },
        { currentCount: sourceCount },
      )
    : null;

  // ─── Render ────────────────────────────────────────────────────────────────

  // Show the suggestion card when: there is a match, the user hasn't dismissed
  // it for this action+unit pair, and we're not already in link mode.
  const showSuggestion = suggestion !== null && !suggestionDismissed && mode !== 'link';

  return (
    <div className={styles.pickerRoot}>
      {/* Link suggestion card — appears above the mode toggle when action+unit
          match an existing counter. One tap switches to the link panel with the
          source pre-selected; "No thanks" hides it for the current action+unit. */}
      {showSuggestion && (
        <div className={styles.suggestionCard} role="region" aria-label="Counter link suggestion">
          <div className={styles.suggestionContent}>
            <span className={styles.suggestionIcon} aria-hidden="true">↔</span>
            <div className={styles.suggestionText}>
              <p className={styles.suggestionTitle}>
                Counts on your existing <strong>"{suggestion.name}"</strong> counter
              </p>
              <p className={styles.suggestionMeta}>
                {suggestion.lifetime} all-time
                {' · '}
                {suggestion.memberCount} task{suggestion.memberCount !== 1 ? 's' : ''}
              </p>
            </div>
          </div>
          <div className={styles.suggestionActions}>
            <button
              type="button"
              className={styles.suggestionLinkBtn}
              onClick={handleSuggestionLink}
            >
              Link
            </button>
            <button
              type="button"
              className={styles.suggestionDismissBtn}
              onClick={() => setSuggestionDismissed(true)}
            >
              No thanks
            </button>
          </div>
        </div>
      )}

      {/* Mode toggle */}
      <div className={styles.modeToggle} role="group" aria-label="Counting task picker mode">
        <button
          type="button"
          className={`${styles.modeTab} ${mode === 'template' ? styles.modeTabActive : ''}`}
          onClick={() => handleModeChange('template')}
          aria-pressed={mode === 'template'}
        >
          Use as template
        </button>
        <button
          type="button"
          className={`${styles.modeTab} ${mode === 'link' ? styles.modeTabActive : ''}`}
          onClick={() => handleModeChange('link')}
          aria-pressed={mode === 'link'}
        >
          Link to existing counter
        </button>
      </div>

      {/* Template mode */}
      {mode === 'template' && (
        <>
          {selectedTemplate !== null ? (
            <div className={styles.selectedBanner}>
              <span className={styles.selectedLabel}>Template:</span>
              <span className={styles.selectedTitle}>{selectedTemplate.title}</span>
              <button
                type="button"
                className={styles.clearButton}
                onClick={onClear}
                aria-label="Clear template"
              >
                ✕
              </button>
            </div>
          ) : (
            <div className={styles.dropdownWrapper}>
              <button
                ref={buttonRef}
                type="button"
                className={styles.affordance}
                onClick={() => setOpen((prev) => !prev)}
                aria-expanded={open}
                aria-haspopup="listbox"
              >
                Use existing counting task as template...
              </button>
              {open && (
                <div className={styles.dropdown} role="listbox" aria-label="Counting task templates">
                  {countingTasks.length === 0 ? (
                    <p className={styles.dropdownEmpty}>No counting tasks in your library yet.</p>
                  ) : (
                    countingTasks.map((task) => (
                      <button
                        key={task.id}
                        type="button"
                        className={styles.dropdownItem}
                        role="option"
                        aria-selected={false}
                        onClick={() => handleTemplateSelect(task)}
                      >
                        {task.title}
                        {task.action && task.unit ? (
                          <span className={styles.dropdownMeta}>
                            {task.action} · {task.unit}
                          </span>
                        ) : null}
                      </button>
                    ))
                  )}
                </div>
              )}
            </div>
          )}
        </>
      )}

      {/* Link mode */}
      {mode === 'link' && (
        <div className={styles.linkPanel}>
          {/* Source picker */}
          <div className={styles.linkField}>
            <label className={styles.linkLabel}>Source counter</label>
            {linkSource !== null ? (
              <div className={styles.selectedBanner}>
                <span className={styles.selectedLabel}>Source:</span>
                <span className={styles.selectedTitle}>{linkSource.title}</span>
                <button
                  type="button"
                  className={styles.clearButton}
                  onClick={() => { setLinkSource(null); setLinkedTitle(''); }}
                  aria-label="Clear source"
                >
                  ✕
                </button>
              </div>
            ) : (
              <div className={styles.dropdownWrapper}>
                <button
                  type="button"
                  className={styles.affordance}
                  onClick={() => setLinkOpen((prev) => !prev)}
                  aria-expanded={linkOpen}
                  aria-haspopup="listbox"
                >
                  Pick a source counter...
                </button>
                {linkOpen && (
                  <div className={styles.dropdown} role="listbox" aria-label="Source counters">
                    {countingTasks.length === 0 ? (
                      <p className={styles.dropdownEmpty}>No counting tasks in your library yet.</p>
                    ) : (
                      countingTasks.map((task) => (
                        <button
                          key={task.id}
                          type="button"
                          className={styles.dropdownItem}
                          role="option"
                          aria-selected={false}
                          onClick={() => handleLinkSourceSelect(task)}
                        >
                          {task.title}
                          {task.action && task.unit ? (
                            <span className={styles.dropdownMeta}>
                              {task.action} · {task.unit} · {task.currentCount ?? 0} so far
                            </span>
                          ) : null}
                        </button>
                      ))
                    )}
                  </div>
                )}
              </div>
            )}
          </div>

          {/* Threshold input */}
          <div className={styles.linkField}>
            <label className={styles.linkLabel} htmlFor="link-threshold">
              Threshold <span className={styles.linkRequired}>*</span>
            </label>
            <input
              id="link-threshold"
              type="number"
              min="1"
              step="1"
              inputMode="numeric"
              className={styles.linkInput}
              value={thresholdStr}
              onChange={(e) => handleThresholdChange(e.target.value)}
              placeholder="e.g. 50"
            />
          </div>

          {/* Title (auto-filled, editable) */}
          <div className={styles.linkField}>
            <label className={styles.linkLabel} htmlFor="link-title">
              Title
            </label>
            <input
              id="link-title"
              type="text"
              className={styles.linkInput}
              value={linkedTitle}
              onChange={(e) => setLinkedTitle(e.target.value)}
              placeholder={
                linkSource && hasValidThreshold
                  ? generateCounterTaskTitle(linkSource.action ?? '', thresholdNum, linkSource.unit ?? '')
                  : 'Auto-generated from source'
              }
            />
          </div>

          {/* Baseline radio */}
          <div className={styles.linkField}>
            <span className={styles.linkLabel}>Baseline</span>
            <div className={styles.baselineRadioGroup}>
              <label className={styles.baselineRadioLabel}>
                <input
                  type="radio"
                  name="link-baseline-mode"
                  value="inherit"
                  checked={baselineMode === 'inherit'}
                  onChange={() => setBaselineMode('inherit')}
                />
                Inherit{' '}
                <span className={styles.baselineHint}>
                  (start counting from source's current total)
                </span>
              </label>
              <label className={styles.baselineRadioLabel}>
                <input
                  type="radio"
                  name="link-baseline-mode"
                  value="startFromZero"
                  checked={baselineMode === 'startFromZero'}
                  onChange={() => setBaselineMode('startFromZero')}
                />
                Start from zero{' '}
                <span className={styles.baselineHint}>
                  (ignore counts before link time)
                </span>
              </label>
            </div>
          </div>

          {/* Preview */}
          {showPreview && previewResult !== null && (
            <div className={styles.linkPreview}>
              <span className={styles.linkPreviewLabel}>Preview</span>
              <DerivedCounterRow
                data={{
                  id: 'preview',
                  title: previewTitle || '(auto-generated)',
                  maxCount: thresholdNum,
                  baseline,
                  baselineMode: baselineMode === 'inherit' ? 'Inherit' : 'Start from zero',
                }}
                result={previewResult}
              />
            </div>
          )}

          {/* Error */}
          {linkError && <p className={styles.linkError}>{linkError}</p>}

          {/* Create button */}
          <button
            type="button"
            className={styles.linkCreateButton}
            disabled={!onCreateLinked}
            onClick={handleCreateLinked}
            title={!onCreateLinked ? 'Linked counter create not available in this context' : undefined}
          >
            Create linked task
          </button>

        </div>
      )}
    </div>
  );
}
