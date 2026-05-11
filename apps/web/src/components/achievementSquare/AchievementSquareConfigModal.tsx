import { useEffect, useMemo, useState } from 'react';
import {
  Timeframe,
  hasCycle,
  type Board,
  type BoardTask,
  type RecurringBoardTemplate,
} from '@oybc/shared';
import styles from './AchievementSquareConfigModal.module.css';

/**
 * Phase 6.3 — Achievement-Square Config Modal
 *
 * Lets the user convert a regular task cell into an achievement square
 * (or revert it back). When the achievement-square toggle is ON, the
 * user picks one of three modes:
 *
 * - **Count across timeframe** (aggregate; pre-6.3 behavior) — driven by
 *   an external progress counter; the modal lets the user set the
 *   target count + timeframe + type (bingo vs full completion).
 * - **Watch a specific board** — `referencedBoardId` mode. Completes
 *   when the referenced board greenlogs.
 * - **Watch a recurring template** — `referencedTemplateId` mode.
 *   Completes when ALL in-window non-deleted spawns greenlog. Empty
 *   window ⇒ incomplete (NOT vacuously true) — surfaced as a warning.
 *
 * `referencedBoardId` and `referencedTemplateId` are mutually exclusive
 * at the Zod refinement layer. The modal's local state allows the user
 * to switch between modes freely; the Save patch clears whichever
 * fields don't belong to the chosen mode.
 *
 * Cycle detection runs at Save: see `hasCycle` in `@oybc/shared`. The
 * inline error displays the offending path so the user knows which
 * boards form the loop. Cycle detection is best-effort at placement
 * time; the derivation pass has a defensive short-circuit for
 * post-sync cycles that slip through (see Phase 6.3 plan).
 */

export type AchievementSquareConfigMode =
  | 'aggregate'
  | 'specificBoard'
  | 'recurringTemplate';

/** Shape of the patch handed to the caller's persistence helper.
 *  Mirrors `updateAchievementSquareConfig`'s expected patch in
 *  `apps/web/src/db/operations/boardTasks.ts`. `null` means "clear
 *  this field"; `undefined` means "leave unchanged" (but the modal
 *  always sets every relevant field explicitly to avoid stale state
 *  from a prior mode). */
export interface AchievementSquareConfigPatch {
  isAchievementSquare: boolean;
  achievementType?: 'bingo' | 'full_completion';
  achievementCount?: number;
  achievementTimeframe?: Timeframe;
  referencedBoardId: string | null;
  referencedTemplateId: string | null;
}

export interface AchievementSquareConfigModalProps {
  /** The cell being edited. Modal hydrates from its existing fields. */
  boardTask: BoardTask;
  /** The board the cell sits on. Used for window-bound display + cycle
   *  detection. */
  parentBoard: Board;
  /** All non-deleted boards in the workspace — for the board picker
   *  and cycle detection. The picker hides the parent board (a square
   *  can't reference its own board). */
  allBoards: Board[];
  /** All non-deleted board_tasks in the workspace — for cycle
   *  detection's adjacency walk. */
  allBoardTasks: BoardTask[];
  /** All non-deleted active recurring templates — for the template
   *  picker. Paused templates are NOT filtered out; the modal renders
   *  an inline "paused" warning so the user can choose to proceed
   *  knowing the implication. */
  allTemplates: RecurringBoardTemplate[];
  /** Human-readable title of the underlying task; displayed in the
   *  modal header so the user knows which cell they're configuring. */
  taskTitle: string;
  /** Called when the user confirms a change. Caller persists via
   *  `updateAchievementSquareConfig` (or equivalent). The modal awaits
   *  the promise before closing so the caller can surface errors. */
  onSave: (patch: AchievementSquareConfigPatch) => Promise<void> | void;
  /** Called on Cancel / Escape / backdrop click. */
  onClose: () => void;
}

interface CycleErrorState {
  cyclePath: string[];
}

export function AchievementSquareConfigModal({
  boardTask,
  parentBoard,
  allBoards,
  allBoardTasks,
  allTemplates,
  taskTitle,
  onSave,
  onClose,
}: AchievementSquareConfigModalProps): React.ReactElement {
  // ─── Local edit state ─────────────────────────────────────────────────
  // Hydrate from the existing BoardTask row. The user's local edits
  // don't persist until Save; Cancel discards them.
  const [isAchievement, setIsAchievement] = useState<boolean>(
    boardTask.isAchievementSquare ?? false,
  );
  const [mode, setMode] = useState<AchievementSquareConfigMode>(() => {
    if (boardTask.referencedBoardId) return 'specificBoard';
    if (boardTask.referencedTemplateId) return 'recurringTemplate';
    return 'aggregate';
  });
  const [count, setCount] = useState<number>(boardTask.achievementCount ?? 1);
  const [timeframe, setTimeframe] = useState<Timeframe>(
    boardTask.achievementTimeframe ?? Timeframe.WEEKLY,
  );
  const [achievementType, setAchievementType] = useState<'bingo' | 'full_completion'>(
    boardTask.achievementType ?? 'full_completion',
  );
  const [referencedBoardId, setReferencedBoardId] = useState<string | null>(
    boardTask.referencedBoardId ?? null,
  );
  const [referencedTemplateId, setReferencedTemplateId] = useState<string | null>(
    boardTask.referencedTemplateId ?? null,
  );
  const [boardSearch, setBoardSearch] = useState('');
  const [templateSearch, setTemplateSearch] = useState('');
  const [cycleError, setCycleError] = useState<CycleErrorState | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  // ─── Escape-to-close ──────────────────────────────────────────────────
  useEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  // ─── Derived: filtered picker lists ───────────────────────────────────
  // Board picker excludes the parent board (a square can't reference
  // its own board), soft-deleted boards, and matches on case-insensitive
  // substring search.
  const filteredBoards = useMemo(() => {
    const query = boardSearch.trim().toLowerCase();
    return allBoards
      .filter((b) => b.id !== parentBoard.id && !b.isDeleted)
      .filter((b) => (query ? b.name.toLowerCase().includes(query) : true));
  }, [allBoards, parentBoard.id, boardSearch]);

  const filteredTemplates = useMemo(() => {
    const query = templateSearch.trim().toLowerCase();
    return allTemplates
      .filter((t) => !t.isDeleted)
      .filter((t) => (query ? t.name.toLowerCase().includes(query) : true));
  }, [allTemplates, templateSearch]);

  // ─── Derived: template-mode warnings ──────────────────────────────────
  // Empty-window: no template spawns fall within the parent board's
  // [startDate, endDate]. The square would be incomplete until a
  // future spawn lands — surfaced so the user knows what they're
  // signing up for, not blocked (they may intend it).
  const selectedTemplate = useMemo(
    () => allTemplates.find((t) => t.id === referencedTemplateId) ?? null,
    [allTemplates, referencedTemplateId],
  );
  const templateInWindowCount = useMemo(() => {
    if (!selectedTemplate) return 0;
    return allBoards.filter(
      (b) =>
        !b.isDeleted &&
        b.spawnedFromTemplateId === selectedTemplate.id &&
        b.startDate >= parentBoard.startDate &&
        b.startDate <= parentBoard.endDate,
    ).length;
  }, [selectedTemplate, allBoards, parentBoard.startDate, parentBoard.endDate]);

  // ─── Save handler ─────────────────────────────────────────────────────
  // Composes the patch based on the current mode, runs cycle detection
  // for specific-mode placements, surfaces any error inline, otherwise
  // delegates to `onSave`. The modal closes only on successful save —
  // failures keep it open so the user can correct.
  const handleSave = async (): Promise<void> => {
    setCycleError(null);

    // Build the patch. When achievement square is OFF, clear both
    // reference fields (mutual-exclusion guarantee) and isAchievementSquare.
    // When ON + aggregate: clear refs, set aggregate fields.
    // When ON + specificBoard: clear template + aggregate fields, set ref.
    // When ON + recurringTemplate: clear board + aggregate fields, set ref.
    let patch: AchievementSquareConfigPatch;
    if (!isAchievement) {
      patch = {
        isAchievementSquare: false,
        referencedBoardId: null,
        referencedTemplateId: null,
      };
    } else if (mode === 'aggregate') {
      patch = {
        isAchievementSquare: true,
        achievementType,
        achievementCount: count,
        achievementTimeframe: timeframe,
        referencedBoardId: null,
        referencedTemplateId: null,
      };
    } else if (mode === 'specificBoard') {
      patch = {
        isAchievementSquare: true,
        referencedBoardId,
        referencedTemplateId: null,
      };
    } else {
      patch = {
        isAchievementSquare: true,
        referencedBoardId: null,
        referencedTemplateId,
      };
    }

    // Cycle detection — only meaningful for the two specific modes.
    // The candidate carries whichever field is non-null; hasCycle's
    // adjacency walk handles both edge kinds (direct + template
    // fan-out). The walk is best-effort: a multi-device race can
    // form a cycle post-sync that this check can't see, but
    // derivationPass has a defensive short-circuit for that case.
    if (isAchievement && (mode === 'specificBoard' || mode === 'recurringTemplate')) {
      const cycle = hasCycle(
        {
          boardId: parentBoard.id,
          referencedBoardId: patch.referencedBoardId ?? undefined,
          referencedTemplateId: patch.referencedTemplateId ?? undefined,
        },
        { allBoardTasks, allBoards },
      );
      if (!cycle.ok) {
        setCycleError({ cyclePath: cycle.cyclePath });
        return;
      }
    }

    setIsSaving(true);
    try {
      await onSave(patch);
      onClose();
    } finally {
      setIsSaving(false);
    }
  };

  // ─── Save-button enabled state ────────────────────────────────────────
  // Off-toggle: always allowed (clears the cell back to a normal task).
  // On + aggregate: count > 0.
  // On + specificBoard: a board must be picked.
  // On + recurringTemplate: a template must be picked.
  const canSave =
    !isAchievement ||
    (mode === 'aggregate' && count > 0) ||
    (mode === 'specificBoard' && referencedBoardId !== null) ||
    (mode === 'recurringTemplate' && referencedTemplateId !== null);

  return (
    <div
      className={styles.backdrop}
      role="dialog"
      aria-modal="true"
      aria-labelledby="ach-config-title"
      onClick={onClose}
    >
      <div className={styles.dialog} onClick={(e) => e.stopPropagation()}>
        <div className={styles.header}>
          <div>
            <h3 id="ach-config-title" className={styles.title}>
              Configure cell
            </h3>
            <p className={styles.subtitle}>{taskTitle}</p>
          </div>
          <button
            type="button"
            className={styles.closeButton}
            onClick={onClose}
            aria-label="Close"
          >
            ×
          </button>
        </div>

        {/* ── Toggle: treat as achievement square ── */}
        <div className={styles.section}>
          <label className={styles.toggleRow}>
            <input
              type="checkbox"
              checked={isAchievement}
              onChange={(e) => setIsAchievement(e.target.checked)}
            />
            <span className={styles.toggleLabel}>
              Treat this cell as an achievement square
            </span>
          </label>
          <p className={styles.toggleHelp}>
            Achievement squares complete from cross-board signals (other
            boards greenlogging, recurring spawns completing) instead of
            the cell's underlying task.
          </p>
        </div>

        {/* ── Mode selector — only when achievement square is ON ── */}
        {isAchievement && (
          <div className={styles.section}>
            <span className={styles.sectionLabel}>Completion source</span>
            <div className={styles.modeRow}>
              <label
                className={`${styles.modeOption} ${mode === 'aggregate' ? styles.modeOptionSelected : ''}`}
              >
                <div className={styles.modeHeader}>
                  <input
                    type="radio"
                    name="ach-mode"
                    checked={mode === 'aggregate'}
                    onChange={() => setMode('aggregate')}
                  />
                  Count across timeframe
                </div>
                <div className={styles.modeDescription}>
                  Completes after N boards of the chosen timeframe meet
                  the chosen condition (bingo or full completion).
                </div>
              </label>

              <label
                className={`${styles.modeOption} ${mode === 'specificBoard' ? styles.modeOptionSelected : ''}`}
              >
                <div className={styles.modeHeader}>
                  <input
                    type="radio"
                    name="ach-mode"
                    checked={mode === 'specificBoard'}
                    onChange={() => setMode('specificBoard')}
                  />
                  Watch a specific board
                </div>
                <div className={styles.modeDescription}>
                  Completes when one named board greenlogs.
                </div>
              </label>

              <label
                className={`${styles.modeOption} ${mode === 'recurringTemplate' ? styles.modeOptionSelected : ''}`}
              >
                <div className={styles.modeHeader}>
                  <input
                    type="radio"
                    name="ach-mode"
                    checked={mode === 'recurringTemplate'}
                    onChange={() => setMode('recurringTemplate')}
                  />
                  Watch a recurring template
                </div>
                <div className={styles.modeDescription}>
                  Completes when every spawn of the template that falls
                  inside this board's window greenlogs. Empty window =
                  incomplete (a future spawn must land first).
                </div>
              </label>
            </div>
          </div>
        )}

        {/* ── Mode-specific sub-controls ── */}
        {isAchievement && mode === 'aggregate' && (
          <div className={styles.section}>
            <span className={styles.sectionLabel}>Aggregate settings</span>
            <div className={styles.fieldGrid}>
              <div className={styles.fieldGroup}>
                <label className={styles.fieldLabel} htmlFor="ach-count">
                  Boards needed
                </label>
                <input
                  id="ach-count"
                  className={styles.input}
                  type="number"
                  min={1}
                  value={count}
                  onChange={(e) => setCount(Math.max(1, parseInt(e.target.value, 10) || 1))}
                />
              </div>
              <div className={styles.fieldGroup}>
                <label className={styles.fieldLabel} htmlFor="ach-timeframe">
                  Timeframe
                </label>
                <select
                  id="ach-timeframe"
                  className={styles.select}
                  value={timeframe}
                  onChange={(e) => setTimeframe(e.target.value as Timeframe)}
                >
                  <option value={Timeframe.DAILY}>Daily</option>
                  <option value={Timeframe.WEEKLY}>Weekly</option>
                  <option value={Timeframe.MONTHLY}>Monthly</option>
                  <option value={Timeframe.YEARLY}>Yearly</option>
                </select>
              </div>
              <div className={styles.fieldGroup} style={{ gridColumn: '1 / -1' }}>
                <label className={styles.fieldLabel} htmlFor="ach-type">
                  Condition
                </label>
                <select
                  id="ach-type"
                  className={styles.select}
                  value={achievementType}
                  onChange={(e) =>
                    setAchievementType(e.target.value as 'bingo' | 'full_completion')
                  }
                >
                  <option value="bingo">Bingo line completed</option>
                  <option value="full_completion">All squares completed</option>
                </select>
              </div>
            </div>
          </div>
        )}

        {isAchievement && mode === 'specificBoard' && (
          <div className={styles.section}>
            <span className={styles.sectionLabel}>Pick a board</span>
            <input
              className={`${styles.input} ${styles.searchInput}`}
              type="text"
              placeholder="Search boards…"
              value={boardSearch}
              onChange={(e) => setBoardSearch(e.target.value)}
            />
            <div className={styles.pickerList}>
              {filteredBoards.length === 0 ? (
                <div className={styles.pickerEmpty}>No matching boards.</div>
              ) : (
                filteredBoards.map((b) => (
                  <button
                    key={b.id}
                    type="button"
                    className={`${styles.pickerRow} ${
                      referencedBoardId === b.id ? styles.pickerRowSelected : ''
                    }`}
                    onClick={() => setReferencedBoardId(b.id)}
                  >
                    <span>{b.name}</span>
                    <span className={styles.pickerRowMeta}>
                      {b.timeframe} · {b.status}
                    </span>
                  </button>
                ))
              )}
            </div>
          </div>
        )}

        {isAchievement && mode === 'recurringTemplate' && (
          <div className={styles.section}>
            <span className={styles.sectionLabel}>Pick a template</span>
            <input
              className={`${styles.input} ${styles.searchInput}`}
              type="text"
              placeholder="Search templates…"
              value={templateSearch}
              onChange={(e) => setTemplateSearch(e.target.value)}
            />
            <div className={styles.pickerList}>
              {filteredTemplates.length === 0 ? (
                <div className={styles.pickerEmpty}>
                  No matching templates. Create one in Profile → Recurring templates.
                </div>
              ) : (
                filteredTemplates.map((t) => (
                  <button
                    key={t.id}
                    type="button"
                    className={`${styles.pickerRow} ${
                      referencedTemplateId === t.id ? styles.pickerRowSelected : ''
                    }`}
                    onClick={() => setReferencedTemplateId(t.id)}
                  >
                    <span>{t.name}</span>
                    <span className={styles.pickerRowMeta}>
                      {t.timeframe}
                      {!t.isActive ? ' · paused' : ''}
                    </span>
                  </button>
                ))
              )}
            </div>

            {/* Paused-template warning — surfaced inline so the user
                can see the implication before saving. Doesn't block. */}
            {selectedTemplate && !selectedTemplate.isActive && (
              <div className={styles.warning}>
                This template is paused; only existing spawns will count
                toward this square. Resume it from Profile → Recurring
                templates if you want new windows to spawn.
              </div>
            )}

            {/* Empty-window warning — the square would never complete
                with the current state of this board's window. */}
            {selectedTemplate && templateInWindowCount === 0 && (
              <div className={styles.warning}>
                No spawns of <strong>{selectedTemplate.name}</strong> fall
                inside this board's window
                (<code>{parentBoard.startDate.split('T')[0]} → {parentBoard.endDate.split('T')[0]}</code>).
                The square will only complete after a future spawn lands
                inside that window.
              </div>
            )}
          </div>
        )}

        {/* ── Cycle-detection error display ── */}
        {cycleError && (
          <div className={styles.error}>
            This would create a cycle in the cross-board dependency graph.
            <br />
            <span className={styles.cyclePath}>
              {cycleError.cyclePath
                .map((id) => {
                  const b = allBoards.find((x) => x.id === id);
                  return b?.name ?? id.slice(0, 8);
                })
                .join(' → ')}
            </span>
          </div>
        )}

        {/* ── Footer actions ── */}
        <div className={styles.footer}>
          <button
            type="button"
            className={styles.cancelButton}
            onClick={onClose}
            disabled={isSaving}
          >
            Cancel
          </button>
          <button
            type="button"
            className={styles.saveButton}
            onClick={() => void handleSave()}
            disabled={!canSave || isSaving}
          >
            {isSaving ? 'Saving…' : 'Save'}
          </button>
        </div>
      </div>
    </div>
  );
}
