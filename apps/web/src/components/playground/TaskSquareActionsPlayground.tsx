import { useState, useCallback } from 'react';
import { InteractiveTaskSquare, DetailModal, FloatingContextMenu } from '../InteractiveTaskSquare';
import {
  applyAction,
  type TaskSquareData,
  type SquareState,
  type ContextMenuState,
} from '../interactiveTaskSquareUtils';
import styles from './TaskSquareActionsPlayground.module.css';

// ─── Demo data ────────────────────────────────────────────────────────────────

const DEMO_SQUARES: TaskSquareData[] = [
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
    (sq: TaskSquareData) => {
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

  const handleResetCount = useCallback((id: string) => {
    setSquareStates((prev) => ({
      ...prev,
      [id]: { ...prev[id], currentCount: 0, isCompleted: false },
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
          <InteractiveTaskSquare
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
