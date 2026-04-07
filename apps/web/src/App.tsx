import { useEffect, useState } from 'react';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthProvider } from './firebase/AuthContext';
import { AuthGate } from './components/AuthGate';
import { TabBar } from './components/TabBar';
import { BoardsPage } from './pages/BoardsPage';
import { CreatePage } from './pages/CreatePage';
import { ProfilePage } from './pages/ProfilePage';
import { Playground } from './pages/Playground';
import { useSyncLoop } from './hooks';

// ─── Types ────────────────────────────────────────────────────────────────────

type Theme = 'light' | 'dark';

const THEME_STORAGE_KEY = 'oybc-theme';

// ─── Authenticated Layout ─────────────────────────────────────────────────────

/**
 * Layout rendered when the user is signed in.
 * Provides tab bar navigation and starts the background sync loop.
 */
function AuthenticatedLayout({
  theme,
  onThemeToggle,
}: {
  theme: Theme;
  onThemeToggle: () => void;
}): React.ReactElement {
  useSyncLoop();

  return (
    <>
      <div className="tabbar-content">
        <Routes>
          <Route path="/boards" element={<BoardsPage />} />
          {/* <Route path="/boards/:id" element={<BoardPlayPage />} /> -- Phase 3 */}
          <Route path="/create" element={<CreatePage />} />
          <Route
            path="/profile"
            element={<ProfilePage theme={theme} onThemeToggle={onThemeToggle} />}
          />
          <Route path="/" element={<Navigate to="/boards" replace />} />
          <Route path="*" element={<Navigate to="/boards" replace />} />
        </Routes>
      </div>
      <TabBar />
    </>
  );
}

// ─── App ──────────────────────────────────────────────────────────────────────

/**
 * Root app component.
 *
 * - Playground is accessible without auth (dev tool)
 * - All other routes require authentication via AuthGate
 * - Tab bar provides navigation between Boards, Create, and Profile
 */
function App() {
  const [theme, setTheme] = useState<Theme>(() => {
    const savedTheme = localStorage.getItem(THEME_STORAGE_KEY);
    return (savedTheme === 'dark' ? 'dark' : 'light') as Theme;
  });

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem(THEME_STORAGE_KEY, theme);
  }, [theme]);

  const toggleTheme = () => {
    setTheme((prev) => (prev === 'light' ? 'dark' : 'light'));
  };

  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          {/* Public route — playground accessible without auth */}
          <Route path="/playground" element={<Playground />} />

          {/* Protected routes — auth required */}
          <Route
            path="/*"
            element={
              <AuthGate>
                <AuthenticatedLayout
                  theme={theme}
                  onThemeToggle={toggleTheme}
                />
              </AuthGate>
            }
          />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  );
}

export default App;
