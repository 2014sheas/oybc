import { useEffect, useState } from 'react';
import { db } from '../db';
import styles from './Home.module.css';

/**
 * Home Page Component
 *
 * Displays "Hello OYBC" message and verifies database connection.
 * This is the main landing page for the OYBC web app.
 */
export function Home() {
  const [dbConnected, setDbConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    // Verify database connection
    const testDatabase = async () => {
      try {
        // Try to open the database
        await db.open();
        setDbConnected(true);
        console.log('✅ Dexie database connected successfully');
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Unknown error');
        console.error('❌ Database connection failed:', err);
      }
    };

    testDatabase();
  }, []);

  return (
    <div className={styles.container}>
      <h1 className={styles.title}>Hello OYBC</h1>

      <p className={styles.subtitle}>On Your Bingo Card - Web App</p>

      <div
        className={`${styles.statusCard} ${
          dbConnected ? styles.connected : error ? styles.error : styles.loading
        }`}
      >
        <strong>Database Status:</strong>{' '}
        {dbConnected ? '✅ Connected' : error ? `❌ Error: ${error}` : '⏳ Connecting...'}
      </div>

      <div className={styles.infoCard}>
        <p>
          <strong>Phase 1.5:</strong> Working App Infrastructure 🚧
        </p>
        <p>
          This is a minimal working web app. Phase 2 will add the actual game UI.
        </p>
      </div>
    </div>
  );
}
