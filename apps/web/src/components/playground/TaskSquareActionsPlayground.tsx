import { useState, useEffect, useRef, useCallback } from 'react';
import styles from './TaskSquareActionsPlayground.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

type SquareTaskType = 'normal' | 'counting' | 'progress';

interface ProgressStep {
  id: string;
  label: string;
}

interface DemoSquare {
  id: string;
  title: string;
  type: SquareTaskType;
  description?: string;
  /** counting only */
  action?: string;
  maxCount?: number;
  unit?: string;
  /** progress only */
  steps?: ProgressStep[];
}

interface SquareState {
  isCompleted: boolean;
  /** counting: current count */
  currentCount: number;
  /** progress: set of completed step IDs */
  completedStepIds: Set<string>;
}

interface ContextMenuState {
  squareId: string;
  x: number;
  y: number;
}

// ─── Demo data ────────────────────────────────────────────────────────────────

const DEMO_SQUARES: DemoSquare[] = [
  {
    id: 'sq-0',
    title: 'Morning Run',
    type: 'counting',
    action: 'Run',
    maxCount: 5,
    unit: 'km',
  },
  {
    id: 'sq-1',
    title: 'Read a book',
    type: 'normal',
    description: 'Spend 30 min reading',
  },
  {
    id: 'sq-2',
    title: 'Weekly Workout',
    type: 'progress',
    description: 'Complete all three sessions',
    steps: [
      { id: 'step-mon', label: 'Mon strength' },
      { id: 'step-wed', label: 'Wed cardio' },
      { id: 'step-fri', label: 'Fri yoga' },
    ],
  },
  {
    id: 'sq-3',
    title: 'Cook at home',
    type: 'normal',
    description: 'Prepare a meal from scratch',
  },
  {
    id: 'sq-4',
    title: 'Drink water',
    type: 'counting',
    action: 'Drink',
    maxCount: 8,
    unit: 'glasses',
  },
  {
    id: 'sq-5',
    title: 'Meditate',
    type: 'normal',
    description: 'Sit quietly for 10 min',
  },
  {
    id: 'sq-6',
    title: 'Learn Spanish',
    type: 'progress',
    description: 'Daily language practice',
    steps: [
      { id: 'step-duo', label: 'Duolingo lesson' },
      { id: 'step-vocab', label: 'Vocab review' },
      { id: 'step-pod', label: 'Podcast' },
    ],
  },
  {
    id: 'sq-7',
    title: 'Write in journal',
    type: 'normal',
    description: 'Reflect on your day',
  },
  {
    id: 'sq-8',
    title: 'Walk the dog',
    type: 'counting',
    action: 'Walk',
    maxCount: 3,
    unit: 'km',
  },
];

/** Build initial state for all squares */
function buildInitialState(): Record<string, SquareState> {
  const record: Record<string, SquareState> = {};
  for (const sq of DEMO_SQUARES) {
    record[sq.id] = {
      isCompleted: false,
      currentCount: 0,
      completedStepIds: new Set(),
    };
  }
  return record;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Perform the "type-specific action" for a square:
 * - normal: toggle completion
 * - counting: increment count (caps at maxCount, marks complete at max)
 * - progress: no grid-level action (callers should open modal instead)
 *
 * Returns the updated SquareState.
 */
function applyAction(
  sq: DemoSquare,
  prev: SquareState,
): SquareState {
  if (sq.type === 'normal') {
    return { ...prev, isCompleted: !prev.isCompleted };
  }
  if (sq.type === 'counting') {
    const max = sq.maxCount ?? 1;
    const next = Math.min(prev.currentCount + 1, max);
    return { ...prev, currentCount: next, isCompleted: next >= max };
  }
  // progress — no grid-level action; callers should open modal instead
  return prev;
}

/**
 * Compute the progress fraction [0, 1] for a square.
 */
function progressFraction(sq: DemoSquare, state: SquareState): number {
  if (sq.type === 'counting') {
    const max = sq.maxCount ?? 1;
    return max === 0 ? 0 : state.currentCount / max;
  }
  if (sq.type === 'progress') {
    const total = sq.steps?.length ?? 0;
    if (total === 0) return 0;
    return state.completedStepIds.size / total;
  }
  return 0;
}

/** Label shown inside the progress bar */
function progressBarLabel(sq: DemoSquare, state: SquareState): string {
  if (sq.type === 'counting') {
    return `${state.currentCount}/${sq.maxCount} ${sq.unit ?? ''}`.trim();
  }
  if (sq.type === 'progress') {
    const total = sq.steps?.length ?? 0;
    return `${state.completedStepIds.size}/${total} steps`;
  }
  return '';
}

// ─── TaskBingoSquare sub-component ────────────────────────────────────────────

interface TaskBingoSquareProps {
  sq: DemoSquare;
  state: SquareState;
  onAct: () => void;
  onContextMenu: (e: React.MouseEvent) => void;
}

/**
 * A single 90x90 bingo square with task name, optional progress bar, and checkmark on completion.
 * Click to act, right-click for context menu.
 */
function TaskBingoSquare({
  sq,
  state,
  onAct,
  onContextMenu,
}: TaskBingoSquareProps) {
  const hasProgress = sq.type === 'counting' || sq.type === 'progress';
  const fraction = progressFraction(sq, state);
  const barLabel = progressBarLabel(sq, state);

  const handleClick = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      onAct();
    },
    [onAct],
  );

  const handleContextMenu = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      onContextMenu(e);
    },
    [onContextMenu],
  );

  return (
    <div
      role="button"
      tabIndex={0}
      className={`${styles.taskSquare} ${state.isCompleted ? styles.taskSquareCompleted : ''}`}
      onClick={handleClick}
      onContextMenu={handleContextMenu}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          onAct();
        }
      }}
      aria-label={sq.title}
      aria-pressed={state.isCompleted}
    >
      {/* Checkmark (visible when completed) */}
      <span className={styles.checkmark}>✓</span>

      {/* Task name */}
      <span className={styles.taskName}>{sq.title}</span>

      {/* Action hint (counting tasks only, visible on hover) */}
      {sq.type === 'counting' && sq.unit && (
        <span className={styles.actionHint}>Tap: +1 {sq.unit}</span>
      )}

      {/* Progress bar */}
      {hasProgress && (
        <div className={styles.progressBarWrapper}>
          <div
            className={`${styles.progressBarFill} ${
              sq.type === 'counting'
                ? styles.progressBarFillCounting
                : styles.progressBarFillProgress
            }`}
            style={{ width: `${fraction * 100}%` }}
          />
          <div className={styles.progressBarLabel}>{barLabel}</div>
        </div>
      )}
    </div>
  );
}

// ─── Detail modal ─────────────────────────────────────────────────────────────

interface DetailModalProps {
  sq: DemoSquare;
  state: SquareState;
  onClose: () => void;
  onToggleComplete: (id: string) => void;
  onIncrementCount: (id: string) => void;
  onDecrementCount: (id: string) => void;
  onToggleStep: (squareId: string, stepId: string) => void;
}

/**
 * A detail modal rendered as a fixed overlay with backdrop.
 * Backdrop clicks close the modal; inner clicks do not.
 */
function DetailModal({
  sq,
  state,
  onClose,
  onToggleComplete,
  onIncrementCount,
  onDecrementCount,
  onToggleStep,
}: DetailModalProps) {
  // Close on Escape key
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [onClose]);

  const fraction = progressFraction(sq, state);
  const barLabel = progressBarLabel(sq, state);

  return (
    <div
      className={styles.modalBackdrop}
      onClick={onClose}
      role="presentation"
    >
      {/* Inner content stops propagation so clicks don't close */}
      <div
        className={styles.modal}
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-labelledby="modal-title"
      >
        <button
          className={styles.modalCloseButton}
          onClick={onClose}
          aria-label="Close"
        >
          ✕
        </button>

        <h3 id="modal-title" className={styles.modalTitle}>
          {sq.title}
        </h3>

        {/* Normal task */}
        {sq.type === 'normal' && (
          <>
            {sq.description && (
              <p className={styles.modalDescription}>{sq.description}</p>
            )}
            <button
              className={`${styles.modalButton} ${
                state.isCompleted
                  ? styles.modalButtonIncomplete
                  : styles.modalButtonComplete
              }`}
              onClick={() => onToggleComplete(sq.id)}
            >
              {state.isCompleted ? 'Mark Incomplete' : 'Mark Complete'}
            </button>
          </>
        )}

        {/* Counting task */}
        {sq.type === 'counting' && (
          <>
            <p className={styles.modalMeta}>
              {sq.action} · {sq.maxCount} {sq.unit}
            </p>
            {/* Progress bar */}
            <div className={styles.modalProgressBar}>
              <div
                className={`${styles.modalProgressFill} ${styles.modalProgressFillCounting}`}
                style={{ width: `${fraction * 100}%` }}
              />
              <div className={styles.modalProgressLabel}>{barLabel}</div>
            </div>
            {/* Counter controls */}
            <div className={styles.counterRow}>
              <button
                className={styles.counterButton}
                disabled={state.currentCount <= 0}
                onClick={() => onDecrementCount(sq.id)}
                aria-label="Decrease"
              >
                −
              </button>
              <span className={styles.counterValue}>
                {state.currentCount} / {sq.maxCount}
              </span>
              <button
                className={styles.counterButton}
                disabled={state.currentCount >= (sq.maxCount ?? 1)}
                onClick={() => onIncrementCount(sq.id)}
                aria-label="Increase"
              >
                +
              </button>
            </div>
          </>
        )}

        {/* Progress task */}
        {sq.type === 'progress' && (
          <>
            {sq.description && (
              <p className={styles.modalDescription}>{sq.description}</p>
            )}
            {/* Progress bar */}
            <div className={styles.modalProgressBar}>
              <div
                className={`${styles.modalProgressFill} ${styles.modalProgressFillProgress}`}
                style={{ width: `${fraction * 100}%` }}
              />
              <div className={styles.modalProgressLabel}>{barLabel}</div>
            </div>
            {/* Step checkboxes */}
            <div className={styles.stepsList}>
              {(sq.steps ?? []).map((step) => (
                <label key={step.id} className={styles.stepItem}>
                  <input
                    type="checkbox"
                    checked={state.completedStepIds.has(step.id)}
                    onChange={() => onToggleStep(sq.id, step.id)}
                  />
                  {step.label}
                </label>
              ))}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

// ─── Context menu ─────────────────────────────────────────────────────────────

interface ContextMenuProps {
  sq: DemoSquare;
  state: SquareState;
  position: { x: number; y: number };
  onClose: () => void;
  onToggleComplete: (id: string) => void;
  onIncrementCount: (id: string) => void;
  onDecrementCount: (id: string) => void;
  onResetCount: (id: string) => void;
  onMarkAllStepsComplete: (id: string) => void;
  onMarkAllStepsIncomplete: (id: string) => void;
  onViewDetails: (id: string) => void;
}

/**
 * Floating context menu positioned near the cursor, clamped to viewport.
 */
function FloatingContextMenu({
  sq,
  state,
  position,
  onClose,
  onToggleComplete,
  onIncrementCount,
  onDecrementCount,
  onResetCount,
  onMarkAllStepsComplete,
  onMarkAllStepsIncomplete,
  onViewDetails,
}: ContextMenuProps) {
  const menuRef = useRef<HTMLDivElement>(null);

  // Clamp to viewport once mounted
  const [pos, setPos] = useState(position);
  useEffect(() => {
    if (menuRef.current) {
      const { offsetWidth: w, offsetHeight: h } = menuRef.current;
      const x = Math.min(position.x, window.innerWidth - w - 8);
      const y = Math.min(position.y, window.innerHeight - h - 8);
      setPos({ x: Math.max(8, x), y: Math.max(8, y) });
    }
  }, [position]);

  // Close on click-outside or Escape
  useEffect(() => {
    const handleClick = () => onClose();
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    // Defer to avoid the triggering contextmenu event from also counting
    const id = setTimeout(() => {
      document.addEventListener('click', handleClick);
      document.addEventListener('keydown', handleKey);
    }, 0);
    return () => {
      clearTimeout(id);
      document.removeEventListener('click', handleClick);
      document.removeEventListener('keydown', handleKey);
    };
  }, [onClose]);

  const allStepsDone =
    sq.type === 'progress' &&
    (sq.steps ?? []).length > 0 &&
    state.completedStepIds.size >= (sq.steps ?? []).length;

  return (
    <div
      ref={menuRef}
      className={styles.contextMenu}
      style={{ left: pos.x, top: pos.y }}
      onClick={(e) => e.stopPropagation()}
    >
      {sq.type === 'normal' && (
        <button
          className={styles.contextMenuItem}
          onClick={() => {
            onToggleComplete(sq.id);
            onClose();
          }}
        >
          {state.isCompleted ? '✗ Mark Incomplete' : '✓ Mark Complete'}
        </button>
      )}

      {sq.type === 'counting' && (
        <>
          <button
            className={styles.contextMenuItem}
            onClick={() => {
              onIncrementCount(sq.id);
              onClose();
            }}
            disabled={state.currentCount >= (sq.maxCount ?? 1)}
          >
            + Add {sq.action} (+1)
          </button>
          <button
            className={styles.contextMenuItem}
            disabled={state.currentCount <= 0}
            onClick={() => {
              onDecrementCount(sq.id);
              onClose();
            }}
          >
            − Remove {sq.action} (−1)
          </button>
          <button
            className={styles.contextMenuItem}
            disabled={state.currentCount <= 0}
            onClick={() => {
              onResetCount(sq.id);
              onClose();
            }}
          >
            ↺ Reset
          </button>
        </>
      )}

      {sq.type === 'progress' && (
        <>
          <button
            className={styles.contextMenuItem}
            onClick={() => {
              onViewDetails(sq.id);
              onClose();
            }}
          >
            ✓ View Steps
          </button>
          <button
            className={styles.contextMenuItem}
            disabled={allStepsDone}
            onClick={() => {
              onMarkAllStepsComplete(sq.id);
              onClose();
            }}
          >
            ✓✓ Mark All Complete
          </button>
          <button
            className={styles.contextMenuItem}
            disabled={!allStepsDone}
            onClick={() => {
              onMarkAllStepsIncomplete(sq.id);
              onClose();
            }}
          >
            ✗ Mark Incomplete
          </button>
        </>
      )}

      <div className={styles.contextMenuDivider} />
      <button
        className={styles.contextMenuItem}
        onClick={() => {
          onViewDetails(sq.id);
          onClose();
        }}
      >
        ⓘ View Details
      </button>
    </div>
  );
}

// ─── Main playground component ────────────────────────────────────────────────

/**
 * TaskSquareActionsPlayground
 *
 * Demonstrates the "Act + Context Menu" interaction model for task squares on a
 * 3x3 bingo grid. Click/tap a square to perform its primary action (toggle,
 * increment, or open details). Right-click (web) or long-press (iOS) to open a
 * context menu with type-specific quick actions.
 */
export function TaskSquareActionsPlayground() {
  const [squareStates, setSquareStates] = useState<Record<string, SquareState>>(
    buildInitialState,
  );
  const [selectedSquareId, setSelectedSquareId] = useState<string | null>(null);
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);

  /** The square currently shown in the modal */
  const selectedSquare = selectedSquareId
    ? DEMO_SQUARES.find((s) => s.id === selectedSquareId) ?? null
    : null;

  // ── State mutators ──────────────────────────────────────────────────────────

  const handleAct = useCallback(
    (sq: DemoSquare) => {
      if (sq.type === 'progress') {
        // Progress tasks open the modal instead
        setSelectedSquareId(sq.id);
        return;
      }
      setSquareStates((prev) => ({
        ...prev,
        [sq.id]: applyAction(sq, prev[sq.id]),
      }));
    },
    [],
  );

  const handleToggleComplete = useCallback((id: string) => {
    setSquareStates((prev) => ({
      ...prev,
      [id]: { ...prev[id], isCompleted: !prev[id].isCompleted },
    }));
  }, []);

  const handleIncrementCount = useCallback((id: string) => {
    const sq = DEMO_SQUARES.find((s) => s.id === id);
    if (!sq) return;
    setSquareStates((prev) => {
      const cur = prev[id];
      const max = sq.maxCount ?? 1;
      const next = Math.min(cur.currentCount + 1, max);
      return { ...prev, [id]: { ...cur, currentCount: next, isCompleted: next >= max } };
    });
  }, []);

  const handleDecrementCount = useCallback((id: string) => {
    setSquareStates((prev) => {
      const cur = prev[id];
      const next = Math.max(cur.currentCount - 1, 0);
      return { ...prev, [id]: { ...cur, currentCount: next, isCompleted: false } };
    });
  }, []);

  const handleToggleStep = useCallback((squareId: string, stepId: string) => {
    const sq = DEMO_SQUARES.find((s) => s.id === squareId);
    if (!sq) return;
    setSquareStates((prev) => {
      const cur = prev[squareId];
      const updated = new Set(cur.completedStepIds);
      if (updated.has(stepId)) {
        updated.delete(stepId);
      } else {
        updated.add(stepId);
      }
      const allDone = (sq.steps ?? []).length > 0 && updated.size >= (sq.steps ?? []).length;
      return {
        ...prev,
        [squareId]: { ...cur, completedStepIds: updated, isCompleted: allDone },
      };
    });
  }, []);

  const handleResetCount = useCallback((id: string) => {
    setSquareStates((prev) => ({
      ...prev,
      [id]: { ...prev[id], currentCount: 0, isCompleted: false },
    }));
  }, []);

  const handleMarkAllStepsComplete = useCallback((id: string) => {
    const sq = DEMO_SQUARES.find((s) => s.id === id);
    if (!sq) return;
    const allIds = new Set((sq.steps ?? []).map((s) => s.id));
    setSquareStates((prev) => ({
      ...prev,
      [id]: { ...prev[id], completedStepIds: allIds, isCompleted: true },
    }));
  }, []);

  const handleMarkAllStepsIncomplete = useCallback((id: string) => {
    setSquareStates((prev) => ({
      ...prev,
      [id]: { ...prev[id], completedStepIds: new Set(), isCompleted: false },
    }));
  }, []);

  const handleResetAll = useCallback(() => {
    setSquareStates(buildInitialState());
    setSelectedSquareId(null);
    setContextMenu(null);
  }, []);

  // ── Render ──────────────────────────────────────────────────────────────────

  return (
    <div>
      <p style={{ color: 'var(--text-secondary)', marginBottom: '0.5rem' }}>
        Click a square to perform its primary action. Right-click for a context menu
        with type-specific quick actions and details.
      </p>
      <p className={styles.gestureHint}>
        Click to act · Right-click for quick options
      </p>

      {/* Reset button */}
      <div className={styles.controls}>
        <button className={styles.resetButton} onClick={handleResetAll}>
          Reset
        </button>
      </div>

      {/* 3×3 grid */}
      <div className={styles.grid}>
        {DEMO_SQUARES.map((sq) => (
          <TaskBingoSquare
            key={sq.id}
            sq={sq}
            state={squareStates[sq.id]}
            onAct={() => handleAct(sq)}
            onContextMenu={(e) => {
              setContextMenu({ squareId: sq.id, x: e.clientX, y: e.clientY });
            }}
          />
        ))}
      </div>

      {/* Detail modal */}
      {selectedSquare && squareStates[selectedSquare.id] && (
        <DetailModal
          sq={selectedSquare}
          state={squareStates[selectedSquare.id]}
          onClose={() => setSelectedSquareId(null)}
          onToggleComplete={handleToggleComplete}
          onIncrementCount={handleIncrementCount}
          onDecrementCount={handleDecrementCount}
          onToggleStep={handleToggleStep}
        />
      )}

      {/* Floating context menu */}
      {contextMenu && (() => {
        const sq = DEMO_SQUARES.find((s) => s.id === contextMenu.squareId);
        if (!sq) return null;
        return (
          <FloatingContextMenu
            sq={sq}
            state={squareStates[sq.id]}
            position={{ x: contextMenu.x, y: contextMenu.y }}
            onClose={() => setContextMenu(null)}
            onToggleComplete={handleToggleComplete}
            onIncrementCount={handleIncrementCount}
            onDecrementCount={handleDecrementCount}
            onResetCount={handleResetCount}
            onMarkAllStepsComplete={handleMarkAllStepsComplete}
            onMarkAllStepsIncomplete={handleMarkAllStepsIncomplete}
            onViewDetails={(id) => {
              setContextMenu(null);
              setSelectedSquareId(id);
            }}
          />
        );
      })()}
    </div>
  );
}
