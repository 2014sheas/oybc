import { useEffect, useState } from 'react';
import { db } from './db';

/**
 * Main App Component
 *
 * This is the root component for the OYBC web app.
 * Currently shows a simple "Hello OYBC" message and verifies database connection.
 */
function App() {
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
    <div style={{
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      justifyContent: 'center',
      minHeight: '100vh',
      padding: '20px',
      textAlign: 'center'
    }}>
      <h1 style={{ fontSize: '3rem', marginBottom: '1rem', color: '#333' }}>
        Hello OYBC
      </h1>

      <p style={{ fontSize: '1.2rem', color: '#666', marginBottom: '2rem' }}>
        On Your Bingo Card - Web App
      </p>

      <div style={{
        padding: '1rem',
        borderRadius: '8px',
        backgroundColor: dbConnected ? '#d4edda' : error ? '#f8d7da' : '#fff3cd',
        color: dbConnected ? '#155724' : error ? '#721c24' : '#856404',
        border: `1px solid ${dbConnected ? '#c3e6cb' : error ? '#f5c6cb' : '#ffeeba'}`,
        maxWidth: '500px'
      }}>
        <strong>Database Status:</strong>{' '}
        {dbConnected ? '✅ Connected' : error ? `❌ Error: ${error}` : '⏳ Connecting...'}
      </div>

      <div style={{
        marginTop: '2rem',
        padding: '1rem',
        backgroundColor: '#e7f3ff',
        borderRadius: '8px',
        maxWidth: '600px'
      }}>
        <p style={{ fontSize: '0.9rem', color: '#0056b3' }}>
          <strong>Phase 1.5:</strong> Working App Infrastructure 🚧
        </p>
        <p style={{ fontSize: '0.8rem', color: '#666', marginTop: '0.5rem' }}>
          This is a minimal working web app. Phase 2 will add the actual game UI.
        </p>
      </div>
    </div>
  );
}

export default App;
