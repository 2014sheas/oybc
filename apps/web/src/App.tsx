import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthProvider } from './firebase/AuthContext';
import { AuthGate } from './components/AuthGate';
import { TabBar } from './components/TabBar';
import { BoardsPage } from './pages/BoardsPage';
import { BoardPlayPage } from './pages/BoardPlayPage';
import { CreatePage } from './pages/CreatePage';
import { ProfilePage } from './pages/ProfilePage';
import { BoardPreferencesPage } from './pages/BoardPreferencesPage';
import { Playground } from './pages/Playground';
import {
  useSyncLoop,
  useLegacyPreferencesMigration,
  useAppliedTheme,
} from './hooks';

// ─── Authenticated Layout ─────────────────────────────────────────────────────

/**
 * Layout rendered when the user is signed in.
 *
 * Hosts the cross-cutting hooks that need an authenticated user:
 * - `useSyncLoop` — background push/pull of the local queue
 * - `useLegacyPreferencesMigration` — one-shot lift of pre-Phase-0 localStorage
 * - `useAppliedTheme` — resolves the user's theme preference to the DOM
 */
function AuthenticatedLayout(): React.ReactElement {
  useSyncLoop();
  useLegacyPreferencesMigration();
  useAppliedTheme();

  return (
    <>
      <div className="tabbar-content">
        <Routes>
          <Route path="/boards" element={<BoardsPage />} />
          <Route path="/boards/:id" element={<BoardPlayPage />} />
          <Route path="/create" element={<CreatePage />} />
          <Route path="/profile" element={<ProfilePage />} />
          <Route
            path="/profile/board-preferences"
            element={<BoardPreferencesPage />}
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
                <AuthenticatedLayout />
              </AuthGate>
            }
          />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  );
}

export default App;
