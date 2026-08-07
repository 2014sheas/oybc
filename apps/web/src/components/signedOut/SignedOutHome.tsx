import { useEffect, useState } from 'react';
import { RisoButton, RisoBrandMark, RisoIcon, RisoSegmented } from '../riso';
import { HeroBoard, BeatMini, type BeatState } from './SignedOutArt';
import { SignInModal, type AuthMode } from './SignInModal';
import { useSignedOutTheme, type SignedOutTheme } from './useSignedOutTheme';
import styles from './SignedOut.module.css';

/** The three escalation beats — fill → bingo → clear. */
const BEATS: ReadonlyArray<{ n: string; state: BeatState; h: string; p: string; loud?: boolean }> = [
  {
    n: '01',
    state: 'partial',
    h: 'Fill your squares',
    p: 'Drop up to twenty-five goals on a board and tap a square when you’ve done the thing.',
  },
  {
    n: '02',
    state: 'bingo',
    h: 'Line up a bingo',
    p: 'Any row, column, or diagonal counts as a win — you don’t need the whole board.',
  },
  {
    n: '03',
    state: 'full',
    h: 'Clear it and renew',
    p: 'Finish a board to start fresh. Your streak and history carry straight over.',
    loud: true,
  },
];

/** The four square types. */
const TYPES: ReadonlyArray<{ b: string; cls: string; h: string; p: string }> = [
  { b: 'N', cls: styles.normal, h: 'Normal', p: 'A simple done / not-done check. Tap it when you’ve done the thing.' },
  { b: 'C', cls: styles.count, h: 'Counting', p: 'A goal with a number — “Run 5 km.” Tap +/− to log progress.' },
  { b: 'K', cls: styles.cmnd, h: 'Compound', p: 'Multi-step tasks — all of, any of, or a set number. One square, several moves.' },
  { b: 'A', cls: styles.achv, h: 'Achievement', p: 'Watches a board or template and completes on a bingo or GREENLOG.' },
];

/**
 * Signed-out marketing home — the poster landing shown to visitors without a
 * session. Mascot-agnostic (the bingo board is the hero). Owns its own theme
 * (pre-auth) and the sign-in/up modal; auth runs through the real `useAuth`
 * inside the modal, and on success `AuthGate` swaps this whole tree for the app.
 */
export function SignedOutHome(): React.ReactElement {
  const [theme, setTheme] = useSignedOutTheme();
  const [authMode, setAuthMode] = useState<AuthMode | null>(null);

  // Escape closes the modal.
  useEffect(() => {
    if (!authMode) return;
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') setAuthMode(null);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [authMode]);

  const scrollTo = (id: string): void => {
    document.getElementById(id)?.scrollIntoView({ behavior: 'smooth' });
  };

  return (
    <div className={`${styles.so} riso-grain`}>
      <header className={styles.soNav}>
        <div className={styles.soNavIn}>
          <RisoBrandMark size={40} />
          <div className={styles.soWord}>OYBC</div>
          <nav className={styles.soNavLinks}>
            <button type="button" onClick={() => scrollTo('so-how')}>
              How it works
            </button>
            <button type="button" onClick={() => scrollTo('so-squares')}>
              Squares
            </button>
          </nav>
          <div className={styles.soNavRight}>
            <RisoSegmented<SignedOutTheme>
              variant="pill"
              aria-label="Theme"
              value={theme}
              onChange={setTheme}
              options={[
                { value: 'light', label: <><RisoIcon name="sun" size={13} /> <span className={styles.soSegLabel}>Day</span></> },
                { value: 'dark', label: <><RisoIcon name="moon" size={13} /> <span className={styles.soSegLabel}>Night</span></> },
              ]}
            />
            <span className={styles.soNavSignIn}>
              <RisoButton kind="ghost" onClick={() => setAuthMode('signin')}>
                Sign in
              </RisoButton>
            </span>
            <RisoButton kind="primary" onClick={() => setAuthMode('signup')}>
              Get started
            </RisoButton>
          </div>
        </div>
      </header>

      {/* hero */}
      <section className={styles.soHero}>
        <div>
          <div className={styles.soLeadin}>Put the goals you keep dodging</div>
          <h1 className={styles.soDisplay}>
            on your
            <br />
            bingo card.
          </h1>
          <p className={styles.soSub}>
            Your goals, on a board you’ll actually want to fill. A single line is a bingo — so some weeks, five
            squares is a win. Progress, minus the pressure to do it all.
          </p>
          <div className={styles.soCta}>
            <RisoButton
              kind="primary"
              size="large"
              icon={<RisoIcon name="plus" size={16} />}
              onClick={() => setAuthMode('signup')}
            >
              Start a board
            </RisoButton>
            <RisoButton kind="neutral" size="large" onClick={() => setAuthMode('signin')}>
              Sign in
            </RisoButton>
          </div>
          <div className={styles.soCtaNote}>Free to start · syncs across your devices</div>
        </div>
        <div className={styles.soPosterWrap}>
          <HeroBoard />
        </div>
      </section>

      {/* how it works */}
      <section className={styles.soSection} id="so-how">
        <div className={styles.soSectionIn}>
          <div className={styles.soEyebrow}>How it works</div>
          <h2 className={styles.soH2}>Three moves, start to finish.</h2>
          <p className={styles.soLead}>
            Build a board, line up a bingo, then start a fresh one. The whole loop takes seconds to learn.
          </p>
          <div className={styles.soBeats}>
            {BEATS.map((b) => (
              <div className={[styles.soBeat, b.loud ? styles.loud : ''].filter(Boolean).join(' ')} key={b.n}>
                <div className={styles.soBeatNum}>{b.n}</div>
                <BeatMini state={b.state} />
                <div className={styles.soBeatH}>{b.h}</div>
                <p className={styles.soBeatP}>{b.p}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* square types */}
      <section className={styles.soSection} id="so-squares">
        <div className={styles.soSectionIn}>
          <div className={styles.soEyebrow}>What a square can be</div>
          <h2 className={styles.soH2}>Not just a checkbox.</h2>
          <p className={styles.soLead}>
            Squares flex to fit the goal — a simple check, a counter, a multi-step routine, or a cross-board
            achievement. Reuse them across boards and your streak history follows.
          </p>
          <div className={styles.soTypes}>
            {TYPES.map((t) => (
              <div className={styles.soType} key={t.h}>
                <div className={[styles.soTypeBadge, t.cls].join(' ')}>{t.b}</div>
                <div className={styles.soTypeH}>{t.h}</div>
                <p className={styles.soTypeP}>{t.p}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* footer CTA */}
      <footer className={styles.soFoot}>
        <div className={styles.soFootIn}>
          <div className={styles.soKicker} style={{ color: 'var(--riso-gold)' }}>
            Ready when you are
          </div>
          <h2 className={styles.soFootH}>Fill your first board.</h2>
          <div className={styles.soFootCta}>
            <button type="button" className={styles.btnOnred} onClick={() => setAuthMode('signup')}>
              <RisoIcon name="plus" size={16} />
              Start a board
            </button>
            <button type="button" className={styles.btnOnredGhost} onClick={() => setAuthMode('signin')}>
              Sign in
            </button>
          </div>
        </div>
        <div className={styles.soFootLegal}>
          <span>OYBC · On Your Bingo Card</span>
          <span className={styles.soFootLegalLinks}>
            {/* Placeholder until the legal pages exist (pre-launch). Buttons, not
                hrefless <a>s, so they're keyboard-focusable + announced correctly. */}
            <button type="button">Privacy</button>
            <button type="button">Terms</button>
            <button type="button">Contact</button>
          </span>
        </div>
      </footer>

      {authMode && (
        <SignInModal mode={authMode} onClose={() => setAuthMode(null)} onSwitchMode={setAuthMode} />
      )}
    </div>
  );
}
