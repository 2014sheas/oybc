import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { counterMilestoneProgress } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { useSharedCounterGroups } from '../hooks/useSharedCounterGroups';
import { useCounterDailyTotals } from '../hooks/useCounterDailyTotals';
import {
  computeTaskDeletionImpact,
  decrementSharedCounter,
  deleteCounterWithUnlink,
  incrementSharedCounter,
  setCounterDefaultLogAmount,
  undoLastCounterLog,
  type TaskDeletionImpact,
} from '../db/operations/tasks';
import { generateUUID } from '../db/utils';
import { CounterDeleteConfirmDialog, CounterDetailTaskCard, CounterLogToast } from '../components/counters';
import { buildAmountChipOptions, parseCustomLogAmount } from '../components/counters/amountChips';
import { RowContextMenu } from '../components/wizard/RowContextMenu';
import { RisoSectionLabel } from '../components/riso';
import profileStyles from './ProfilePage.module.css';
import styles from './CounterDetailPage.module.css';

// ─── CounterDetailPage ────────────────────────────────────────────────────────

/**
 * CounterDetailPage — single shared counter's home.
 *
 * Route: /profile/counters/:counterId
 *
 * Sections (R2 Counters UX refresh — design handoff §Counter Detail):
 *   1. Header — back circle · blue "SHARED COUNTER" kicker · counter name ·
 *      "⋯" overflow (Delete counter…).
 *   2. Hero card — 46px blue all-time total + "all-time {noun}", a REAL
 *      7-day sparkline (`useCounterDailyTotals`), and the milestone bar
 *      (`counterMilestoneProgress` from `@oybc/shared`).
 *   3. Stat strip — Today (REAL) / Streak (STUB) / Best week (STUB).
 *   4. Log card (blue fill) — amount chips (1 / default / 25 / #) + −/+Add N.
 *      Logging updates the counter's `defaultLogAmount` to the amount just
 *      used and shows the reusable `CounterLogToast` ("Logged +N · Undo").
 *   5. Explainer line.
 *   6. "Counting on N tasks" — active member cards.
 *   7. "Recent weeks" — STUB history card.
 *   8. "Not counting now" — inactive/draft/unplaced members (kept from P1;
 *      not in the mock's example state because its sample counter has none).
 *   9. Delete — quiet red text link (was a filled RisoButton).
 *
 * Desktop (≥900px): 360px sticky left rail (hero + stats + log + explainer)
 * and a right column (task cards 2-up, history, delete link).
 *
 * Mirrors iOS `CounterDetailView.swift`.
 */
export function CounterDetailPage(): React.ReactElement {
  const { counterId } = useParams<{ counterId: string }>();
  const navigate = useNavigate();
  const { user } = useAuth();
  const groups = useSharedCounterGroups(user?.id);
  const dailyTotals = useCounterDailyTotals(counterId);

  const [isLogging, setIsLogging] = useState(false);
  const [selectedAmount, setSelectedAmount] = useState(1);
  const [isCustomActive, setIsCustomActive] = useState(false);
  const [customOpen, setCustomOpen] = useState(false);
  const [customDraft, setCustomDraft] = useState('');
  const [toast, setToast] = useState<
    { amount: number; unit: string; verb: 'logged' | 'removed'; toastKey: string } | null
  >(null);

  const overflowBtnRef = useRef<HTMLButtonElement>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const [menuPos, setMenuPos] = useState<{ x: number; y: number } | null>(null);

  // Delete-counter (P5 decision 8: deleteCounterWithUnlink) UI state.
  const [deleteImpact, setDeleteImpact] = useState<TaskDeletionImpact | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [deleteError, setDeleteError] = useState<string | null>(null);

  const group = groups.find((g) => g.counterId === counterId);

  // Sync the selected chip amount to the counter's current default exactly
  // once per counter (on first load / on navigating to a different counter)
  // — NOT on every live update, or a background defaultLogAmount write from
  // this very session's own log would clobber the user's in-progress chip
  // selection.
  const initializedForRef = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (!group || !counterId) return;
    if (initializedForRef.current === counterId) return;
    initializedForRef.current = counterId;
    setSelectedAmount(group.defaultLogAmount ?? 1);
    setIsCustomActive(false);
    setCustomOpen(false);
    setCustomDraft('');
  }, [group, counterId]);

  const handleLog = useCallback(
    async (direction: 'add' | 'remove') => {
      if (!counterId || isLogging || selectedAmount <= 0) return;
      setIsLogging(true);
      try {
        if (direction === 'add') {
          await incrementSharedCounter(counterId, selectedAmount);
        } else {
          // decrementSharedCounter clamps to 0 itself — no additional guard needed.
          await decrementSharedCounter(counterId, selectedAmount);
        }
        // The amount just used becomes the new default (no-op if unchanged).
        await setCounterDefaultLogAmount(counterId, selectedAmount);
        setToast({
          amount: selectedAmount,
          unit: group?.unit ?? '',
          verb: direction === 'add' ? 'logged' : 'removed',
          toastKey: generateUUID(),
        });
      } finally {
        setIsLogging(false);
      }
    },
    [counterId, isLogging, selectedAmount, group?.unit],
  );

  const handleUndo = useCallback(async () => {
    if (!counterId) return;
    await undoLastCounterLog(counterId);
    setToast(null);
  }, [counterId]);

  function selectChip(value: number): void {
    setSelectedAmount(value);
    setIsCustomActive(false);
    setCustomOpen(false);
  }

  function openCustomInput(): void {
    setCustomDraft(isCustomActive ? String(selectedAmount) : '');
    setCustomOpen(true);
  }

  function confirmCustomInput(): void {
    const parsed = parseCustomLogAmount(customDraft);
    if (parsed == null) return;
    setSelectedAmount(parsed);
    setIsCustomActive(true);
    setCustomOpen(false);
  }

  function openOverflowMenu(): void {
    const rect = overflowBtnRef.current?.getBoundingClientRect();
    if (!rect) return;
    setMenuPos({ x: rect.right - 190, y: rect.bottom + 6 });
    setMenuOpen(true);
  }

  const handleDeleteClick = useCallback(async () => {
    if (!counterId) return;
    setDeleteError(null);
    try {
      const impact = await computeTaskDeletionImpact(counterId);
      setDeleteImpact(impact);
    } catch {
      setDeleteError('Failed to delete counter.');
    }
  }, [counterId]);

  const handleConfirmDelete = useCallback(async () => {
    if (!counterId || isDeleting) return;
    setIsDeleting(true);
    setDeleteError(null);
    try {
      await deleteCounterWithUnlink(counterId);
      navigate('/profile/counters');
    } catch {
      setDeleteError('Failed to delete counter.');
      setIsDeleting(false);
      setDeleteImpact(null);
    }
  }, [counterId, isDeleting, navigate]);

  const handleCancelDelete = useCallback(() => {
    if (isDeleting) return;
    setDeleteImpact(null);
  }, [isDeleting]);

  // ─── Loading / not-found states ───────────────────────────────────────────

  if (!group) {
    // `useSharedCounterGroups` returns [] as the default while Dexie is
    // initializing. When groups is still [] we may still be loading — show
    // a minimal shell to avoid a "not found" flash. Once groups resolves to
    // a non-empty list and this counter is still missing, it's genuine "not found".
    const isLoadingQuery = groups.length === 0;
    return (
      <div className={styles.container}>
        <div className={profileStyles.subPageHeader}>
          <Link to="/profile/counters" className={profileStyles.backLink} aria-label="Back to Counters">
            &larr;
          </Link>
          <h1 className={profileStyles.header}>Counter</h1>
        </div>
        {!isLoadingQuery && (
          <p className={profileStyles.subPageIntro}>Counter not found.</p>
        )}
      </div>
    );
  }

  // ─── Derived values ───────────────────────────────────────────────────────

  const activeTasks = group.tasks.filter((t) => t.isActive);
  const inactiveTasks = group.tasks.filter((t) => !t.isActive);
  const lifetimeStr = group.lifetime.toLocaleString();
  const unitStr = group.unit ?? '';
  const defaultAmount = group.defaultLogAmount ?? 1;
  const chips = buildAmountChipOptions(defaultAmount);
  const selectedChipIndex = isCustomActive ? chips.length - 1 : chips.findIndex((c) => c.value === selectedAmount);

  const progress = counterMilestoneProgress(group.lifetime);
  const maxDaily = Math.max(1, ...dailyTotals.days.map((d) => d.total));

  // ─── Render ───────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      {/* Sub-page header */}
      <div className={styles.headerRow}>
        <div className={profileStyles.subPageHeader}>
          <Link
            to="/profile/counters"
            className={profileStyles.backLink}
            aria-label="Back to Counters"
          >
            &larr;
          </Link>
          <div>
            <div className={styles.kicker}>SHARED COUNTER</div>
            <h1 className={profileStyles.header}>{group.name}</h1>
          </div>
        </div>
        <button
          ref={overflowBtnRef}
          type="button"
          className={styles.overflowBtn}
          aria-label="Counter options"
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          onClick={openOverflowMenu}
        >
          ⋯
        </button>
        {menuOpen && menuPos && (
          <RowContextMenu
            x={menuPos.x}
            y={menuPos.y}
            items={[
              {
                label: 'Delete counter…',
                glyph: '✕',
                destructive: true,
                action: () => void handleDeleteClick(),
              },
            ]}
            onClose={() => setMenuOpen(false)}
          />
        )}
      </div>

      <div className={styles.layout}>
        {/* Left rail (desktop) / top section (mobile) */}
        <div className={styles.leftRail}>
          {/* 1. Hero card */}
          <div className={styles.heroCard} aria-label={`${group.name}: ${lifetimeStr} all-time ${unitStr}`}>
            <div className={styles.heroTop}>
              <div className={styles.heroLifeBlock}>
                <span className={styles.lifetimeNum}>{lifetimeStr}</span>
                <span className={styles.lifetimeLabel}>all-time {unitStr}</span>
              </div>

              {/* 7-day sparkline — REAL data via useCounterDailyTotals. */}
              {dailyTotals.days.length > 0 && (
                <div
                  className={styles.sparkline}
                  role="img"
                  aria-label={`7-day activity — today ${dailyTotals.todayTotal.toLocaleString()} ${unitStr}`}
                >
                  {dailyTotals.days.map((d, i) => {
                    const isToday = i === dailyTotals.days.length - 1;
                    const heightPct = Math.max(6, Math.round((d.total / maxDaily) * 100));
                    return (
                      <span
                        key={d.dateISO}
                        className={`${styles.sparkBar} ${isToday ? styles.sparkBarToday : ''}`}
                        style={{ height: `${heightPct}%` }}
                        aria-hidden="true"
                      />
                    );
                  })}
                </div>
              )}
            </div>

            {/* Milestone progress bar */}
            <div className={styles.milestone}>
              <div className={styles.milestoneBar} aria-hidden="true">
                <div className={styles.milestoneFill} style={{ width: `${progress.fraction * 100}%` }} />
              </div>
              <p className={styles.milestoneLabel}>
                {progress.remaining.toLocaleString()} to{' '}
                <strong>{progress.next.toLocaleString()}</strong> milestone
              </p>
            </div>
          </div>

          {/* 2. Stat strip — Today (real) / Streak / Best week (P4 stubs) */}
          <div className={styles.statStrip}>
            <StatCard label="TODAY" value={dailyTotals.todayTotal.toLocaleString()} />
            {/* P4 — build-now-feed-P4: needs a real streak rollup (window-goal
                history); UI shipped now, wired to real data in P4. */}
            <StatCard label="STREAK" value="—" />
            {/* P4 — build-now-feed-P4: needs closed-window best-week rollup storage. */}
            <StatCard label="BEST WEEK" value="—" />
          </div>

          {/* 3. Log control — blue filled card */}
          <div className={styles.logCard} aria-label={`Log ${unitStr}`}>
            <div className={styles.logHeader}>
              <span className={styles.logTitle}>Log {unitStr}</span>
              <span className={styles.logSub}>
                counts toward {activeTasks.length} active task{activeTasks.length !== 1 ? 's' : ''}
              </span>
            </div>

            <div className={styles.chipRow} role="group" aria-label="Log amount">
              {chips.map((chip, i) => {
                const selected = i === selectedChipIndex;
                const isCustomChip = chip.value === null;
                return (
                  <button
                    key={isCustomChip ? 'custom' : `${i}-${chip.value}`}
                    type="button"
                    className={`${styles.chip} ${selected ? styles.chipSelected : ''}`}
                    aria-pressed={selected}
                    onClick={() => (isCustomChip ? openCustomInput() : selectChip(chip.value as number))}
                  >
                    {isCustomChip && selected ? selectedAmount : chip.label}
                  </button>
                );
              })}
            </div>

            {customOpen && (
              <div className={styles.customInputRow}>
                <input
                  type="number"
                  inputMode="numeric"
                  min={1}
                  step={1}
                  autoFocus
                  value={customDraft}
                  onChange={(e) => setCustomDraft(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') confirmCustomInput();
                    if (e.key === 'Escape') setCustomOpen(false);
                  }}
                  className={styles.customInput}
                  placeholder="Amount"
                  aria-label="Custom log amount"
                />
                <button
                  type="button"
                  className={styles.customConfirm}
                  onClick={confirmCustomInput}
                  disabled={parseCustomLogAmount(customDraft) == null}
                >
                  OK
                </button>
              </div>
            )}

            <div className={styles.logActionsRow}>
              <button
                type="button"
                className={styles.minusBtn}
                onClick={() => void handleLog('remove')}
                disabled={isLogging || group.lifetime === 0}
                aria-label={`Remove ${selectedAmount} ${unitStr}`}
              >
                −
              </button>
              <button
                type="button"
                className={styles.addBtn}
                onClick={() => void handleLog('add')}
                disabled={isLogging}
                aria-label={`Add ${selectedAmount} ${unitStr}`}
              >
                ＋ Add {selectedAmount}
              </button>
            </div>
          </div>

          {/* 4. Explainer copy */}
          <p className={styles.explainer}>
            Logged {unitStr} count toward every active task and your all-time total.
          </p>
        </div>

        {/* Right column (desktop) / bottom section (mobile) */}
        <div className={styles.rightCol}>
          {/* 5. "Counting on N tasks" — active member cards */}
          {activeTasks.length > 0 && (
            <>
              <RisoSectionLabel>
                Counting on {activeTasks.length} task{activeTasks.length !== 1 ? 's' : ''}
              </RisoSectionLabel>
              <div className={styles.taskCardsGrid} role="list" aria-label="Active tasks sharing this counter">
                {activeTasks.map((task) => (
                  <div key={task.taskId} role="listitem">
                    <CounterDetailTaskCard task={task} unit={group.unit} />
                  </div>
                ))}
              </div>
            </>
          )}

          {/* 6. "Recent weeks" — P4 stub */}
          <RisoSectionLabel>Recent weeks</RisoSectionLabel>
          <div className={styles.historyCard}>
            {/* P4 — build-now-feed-P4: needs closed-window history storage;
                UI shipped now (this card), real rows land in P4. */}
            <p className={styles.historyStub}>
              Weekly history will appear here once you&apos;ve logged for a few weeks.
            </p>
          </div>

          {/* 7. "Not counting now" — inactive / draft / unplaced tasks */}
          {inactiveTasks.length > 0 && (
            <>
              <RisoSectionLabel>Not counting now</RisoSectionLabel>
              <div role="list" aria-label="Inactive tasks not currently counting">
                {inactiveTasks.map((task) => (
                  <div key={task.taskId} role="listitem">
                    <CounterDetailTaskCard task={task} unit={group.unit} inactive />
                  </div>
                ))}
              </div>
            </>
          )}

          {/* 8. Delete-counter action — quiet red text link (was a filled button). */}
          {deleteError && <p className={styles.deleteError}>{deleteError}</p>}
          <div className={styles.deleteAction}>
            <button type="button" className={styles.deleteLink} onClick={() => void handleDeleteClick()}>
              Delete counter…
            </button>
          </div>
        </div>
      </div>

      {deleteImpact && (
        <CounterDeleteConfirmDialog
          counterName={group.name}
          memberCount={deleteImpact.counterMemberCount}
          members={deleteImpact.counterMembers.map((m) => ({
            id: m.id,
            title: m.title,
            boardName:
              group.tasks.find((t) => t.taskId === m.id)?.boardName ?? null,
          }))}
          busy={isDeleting}
          onConfirm={() => void handleConfirmDelete()}
          onCancel={handleCancelDelete}
        />
      )}

      {toast && (
        <CounterLogToast
          key={toast.toastKey}
          amount={toast.amount}
          unit={toast.unit}
          verb={toast.verb}
          onUndo={() => void handleUndo()}
          onDone={() => setToast(null)}
        />
      )}
    </div>
  );
}

/** One mini stat card in the stat strip (Today / Streak / Best week). */
function StatCard({ label, value }: { label: string; value: string }): React.ReactElement {
  return (
    <div className={styles.statCard}>
      <span className={styles.statValue}>{value}</span>
      <span className={styles.statLabel}>{label}</span>
    </div>
  );
}
