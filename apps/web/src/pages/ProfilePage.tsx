import { useCallback, useMemo, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useLiveQuery } from 'dexie-react-hooks';
import { useAuth } from '../firebase/useAuth';
import { updateDisplayName } from '../firebase/authService';
import { fetchUser } from '../db/operations';
import { incrementSharedCounter, undoLastCounterLog } from '../db/operations/tasks';
import { generateUUID } from '../db/utils';
import { useProfileHome, useTasks } from '../hooks';
import { RisoIcon, RisoButton, RisoSectionLabel } from '../components/riso';
import {
  attemptCounterWrite,
  CounterLogToast,
  CounterWriteError,
  CreateCounterSheet,
  COUNTER_NOT_UPDATED_MESSAGE,
  type CounterLoggedEvent,
} from '../components/counters';
import { formatLastLoggedLabel, type ProfileHomeCounterRow } from './profileHome';
import styles from './ProfilePage.module.css';

/**
 * ProfilePage — the new Profile home (Profile reorg PR2,
 * `design_handoff_profile_reorg/README.md` §Screens — Web `/profile`, frame
 * `#5a`; mobile collapse `#5c`; owner amendments in
 * `.superpowers/sdd/2026-09-30-profile-reorg/owner-decisions.md`).
 *
 * Layout, top to bottom:
 *   1. Identity header — avatar + name (inline "Edit name", unchanged logic)
 *      + email, with the PR1 Settings pill right-aligned.
 *   2. Three tiles — Board settings / Streak / Getting started. Getting
 *      started is a PLACEHOLDER on web (owner decision 1: no web tutorial;
 *      issue #528) — non-navigating, `aria-disabled`, "Coming soon".
 *   3. Shared counters — up to 2 counters, most recently logged first
 *      (`useProfileHome`), each with an inline "+ Log" that reuses the same
 *      write path (`incrementSharedCounter` / `attemptCounterWrite` /
 *      `CounterLogToast`) the Counters Hub's "+ Log" pill uses.
 *
 * Everything touched rarely (Theme, Account & security, Help & getting
 * started detail, Board renewals, Developer, Sign Out) lives behind the
 * Settings pill at `/profile/settings` (PR1).
 */
export function ProfilePage(): React.ReactElement {
  const { user, isAnonymous } = useAuth();
  const navigate = useNavigate();
  const [isEditingName, setIsEditingName] = useState(false);
  const [editNameValue, setEditNameValue] = useState('');
  const [nameError, setNameError] = useState<string | null>(null);
  const nameInputRef = useRef<HTMLInputElement>(null);
  // Track whether the edit was cancelled so onBlur doesn't save
  const cancelledRef = useRef(false);

  const saveName = useCallback(async (value: string) => {
    setNameError(null);
    try {
      await updateDisplayName(value);
    } catch (err) {
      setNameError(err instanceof Error ? err.message : 'Failed to update name');
    }
  }, []);

  // Read displayName reactively from the Dexie user row so edits show
  // immediately. `useAuth().user` only updates on sign-in/sign-out, not
  // on profile field writes — useLiveQuery fills that gap.
  //
  // When `liveUser` exists, always prefer its displayName (even if
  // undefined = cleared). Only fall back to the auth-context user while
  // the live query is still loading.
  const liveUser = useLiveQuery(
    () => (user?.id ? fetchUser(user.id) : undefined),
    [user?.id]
  );
  // Treat empty string as "no name" — we store '' in Dexie/Firestore
  // for cleared names (undefined gets silently dropped by both).
  const displayName = liveUser
    ? (liveUser.displayName || undefined)
    : (user?.displayName || undefined);

  const displayNameInitial = displayName?.trim().charAt(0).toUpperCase();
  const emailInitial = user?.email?.trim().charAt(0).toUpperCase();
  // Guests have no email (docs/GUEST_MODE.md) — fall back to "G" rather than
  // the generic "?" once a display name is also absent.
  const initial = displayNameInitial || (isAnonymous ? 'G' : emailInitial) || '?';

  const home = useProfileHome();
  const tasks = useTasks(user?.id) ?? [];

  const [createSheetOpen, setCreateSheetOpen] = useState(false);
  const [toast, setToast] = useState<(CounterLoggedEvent & { toastKey: string }) | null>(null);
  const [writeError, setWriteError] = useState<string | null>(null);
  // Frozen at mount, like `StreaksPage`'s `now` — the "logged X" label
  // doesn't need to re-anchor on every render.
  const now = useMemo(() => new Date(), []);

  function handleLogged(event: CounterLoggedEvent): void {
    setWriteError(null);
    setToast({ ...event, toastKey: generateUUID() });
  }

  async function handleUndo(): Promise<void> {
    if (!toast) return;
    const ok = await attemptCounterWrite('profile home undo', () => undoLastCounterLog(toast.counterId));
    setToast(null);
    setWriteError(ok ? null : COUNTER_NOT_UPDATED_MESSAGE);
  }

  function handleCounterCreated(counterId: string): void {
    setCreateSheetOpen(false);
    navigate(`/profile/counters/${counterId}`);
  }

  return (
    <div className={styles.container}>
      {/* Visually hidden landmark heading — the redesigned header shows the
          user's name, not a "Profile" title, but the page still needs an h1
          for assistive tech / the existing route-level e2e coverage. */}
      <h1 className={styles.srOnly}>Profile</h1>

      {/* ── Identity header ── */}
      <div className={styles.pageHeader}>
        <div className={styles.identityBlock}>
          {user?.photoURL ? (
            <img src={user.photoURL} alt="" className={styles.avatar} />
          ) : (
            <div className={styles.avatarPlaceholder}>{initial}</div>
          )}
          <div className={styles.identityInfo}>
            {isEditingName ? (
              <input
                ref={nameInputRef}
                type="text"
                className={styles.editNameInput}
                aria-label="Display name"
                value={editNameValue}
                onChange={(e) => setEditNameValue(e.target.value)}
                onBlur={() => {
                  if (cancelledRef.current) {
                    cancelledRef.current = false;
                    return;
                  }
                  void saveName(editNameValue);
                  setIsEditingName(false);
                }}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    cancelledRef.current = true;
                    void saveName(editNameValue);
                    setIsEditingName(false);
                  } else if (e.key === 'Escape') {
                    cancelledRef.current = true;
                    setIsEditingName(false);
                  }
                }}
                autoFocus
                maxLength={100}
              />
            ) : (
              <span className={styles.identityName}>{displayName ?? 'OYBC User'}</span>
            )}
            <div className={styles.identityMetaRow}>
              <span className={styles.accountEmail}>{isAnonymous ? 'Guest' : user?.email}</span>
              {!isEditingName && (
                <>
                  <span aria-hidden="true">&middot;</span>
                  <button
                    type="button"
                    className={styles.editNameLink}
                    onClick={() => {
                      setEditNameValue(displayName ?? '');
                      setIsEditingName(true);
                    }}
                  >
                    Edit name
                  </button>
                </>
              )}
            </div>
            {nameError && <span className={styles.nameError}>{nameError}</span>}
          </div>
        </div>

        <button
          type="button"
          className={styles.settingsButton}
          onClick={() => navigate('/profile/settings')}
          aria-label="Settings"
        >
          <RisoIcon name="sliders" size={16} />
          <span className={styles.settingsButtonLabel}>Settings</span>
        </button>
      </div>

      {/* ── Tiles ── */}
      <div className={styles.tilesRow}>
        <Link to="/profile/board-settings" className={styles.tile}>
          <div className={styles.tileTop}>
            <span className={`${styles.tileIconBox} ${styles.tileIconBlue}`} aria-hidden="true">
              <RisoIcon name="sliders" size={16} />
            </span>
            <span className={styles.tileArrow} aria-hidden="true">
              &rarr;
            </span>
          </div>
          <div className={styles.tileBody}>
            <h2 className={styles.tileTitle}>Board settings</h2>
            <p className={styles.tileCaption}>{home.boardSettings.defaultsLine}</p>
            <p className={styles.tileCaption}>{home.boardSettings.repeatingLine}</p>
          </div>
        </Link>

        <Link
          to="/profile/streaks"
          className={`${styles.tile} ${home.streak.isEmpty ? styles.tileDashedEmpty : styles.tileGold}`}
        >
          {home.streak.isEmpty ? (
            <>
              <div className={styles.tileTop}>
                <span className={`${styles.tileIconBox} ${styles.tileIconOutline}`} aria-hidden="true">
                  <RisoIcon name="flame" size={16} />
                </span>
              </div>
              <div className={styles.tileBody}>
                <h2 className={`${styles.tileTitle} ${styles.tileTitleMuted}`}>No streak yet</h2>
                <p className={styles.tileCaption}>Clear a board to start one.</p>
              </div>
            </>
          ) : (
            <>
              <div className={styles.tileTop}>
                <span className={`${styles.tileIconBox} ${styles.tileIconRed}`} aria-hidden="true">
                  <RisoIcon name="flame" size={16} />
                </span>
                <span className={styles.tileArrow} aria-hidden="true">
                  &rarr;
                </span>
              </div>
              <div className={styles.tileBody}>
                <div className={styles.streakHeadline}>
                  <span className={styles.streakNumber}>{home.streak.currentBingoStreak}</span>
                  <span className={styles.streakUnit}>day streak</span>
                </div>
                <p className={styles.tileCaption}>
                  Longest {home.streak.longestGreenlogStreak} &middot; {home.streak.greenlogCount}{' '}
                  GREENLOGs
                </p>
              </div>
            </>
          )}
        </Link>

        {/* Getting started — PLACEHOLDER on web (owner decision 1: no web
            tutorial). Non-navigating, aria-disabled; tracked pre-release
            gap, issue #528. */}
        <div
          className={`${styles.tile} ${styles.tileGettingStarted} ${styles.tilePlaceholder}`}
          aria-disabled="true"
        >
          <div className={styles.tileTop}>
            <span className={`${styles.tileIconBox} ${styles.tileIconGreen}`} aria-hidden="true">
              <RisoIcon name="check" size={16} />
            </span>
          </div>
          <div className={styles.tileBody}>
            <h2 className={styles.tileTitle}>Getting started</h2>
            <p className={styles.tileCaption}>Coming soon</p>
          </div>
        </div>
      </div>

      {/* ── Shared counters ── */}
      <div className={styles.countersHeader}>
        <RisoSectionLabel>Shared counters</RisoSectionLabel>
        {home.totalCounterCount > 0 && (
          <Link to="/profile/counters" className={styles.countersAllLink}>
            All {home.totalCounterCount} &rarr;
          </Link>
        )}
      </div>

      <CounterWriteError message={writeError} />

      {home.recentCounters.length === 0 ? (
        <div className={styles.countersEmpty}>
          <div className={styles.countersEmptySquares} aria-hidden="true">
            <span className={styles.emptySquarePaper} />
            <span className={styles.emptySquareBlue} />
            <span className={styles.emptySquarePaper} />
          </div>
          <h2 className={styles.countersEmptyTitle}>One tally, many squares</h2>
          <p className={styles.countersEmptyBody}>
            A counter tracks one activity across every board that counts it. Log once, all of them
            move.
          </p>
          <RisoButton kind="blue" size="small" onClick={() => setCreateSheetOpen(true)}>
            New counter
          </RisoButton>
        </div>
      ) : (
        <div className={styles.countersCard} role="list" aria-label="Shared counters">
          {home.recentCounters.map((row) => (
            <ProfileCounterRow
              key={row.group.counterId}
              row={row}
              now={now}
              onLogged={handleLogged}
              onLogFailed={() => setWriteError(COUNTER_NOT_UPDATED_MESSAGE)}
            />
          ))}
        </div>
      )}

      {user?.id && (
        <CreateCounterSheet
          open={createSheetOpen}
          onClose={() => setCreateSheetOpen(false)}
          tasks={tasks}
          userId={user.id}
          onCreated={handleCounterCreated}
        />
      )}

      {toast && (
        <CounterLogToast
          key={toast.toastKey}
          amount={toast.amount}
          unit={toast.unit}
          verb="logged"
          onUndo={() => void handleUndo()}
          onDone={() => setToast(null)}
        />
      )}
    </div>
  );
}

/**
 * One row in the Shared counters card: name + meta, the most-recently-logged
 * member's progress, the all-time total, and a "+ Log" button that reuses
 * the Counters Hub's exact write path (`incrementSharedCounter` via
 * `attemptCounterWrite`, default amount `group.defaultLogAmount ?? 1`).
 */
function ProfileCounterRow({
  row,
  now,
  onLogged,
  onLogFailed,
}: {
  row: ProfileHomeCounterRow;
  now: Date;
  onLogged: (event: CounterLoggedEvent) => void;
  onLogFailed: () => void;
}): React.ReactElement {
  const { group, member } = row;
  const [isLogging, setIsLogging] = useState(false);
  const logAmount = group.defaultLogAmount ?? 1;

  async function handleLog(): Promise<void> {
    if (isLogging) return;
    setIsLogging(true);
    try {
      const ok = await attemptCounterWrite('profile home log', () =>
        incrementSharedCounter(group.counterId, logAmount),
      );
      if (ok) {
        onLogged({ counterId: group.counterId, amount: logAmount, unit: group.unit ?? '' });
      } else {
        onLogFailed();
      }
    } finally {
      setIsLogging(false);
    }
  }

  const pct = member && member.goal > 0 ? Math.min(100, (member.logged / member.goal) * 100) : 0;

  return (
    <div className={styles.counterRow} role="listitem">
      <div className={styles.counterRowName}>
        <span className={styles.counterName}>{group.name}</span>
        <span className={styles.counterMeta}>
          {group.taskCount} task{group.taskCount === 1 ? '' : 's'} &middot; {group.boardCount} board
          {group.boardCount === 1 ? '' : 's'} &middot; logged {formatLastLoggedLabel(row.lastLoggedAt, now)}
        </span>
      </div>

      <div className={styles.counterRowMember}>
        {member && (
          <>
            <div className={styles.counterMemberTop}>
              <span className={styles.counterMemberLabel}>{member.boardName ?? group.name}</span>
              <span className={styles.counterMemberValue}>
                {member.logged.toLocaleString()}
                <span className={styles.counterMemberGoal}>/{member.goal.toLocaleString()}</span>
              </span>
            </div>
            <div className={styles.counterMemberBarWrap}>
              <div className={styles.counterMemberBarFill} style={{ width: `${pct}%` }} />
            </div>
          </>
        )}
      </div>

      <div className={styles.counterRowTotal}>
        <span className={styles.counterTotalNum}>{group.lifetime.toLocaleString()}</span>
        <span className={styles.counterTotalLabel}>ALL-TIME</span>
      </div>

      <RisoButton
        kind="blue"
        size="small"
        onClick={() => void handleLog()}
        disabled={isLogging}
        aria-label={`Log ${logAmount} ${group.unit ?? ''} for ${group.name}`}
      >
        + Log
      </RisoButton>
    </div>
  );
}
