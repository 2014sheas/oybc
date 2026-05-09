import { BrowserRouter, Routes, Route, Navigate, useNavigate } from 'react-router-dom';
import { AuthProvider } from './firebase/AuthContext';
import { AuthGate } from './components/AuthGate';
import { TabBar } from './components/TabBar';
import { BoardsPage } from './pages/BoardsPage';
import { BoardPlayPage } from './pages/BoardPlayPage';
import { CreateHubPage } from './pages/CreateHubPage';
import { ProfilePage } from './pages/ProfilePage';
import { BoardPreferencesPage } from './pages/BoardPreferencesPage';
import { RecurringTemplatesPage } from './pages/RecurringTemplatesPage';
import { Playground } from './pages/Playground';
import { useAuth } from './firebase/useAuth';
import {
  useSyncLoop,
  useLegacyPreferencesMigration,
  useAppliedTheme,
  usePreferences,
} from './hooks';

// ─── Create tab route wrapper ─────────────────────────────────────────────────

/**
 * Route-level wrapper that pulls the authenticated user id and
 * synced preferences out of the auth / preferences hooks and hands
 * them to `CreateHubPage` as props. `CreateHubPage` itself stays
 * pure so it remains easy to mount from the playground with test
 * values.
 */
function CreateRoute(): React.ReactElement | null {
  const { user } = useAuth();
  const [preferences, , preferencesReady] = usePreferences();
  const navigate = useNavigate();

  // Defer rendering until both auth and preferences have resolved —
  // mounting the hub with placeholder preferences would seed the
  // wizard's defaults with the wrong values and flicker on first
  // paint when the live values arrive.
  if (!user?.id || !preferencesReady) return null;

  return (
    <CreateHubPage
      userId={user.id}
      preferences={preferences}
      onBoardCompleted={(boardId) => {
        navigate(`/boards/${boardId}`);
      }}
    />
  );
}

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
          <Route path="/create" element={<CreateRoute />} />
          <Route path="/profile" element={<ProfilePage />} />
          <Route
            path="/profile/board-preferences"
            element={<BoardPreferencesPage />}
          />
          <Route
            path="/profile/recurring-templates"
            element={<RecurringTemplatesPage />}
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
