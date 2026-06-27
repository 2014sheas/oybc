import { BrowserRouter, Routes, Route, Navigate, useNavigate } from 'react-router-dom';
import { AuthProvider } from './firebase/AuthContext';
import { AuthGate } from './components/AuthGate';
import { AppShell } from './components/appShell/AppShell';
import { HomePage } from './pages/HomePage';
import { BoardsPage } from './pages/BoardsPage';
import { BoardPlayPage } from './pages/BoardPlayPage';
import { CreateHubPage } from './pages/CreateHubPage';
import { TasksPage } from './pages/TasksPage';
import { TaskDetailPage } from './pages/TaskDetailPage';
import { ProfilePage } from './pages/ProfilePage';
import { AccountSecurityPage } from './pages/AccountSecurityPage';
import { BoardPreferencesPage } from './pages/BoardPreferencesPage';
import { RecurringTemplatesPage } from './pages/RecurringTemplatesPage';
import { DefaultPoolsListPage } from './pages/DefaultPoolsListPage';
import { DefaultPoolEditorPage } from './pages/DefaultPoolEditorPage';
import { CoreBoardBrowserPage } from './pages/core-board-browser/CoreBoardBrowserPage';
import { CoreBoardWindowPage } from './pages/core-board-browser/CoreBoardWindowPage';
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
      onTemplateCompleted={() => {
        // Phase 6.2: recurring-template completions without a spawned
        // board (skip OR edit) land on the templates list so the user
        // sees their newly-saved/edited template (with attention badge
        // on skip). The earlier contract overloaded `onBoardCompleted`
        // with templateId, navigating to /boards/<templateId> = 404.
        navigate('/profile/recurring-templates');
      }}
    />
  );
}

// ─── Tasks tab route wrapper ──────────────────────────────────────────────────

/**
 * Route-level wrapper that hands the authenticated user id to
 * `TasksPage`. Mirrors `CreateRoute`'s shape: defers rendering until
 * auth resolves so we don't briefly mount the page against an
 * undefined user.
 */
function TasksRoute(): React.ReactElement | null {
  const { user } = useAuth();
  if (!user?.id) return null;
  return <TasksPage userId={user.id} />;
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
  // Single owner of theme resolution + the `data-theme` side effect; the
  // resolved value is threaded to the nav so it doesn't re-subscribe.
  const appliedTheme = useAppliedTheme();

  return (
    <AppShell appliedTheme={appliedTheme}>
      <Routes>
        <Route path="/home" element={<HomePage />} />
        <Route path="/boards" element={<BoardsPage />} />
        <Route path="/boards/core/:timeframe" element={<CoreBoardBrowserPage />} />
        <Route path="/boards/core/:timeframe/:date" element={<CoreBoardWindowPage />} />
        <Route path="/boards/:id" element={<BoardPlayPage />} />
        <Route path="/create" element={<CreateRoute />} />
        <Route path="/tasks" element={<TasksRoute />} />
        <Route path="/tasks/:id" element={<TaskDetailPage />} />
        <Route path="/profile" element={<ProfilePage />} />
        <Route path="/profile/board-preferences" element={<BoardPreferencesPage />} />
        <Route path="/profile/recurring-templates" element={<RecurringTemplatesPage />} />
        <Route path="/profile/default-pools" element={<DefaultPoolsListPage />} />
        <Route path="/profile/default-pools/:timeframe" element={<DefaultPoolEditorPage />} />
        <Route path="/profile/account-security" element={<AccountSecurityPage />} />
        <Route path="/" element={<Navigate to="/home" replace />} />
        <Route path="*" element={<Navigate to="/home" replace />} />
      </Routes>
    </AppShell>
  );
}

// ─── App ──────────────────────────────────────────────────────────────────────

/**
 * Root app component.
 *
 * - Playground is accessible without auth (dev tool)
 * - All other routes require authentication via AuthGate
 * - The Riso `AppShell` provides the top nav (→ mobile bottom tab bar):
 *   Home · Boards · Tasks · You, plus New board + avatar
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
