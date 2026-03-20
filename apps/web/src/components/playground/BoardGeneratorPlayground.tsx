import { useState } from 'react';
import { BingoBoard } from '../BingoBoard';
import { PLAYGROUND_USER_ID, generateSampleTaskTitles } from './playgroundUtils';
import { UnifiedTaskCreatorPlayground } from './UnifiedTaskCreatorPlayground';
import { useTasks } from '../../hooks/useTasks';
import { createTask } from '../../db/operations/tasks';
import { fisherYatesShuffle, CenterSquareType, getCenterSquareIndex, TaskType } from '@oybc/shared';
import styles from './BoardGeneratorPlayground.module.css';

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
      <p className={styles.description}>
        Create tasks using the task creator below, then generate a 3×3 bingo board from them.
        The center square is always a free space. You need at least {TASKS_NEEDED} tasks to
        generate a board. Clicking "Generate Board" again draws a fresh random selection.
      </p>

      {/* Quick seed button */}
      <div className={styles.seedSection}>
        <button
          className={styles.seedButton}
          onClick={handleGenerateSamples}
          disabled={isGeneratingSamples}
        >
          {isGeneratingSamples ? 'Generating…' : 'Generate Sample Tasks'}
        </button>
        {sampleError && (
          <p className={styles.seedError}>{sampleError}</p>
        )}
      </div>

      {/* Task creation and library via Unified Task Creator */}
      <UnifiedTaskCreatorPlayground />

      {/* Board generation */}
      <div className={styles.generateSection}>
        <p className={styles.taskCount}>
          {tasks.length} task{tasks.length !== 1 ? 's' : ''} available
          {!canGenerate && ` — need ${TASKS_NEEDED - tasks.length} more`}
        </p>
        <button
          className={styles.generateButton}
          onClick={handleGenerateBoard}
          disabled={!canGenerate}
        >
          Generate Board
        </button>
      </div>

      {/* Generated board */}
      {boardTaskNames && (
        <div className={styles.boardContainer}>
          <BingoBoard
            key={boardKey}
            taskNames={boardTaskNames}
            gridSize={BOARD_SIZE}
            squareSize={90}
            centerSquareType={CenterSquareType.FREE}
          />
        </div>
      )}
    </div>
  );
}
