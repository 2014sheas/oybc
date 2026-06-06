import { useState } from 'react';
import { db } from '../db';
import { UnifiedTaskCreatorPlayground } from '../components/playground/UnifiedTaskCreatorPlayground';
import { BoardGeneratorPlayground } from '../components/playground/BoardGeneratorPlayground';
import { TaskSquareActionsPlayground } from '../components/playground/TaskSquareActionsPlayground';
import { SubtaskDerivationPlayground } from '../components/playground/SubtaskDerivationPlayground';
import { CrossBoardRollupPlayground } from '../components/playground/CrossBoardRollupPlayground';
import { BoardWizardTasksPlayground } from '../components/playground/BoardWizardTasksPlayground';
import { CreateHubPlayground } from '../components/playground/CreateHubPlayground';
import { BoardLifecyclePlayground } from '../components/playground/BoardLifecyclePlayground';
import { SharedCounterPlayground } from '../components/playground/SharedCounterPlayground';
import { SyncSimulationPlayground } from '../components/playground/SyncSimulationPlayground';
import styles from './Playground.module.css';

/**
 * Feature item structure for collapsible sections
 */
interface Feature {
  id: string;
  title: string;
  content: React.ReactNode;
}

/**
 * Playground Page Component
 *
 * A dedicated space for testing new features before integrating them into the main app.
 * Features are displayed in collapsible sections and persist across sessions.
 * Includes functionality to clear test data from the database.
 */
export function Playground() {
  const [expandedFeatures, setExpandedFeatures] = useState<Set<string>>(new Set());
  const [clearStatus, setClearStatus] = useState<{
    type: 'success' | 'error' | null;
    message: string;
  }>({ type: null, message: '' });

  // Features under test - new features will be added here (newest first)
  const features: Feature[] = [
    {
      id: 'shared-counter',
      title: 'Shared Counters — Phase 1 spike (deriveDisplayedCount)',
      content: <SharedCounterPlayground />,
    },
    {
      id: 'create-hub',
      title: 'Create Hub — full flow (hub + wizard)',
      content: <CreateHubPlayground />,
    },
    {
      id: 'board-wizard-tasks',
      title: 'Board Wizard — Tasks Step (spike)',
      content: <BoardWizardTasksPlayground />,
    },
    {
      id: 'sync-simulation',
      title: 'Sync & Authentication',
      content: <SyncSimulationPlayground />,
    },
    {
      id: 'board-lifecycle',
      title: 'Board Lifecycle',
      content: <BoardLifecyclePlayground />,
    },
    {
      id: 'cross-board-rollup',
      title: 'Cross-Board Progress Rollup',
      content: <CrossBoardRollupPlayground />,
    },
    {
      id: 'subtask-derivation',
      title: 'Subtask Derivation Engine',
      content: <SubtaskDerivationPlayground />,
    },
    {
      id: 'task-square-actions',
      title: 'Task Square Interactions',
      content: <TaskSquareActionsPlayground />,
    },
    {
      id: 'board-generator',
      title: 'Board Generator',
      content: <BoardGeneratorPlayground />,
    },
    {
      id: 'unified-task-creator',
      title: 'Task Creation (Unified)',
      content: <UnifiedTaskCreatorPlayground />,
    },
  ];

  /**
   * Toggle a feature's expanded/collapsed state
   */
  const toggleFeature = (featureId: string) => {
    setExpandedFeatures((prev) => {
      const newSet = new Set(prev);
      if (newSet.has(featureId)) {
        newSet.delete(featureId);
      } else {
        newSet.add(featureId);
      }
      return newSet;
    });
  };

  /**
   * Clear all test data from the database
   *
   * This removes all records from all tables, useful for resetting
   * the Playground to a clean state during testing.
   */
  const handleClearTestData = async () => {
    try {
      setClearStatus({ type: null, message: '' });

      // Clear all tables in the database
      await db.transaction('rw', db.tables, async () => {
        await Promise.all(db.tables.map((table) => table.clear()));
      });

      setClearStatus({
        type: 'success',
        message: '✅ Test data cleared successfully',
      });

      console.log('✅ All test data cleared from database');

      // Clear status message after 3 seconds
      setTimeout(() => {
        setClearStatus({ type: null, message: '' });
      }, 3000);
    } catch (error) {
      const errorMessage =
        error instanceof Error ? error.message : 'Unknown error occurred';
      setClearStatus({
        type: 'error',
        message: `❌ Error clearing data: ${errorMessage}`,
      });
      console.error('❌ Error clearing test data:', error);
    }
  };

  return (
    <div className={styles.container}>
      {/* Header */}
      <div className={styles.header}>
        <h1 className={styles.title}>Feature Playground</h1>
        <p className={styles.description}>
          This is a dedicated space for testing new features before integrating them
          into the main application. Each feature is isolated in its own section below.
          Test data is stored in the real database but can be cleared at any time using
          the button below.
        </p>
      </div>

      {/* Actions */}
      <div className={styles.actions}>
        <button
          className={styles.clearButton}
          onClick={handleClearTestData}
          disabled={clearStatus.type !== null}
        >
          Clear Test Data
        </button>
      </div>

      {/* Status message */}
      {clearStatus.type && (
        <div className={`${styles.statusMessage} ${styles[clearStatus.type]}`}>
          {clearStatus.message}
        </div>
      )}

      {/* Features Under Test */}
      <div className={styles.featuresSection}>
        <h2 className={styles.sectionTitle}>Features Under Test</h2>

        <div className={styles.featuresList}>
          {features.length === 0 ? (
            <>
              <p style={{ color: 'var(--text-secondary)', fontStyle: 'italic' }}>
                No features currently under test. Features will be added here as they are
                developed.
              </p>
              <button>Test Button</button>
            </>
          ) : (
            features.map((feature) => (
              <div key={feature.id} className={styles.featureItem}>
                {/* Collapsible header */}
                <div
                  className={styles.featureHeader}
                  onClick={() => toggleFeature(feature.id)}
                >
                  <h3 className={styles.featureTitle}>{feature.title}</h3>
                  <span
                    className={`${styles.expandIcon} ${
                      expandedFeatures.has(feature.id) ? styles.expanded : ''
                    }`}
                  >
                    ▼
                  </span>
                </div>

                {/* Feature content (shown when expanded) */}
                {expandedFeatures.has(feature.id) && (
                  <div className={styles.featureContent}>{feature.content}</div>
                )}
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}
