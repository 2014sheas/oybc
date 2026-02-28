import { useState } from 'react';
import { db } from '../db';
import { BingoSquare } from '../components/BingoSquare';
import { BingoBoard } from '../components/BingoBoard';
import { UnifiedTaskCreatorPlayground } from '../components/playground/UnifiedTaskCreatorPlayground';
import { BoardGeneratorPlayground } from '../components/playground/BoardGeneratorPlayground';
import { generateTaskNames } from '../components/playground/playgroundUtils';
import { CenterSquareType } from '@oybc/shared';
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
      id: 'board-generator',
      title: 'Board Generator',
      content: <BoardGeneratorPlayground />,
    },
    {
      id: 'unified-task-creator',
      title: 'Task Creation (Unified)',
      content: (
        <div>
          <p style={{ color: 'var(--text-secondary)', marginBottom: '1rem' }}>
            Unified task creator supporting Normal, Counting, and Progress types.
            Select a type, fill in the shared and type-specific fields, then submit
            to store in the local Dexie database. The Task Library below reactively
            shows all created tasks with type filtering.
          </p>
          <UnifiedTaskCreatorPlayground />
        </div>
      ),
    },
    {
      id: 'center-space-free',
      title: 'Center Space: True Free Space (5x5)',
      content: (
        <div>
          <p style={{ color: 'var(--text-secondary)', marginBottom: '1rem' }}>
            Center is auto-completed, shows "FREE SPACE", locked (cannot toggle off), counts toward bingo.
          </p>
          <BingoBoard taskNames={generateTaskNames(25)} gridSize={5} centerSquareType={CenterSquareType.FREE} />
        </div>
      ),
    },
    {
      id: 'center-space-custom-free',
      title: 'Center Space: Customizable Free Space (5x5)',
      content: (
        <div>
          <p style={{ color: 'var(--text-secondary)', marginBottom: '1rem' }}>
            Center is auto-completed with custom text, locked, counts toward bingo.
          </p>
          <BingoBoard taskNames={generateTaskNames(25)} gridSize={5} centerSquareType={CenterSquareType.CUSTOM_FREE} centerSquareCustomName="My Goal!" />
        </div>
      ),
    },
    {
      id: 'center-space-chosen',
      title: 'Center Space: User-Chosen Center (5x5)',
      content: (
        <div>
          <p style={{ color: 'var(--text-secondary)', marginBottom: '1rem' }}>
            Center has a fixed task (e.g., "My Special Task"), NOT auto-completed, can toggle like any square.
          </p>
          <BingoBoard taskNames={generateTaskNames(25)} gridSize={5} centerSquareType={CenterSquareType.CHOSEN} />
        </div>
      ),
    },
    {
      id: 'center-space-none',
      title: 'Center Space: No Center Space (5x5)',
      content: (
        <div>
          <p style={{ color: 'var(--text-secondary)', marginBottom: '1rem' }}>
            Center is an ordinary square, no special treatment.
          </p>
          <BingoBoard taskNames={generateTaskNames(25)} gridSize={5} centerSquareType={CenterSquareType.NONE} />
        </div>
      ),
    },
    {
      id: 'center-space-3x3',
      title: 'Center Space: Works on 3x3 Too!',
      content: (
        <div>
          <p style={{ color: 'var(--text-secondary)', marginBottom: '1rem' }}>
            True Free Space works on smaller odd-sized boards (center is index 4 on 3x3).
          </p>
          <BingoBoard taskNames={generateTaskNames(9)} gridSize={3} squareSize={90} centerSquareType={CenterSquareType.FREE} />
        </div>
      ),
    },
    {
      id: 'bingo-square',
      title: 'Bingo Square',
      content: (
        <div>
          <p style={{ color: 'var(--text-secondary)', marginBottom: '1rem' }}>
            A single bingo board square that toggles between incomplete and completed states.
            Click or use keyboard (Space/Enter) to toggle.
          </p>
          <div style={{ display: 'flex', gap: '1rem', flexWrap: 'wrap', alignItems: 'flex-start' }}>
            <div style={{ textAlign: 'center' }}>
              <BingoSquare />
              <p style={{ fontSize: '0.85rem', color: 'var(--text-secondary)', marginTop: '0.5rem' }}>
                Default (100px)
              </p>
            </div>
            <div style={{ textAlign: 'center' }}>
              <BingoSquare size={150} />
              <p style={{ fontSize: '0.85rem', color: 'var(--text-secondary)', marginTop: '0.5rem' }}>
                Large (150px)
              </p>
            </div>
            <div style={{ textAlign: 'center' }}>
              <BingoSquare initialCompleted />
              <p style={{ fontSize: '0.85rem', color: 'var(--text-secondary)', marginTop: '0.5rem' }}>
                Initially Completed
              </p>
            </div>
          </div>
        </div>
      ),
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
