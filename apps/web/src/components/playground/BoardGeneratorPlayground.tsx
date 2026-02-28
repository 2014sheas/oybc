import { useState } from 'react';
import { BingoBoard } from '../BingoBoard';
import { PLAYGROUND_USER_ID, generateSampleTaskTitles } from './playgroundUtils';
import { UnifiedTaskCreatorPlayground } from './UnifiedTaskCreatorPlayground';
import { useTasks } from '../../hooks/useTasks';
import { createTask } from '../../db/operations/tasks';
import { fisherYatesShuffle, CenterSquareType, getCenterSquareIndex, TaskType } from '@oybc/shared';

const BOARD_SIZE = 3;
const CENTER_INDEX = getCenterSquareIndex(BOARD_SIZE); // 4 for 3x3
const TASKS_NEEDED = BOARD_SIZE * BOARD_SIZE - 1; // 8 non-center squares

/**
 * Board Generator Playground
 *
 * Lets the user create tasks via the Unified Task Creator and generate a 3×3
 * bingo board from them. The center square is always a FREE space. At least 8
 * tasks are required to generate a board.
 */
export function BoardGeneratorPlayground() {
  const [isGeneratingSamples, setIsGeneratingSamples] = useState(false);
  const [sampleError, setSampleError] = useState<string | null>(null);

  const [boardTaskNames, setBoardTaskNames] = useState<string[] | null>(null);
  const [boardKey, setBoardKey] = useState(0);

  const tasks = useTasks(PLAYGROUND_USER_ID);
  const canGenerate = tasks.length >= TASKS_NEEDED;

  const handleGenerateSamples = async () => {
    setIsGeneratingSamples(true);
    setSampleError(null);
    try {
      const titles = generateSampleTaskTitles();
      for (const title of titles) {
        await createTask(PLAYGROUND_USER_ID, { title, type: TaskType.NORMAL });
      }
    } catch (e) {
      setSampleError(e instanceof Error ? e.message : 'Failed to generate sample tasks');
    } finally {
      setIsGeneratingSamples(false);
    }
  };

  const handleGenerateBoard = () => {
    // Shuffle all available tasks, pick 8, insert placeholder at center
    const shuffled = fisherYatesShuffle(tasks.map((t) => t.title));
    const selected = shuffled.slice(0, TASKS_NEEDED);
    selected.splice(CENTER_INDEX, 0, ''); // placeholder — center always shows "FREE SPACE"
    setBoardTaskNames(selected);
    setBoardKey((prev) => prev + 1); // force BingoBoard re-mount with fresh state
  };

  return (
    <div>
      <p style={{ color: 'var(--text-secondary)', marginBottom: '1rem' }}>
        Create tasks using the task creator below, then generate a 3×3 bingo board from them.
        The center square is always a free space. You need at least {TASKS_NEEDED} tasks to
        generate a board. Clicking "Generate Board" again draws a fresh random selection.
      </p>

      {/* Quick seed button */}
      <div style={{ marginBottom: '1.25rem' }}>
        <button
          onClick={handleGenerateSamples}
          disabled={isGeneratingSamples}
          style={{
            padding: '0.5rem 1rem',
            borderRadius: '6px',
            border: '1px solid var(--border-color, #ccc)',
            background: 'transparent',
            color: 'var(--text-primary, #000)',
            cursor: isGeneratingSamples ? 'not-allowed' : 'pointer',
            opacity: isGeneratingSamples ? 0.6 : 1,
            fontSize: '0.9rem',
          }}
        >
          {isGeneratingSamples ? 'Generating…' : 'Generate Sample Tasks'}
        </button>
        {sampleError && (
          <p style={{ color: '#e53e3e', marginTop: '0.5rem', fontSize: '0.875rem' }}>{sampleError}</p>
        )}
      </div>

      {/* Task creation and library via Unified Task Creator */}
      <UnifiedTaskCreatorPlayground />

      {/* Board generation */}
      <div style={{ marginTop: '1.5rem' }}>
        <p style={{ color: 'var(--text-secondary)', fontSize: '0.875rem', marginBottom: '0.75rem' }}>
          {tasks.length} task{tasks.length !== 1 ? 's' : ''} available
          {!canGenerate && ` — need ${TASKS_NEEDED - tasks.length} more`}
        </p>
        <button
          onClick={handleGenerateBoard}
          disabled={!canGenerate}
          style={{
            padding: '0.625rem 1.5rem',
            borderRadius: '6px',
            border: 'none',
            background: canGenerate ? '#007aff' : 'var(--bg-secondary, #eee)',
            color: canGenerate ? 'white' : 'var(--text-secondary, #999)',
            cursor: canGenerate ? 'pointer' : 'not-allowed',
            fontWeight: 700,
            fontSize: '1rem',
            marginBottom: boardTaskNames ? '1.5rem' : 0,
          }}
        >
          Generate Board
        </button>
      </div>

      {/* Generated board */}
      {boardTaskNames && (
        <BingoBoard
          key={boardKey}
          taskNames={boardTaskNames}
          gridSize={BOARD_SIZE}
          squareSize={90}
          centerSquareType={CenterSquareType.FREE}
        />
      )}
    </div>
  );
}
