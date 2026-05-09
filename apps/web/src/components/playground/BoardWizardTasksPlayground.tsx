import { useCallback, useState } from 'react';
import { TaskType, OperatorType, Timeframe } from '@oybc/shared';
import { createTask, createCompound } from '../../db/operations/tasks';
import { useTaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { BoardWizardTasksStep } from '../wizard/BoardWizardTasksStep';
import { PLAYGROUND_USER_ID } from './playgroundUtils';
import styles from './BoardWizardTasksPlayground.module.css';

const REQUIRED_PRESETS: { label: string; value: number }[] = [
  { label: '3×3 (8)', value: 8 },
  { label: '3×3 chosen (9)', value: 9 },
  { label: '4×4 (16)', value: 16 },
  { label: '5×5 (24)', value: 24 },
  { label: '5×5 chosen (25)', value: 25 },
];

/**
 * BoardWizardTasksPlayground — Spike harness for build-sequence step 1
 * of the board-creation UX redesign.
 *
 * Mounts the production `BoardWizardTasksStep` component with simulated
 * wizard state. Exposes harness controls so the user can flex the
 * surface across configurations (different `tasksRequired` counts and
 * the conditional center-task radio) without spinning up the full
 * wizard plumbing.
 *
 * Persists no wizard state to the DB — selection lives in local state
 * only. Tasks created via the inline "+ New task" sheet ARE persisted
 * to the playground user's library so they survive a page reload.
 */
export function BoardWizardTasksPlayground(): React.ReactElement {
  const library = useTaskLibrary(PLAYGROUND_USER_ID);

  // Simulated wizard state ────────────────────────────────────────────
  const [selectedTaskIds, setSelectedTaskIds] = useState<Set<string>>(new Set());
  const [centerTaskId, setCenterTaskId] = useState<string | null>(null);

  // Harness controls ──────────────────────────────────────────────────
  const [tasksRequired, setTasksRequired] = useState<number>(16);
  const [centerTaskMode, setCenterTaskMode] = useState(false);
  const [navMessage, setNavMessage] = useState<string | null>(null);
  const [seedStatus, setSeedStatus] = useState<string | null>(null);
  const [isSeeding, setIsSeeding] = useState(false);

  const handleToggle = useCallback((taskId: string): void => {
    setSelectedTaskIds((prev) => {
      const next = new Set(prev);
      if (next.has(taskId)) next.delete(taskId);
      else next.add(taskId);
      return next;
    });
  }, []);

  const handleSeedSampleTasks = useCallback(async (): Promise<void> => {
    setIsSeeding(true);
    setSeedStatus(null);
    try {
      const primitiveSamples = [
        { type: TaskType.NORMAL, title: 'Run 5km' },
        { type: TaskType.NORMAL, title: 'Read 30 minutes' },
        { type: TaskType.NORMAL, title: 'Meditate' },
        { type: TaskType.NORMAL, title: 'Cook a homemade meal' },
        { type: TaskType.NORMAL, title: 'Call a friend' },
        { type: TaskType.NORMAL, title: 'Write in journal' },
        { type: TaskType.COUNTING, title: '', action: 'Read', unit: 'pages', maxCount: 50 },
        { type: TaskType.COUNTING, title: '', action: 'Walk', unit: 'km', maxCount: 10 },
        { type: TaskType.COUNTING, title: '', action: 'Drink', unit: 'glasses of water', maxCount: 8 },
        { type: TaskType.NORMAL, title: 'Try a new recipe' },
      ] as const;
      // Former Progress tasks become compound + isOrdered=true under the
      // unified model. Use createCompound with `autoCreate` children to
      // mirror the legacy progress-task seed shape.
      const compoundSamples = [
        {
          title: 'Weekly workout',
          steps: ['Monday run', 'Wednesday weights', 'Friday yoga'],
        },
        {
          title: 'Clean house',
          steps: ['Vacuum', 'Dust', 'Mop floors'],
        },
      ];
      for (const def of primitiveSamples) {
        await createTask(PLAYGROUND_USER_ID, def);
      }
      for (const def of compoundSamples) {
        await createCompound(PLAYGROUND_USER_ID, {
          title: def.title,
          operator: OperatorType.AND,
          isOrdered: true,
          children: def.steps.map((stepTitle) => ({
            autoCreate: { type: TaskType.NORMAL, title: stepTitle },
          })),
        });
      }
      setSeedStatus(
        `Seeded ${primitiveSamples.length + compoundSamples.length} sample tasks.`,
      );
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Unknown error';
      setSeedStatus(`Seed failed: ${msg}`);
    } finally {
      setIsSeeding(false);
    }
  }, []);

  return (
    <div className={styles.container}>
      {/* Harness controls — not part of the production component */}
      <div className={styles.harness}>
        <div className={styles.harnessRow}>
          <label className={styles.harnessLabel}>
            Tasks required
            <select
              className={styles.harnessSelect}
              value={tasksRequired}
              onChange={(e) => setTasksRequired(parseInt(e.target.value, 10))}
            >
              {REQUIRED_PRESETS.map((p) => (
                <option key={p.value} value={p.value}>
                  {p.label}
                </option>
              ))}
            </select>
          </label>

          <label className={styles.harnessLabel}>
            <input
              type="checkbox"
              checked={centerTaskMode}
              onChange={(e) => {
                const next = e.target.checked;
                setCenterTaskMode(next);
                if (!next) setCenterTaskId(null);
              }}
            />
            Center-task mode (CHOSEN)
          </label>

          <button
            type="button"
            className={styles.harnessButton}
            onClick={() => {
              setSelectedTaskIds(new Set());
              setCenterTaskId(null);
              setNavMessage(null);
            }}
          >
            Reset selection
          </button>

          <button
            type="button"
            className={styles.harnessButton}
            onClick={() => void handleSeedSampleTasks()}
            disabled={isSeeding}
          >
            {isSeeding ? 'Seeding…' : 'Seed sample library'}
          </button>
        </div>

        {seedStatus && <div className={styles.harnessNote}>{seedStatus}</div>}
        {navMessage && <div className={styles.harnessNote}>{navMessage}</div>}
      </div>

      {/* The production component being spiked */}
      <BoardWizardTasksStep
        library={library}
        selectedTaskIds={selectedTaskIds}
        onToggleSelection={handleToggle}
        tasksRequired={tasksRequired}
        // Playground simulates the default one-off behavior; the new
        // recurring/strict-exact flags are wizard-state-driven and
        // there's no harness state for them here.
        poolStrictExact={false}
        isRecurring={false}
        centerTaskMode={centerTaskMode}
        centerTaskId={centerTaskId}
        onCenterTaskChange={setCenterTaskId}
        userId={PLAYGROUND_USER_ID}
        // Playground-only seed: CUSTOM hides the new "From parent
        // boards" filter chip (it has no parent timeframes), keeping
        // the playground's existing behavior unchanged.
        currentTimeframe={Timeframe.CUSTOM}
        onTaskCreated={(task) => {
          setSelectedTaskIds((prev) => {
            const next = new Set(prev);
            next.add(task.id);
            return next;
          });
        }}
        onCompositeCreated={() => {
          // Composites can't be auto-selected (not boardable as a unit).
          // The library hook's live query will surface the new composite
          // automatically when the sheet closes.
        }}
        onBack={() => setNavMessage('« Back tapped (would return to Step 1: Setup)')}
        onNext={() =>
          setNavMessage('» Next tapped (would advance to Step 3: Preview & Activate)')
        }
      />
    </div>
  );
}
