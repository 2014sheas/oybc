/* ============================================================
   OYBC · Coming Soon — placeholder logic for oybc.com.
   Board build + escalation, tap-to-play, Day/Night toggle, and
   email capture (POST /api/subscribe → Firestore via Cloud
   Function). No framework. See docs/COMING_SOON.md.
   ============================================================ */
import './styles.css';

/* ---- locked production config (handoff "Locked direction" table) ---- */
const FREE = 12; // center free square
const LOUD = [0, 3, 6, 7, 11, 15, 17, 18, 20, 21, 23]; // resting inked (Loud)
const BLUE = new Set([6, 17, 21]); // Mixed ink: these are blue, rest red
const WIN_INK = [10, 11, 13, 14]; // inked on submit (12/FREE completes the row)
const WIN_LINE = [10, 11, 12, 13, 14]; // gold bingo ring on submit
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const REDUCE = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Query a required element; throw loudly if the shell markup drifts. */
function must<T extends Element>(selector: string, root: ParentNode = document): T {
  const found = root.querySelector<T>(selector);
  if (!found) throw new Error(`Coming Soon: missing element "${selector}"`);
  return found;
}

/* ============================================================
   Poster board — 5×5 grid, staggered "ink filling in" on load,
   tap empty cells to play (purely delightful, not persisted).
   Returns a `win()` that completes the center-row bingo + stamp.
   ============================================================ */
function initBoard(): () => void {
  const grid = must<HTMLDivElement>('.cs-grid');
  const board = must<HTMLDivElement>('.cs-board');
  const stamp = must<HTMLDivElement>('.cs-board-stamp');
  const cells: HTMLDivElement[] = [];
  let submitted = false;

  /** Ink a resting/played cell; `pop` adds the entrance motion only. */
  function ink(i: number, color: 'red' | 'blue', pop: boolean): void {
    const cell = cells[i];
    cell.classList.add('ink');
    cell.classList.toggle('blue', color === 'blue');
    if (pop && !REDUCE) {
      cell.classList.remove('pop');
      void cell.offsetWidth; // reflow so the animation restarts
      cell.classList.add('pop');
    }
  }

  function toggleCell(i: number): void {
    const cell = cells[i];
    if (i === FREE || submitted || cell.classList.contains('line')) return;
    if (cell.classList.contains('ink')) {
      cell.classList.remove('ink', 'blue');
    } else {
      ink(i, 'red', true);
    }
  }

  for (let i = 0; i < 25; i++) {
    const cell = document.createElement('div');
    cell.className = 'cs-cell';
    if (i === FREE) {
      cell.classList.add('free');
    } else {
      const idx = i;
      // one-shot cleanup so a cell can pop again on a later tap
      cell.addEventListener('animationend', () => cell.classList.remove('pop'));
      cell.addEventListener('click', () => toggleCell(idx));
    }
    grid.appendChild(cell);
    cells.push(cell);
  }

  // escalation: stamp the resting cells in one at a time
  const resting = LOUD.filter((i) => i !== FREE);
  resting.forEach((i, k) => {
    const color = BLUE.has(i) ? 'blue' : 'red';
    if (REDUCE) ink(i, color, false);
    else window.setTimeout(() => ink(i, color, true), 360 + k * 95);
  });

  return function win(): void {
    if (submitted) return;
    submitted = true;
    WIN_INK.forEach((i) => ink(i, 'red', true));
    WIN_LINE.forEach((i) => cells[i].classList.add('line'));
    board.classList.add('won');
    stamp.classList.add('in');
  };
}

/* ============================================================
   How-it-works mini-boards.
   ============================================================ */
interface Beat {
  n: string;
  on: number[] | 'all';
  line?: number[];
  h: string;
  p: string;
}
// Fills are scattered so NO row/column/diagonal is fully coloured except the
// intended gold `line` in beat 02 (grid col = index % 5; col 1 = {1,6,11,16,21}).
const BEATS: Beat[] = [
  { n: '01', on: [0, 3, 6, 9, 13, 16, 19, 22], h: 'Fill your squares', p: 'Drop your goals on a board.' },
  { n: '02', on: [0, 6, 8, 16, 19, 22], line: [10, 11, 13, 14], h: 'Line up a bingo', p: 'Any row, column or diagonal wins.' },
  { n: '03', on: 'all', h: 'Clear & renew', p: 'Finish it, start fresh, streak carries.' },
];

function initBeats(): void {
  const container = must<HTMLDivElement>('.cs-beats-in');
  for (const beat of BEATS) {
    const wrap = document.createElement('div');
    wrap.className = 'cs-beat';

    const mini = document.createElement('div');
    mini.className = 'cs-beat-mini';
    mini.setAttribute('aria-hidden', 'true');
    const line = beat.line ?? [];
    for (let i = 0; i < 25; i++) {
      const dot = document.createElement('i');
      if (i === FREE) dot.className = 'free';
      else if (line.includes(i)) dot.className = 'line';
      else if (beat.on === 'all' || beat.on.includes(i)) dot.className = 'on';
      mini.appendChild(dot);
    }

    const text = document.createElement('div');
    const n = document.createElement('div');
    n.className = 'cs-beat-n';
    n.textContent = beat.n;
    const h = document.createElement('div');
    h.className = 'cs-beat-h';
    h.textContent = beat.h;
    const p = document.createElement('div');
    p.className = 'cs-beat-p';
    p.textContent = beat.p;
    text.append(n, h, p);

    wrap.append(mini, text);
    container.appendChild(wrap);
  }
}

/* ============================================================
   Day / Night theme toggle.
   ============================================================ */
function initTheme(): void {
  const buttons = document.querySelectorAll<HTMLButtonElement>('.cs-seg button[data-theme]');
  buttons.forEach((btn) => {
    btn.addEventListener('click', () => {
      const night = btn.dataset.theme === 'night';
      document.body.classList.toggle('night', night);
      buttons.forEach((b) => {
        const on = b.dataset.theme === (night ? 'night' : 'day');
        b.classList.toggle('on', on);
        b.setAttribute('aria-pressed', String(on));
      });
    });
  });
}

/* ============================================================
   Email capture → Firestore via the `subscribe` Cloud Function.
   POST is same-origin (/api/subscribe); Firebase Hosting rewrites
   it to the function, so no CORS and no Firebase SDK on the page.
   ============================================================ */
async function subscribe(email: string, honeypot: string): Promise<void> {
  const res = await fetch('/api/subscribe', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, source: 'coming-soon', hp: honeypot }),
  });
  if (!res.ok) throw new Error('subscribe_failed');
}

function initForm(win: () => void): void {
  const form = must<HTMLFormElement>('.cs-form');
  const emailInput = must<HTMLInputElement>('input[name="email"]', form);
  const honeypot = must<HTMLInputElement>('input[name="company"]', form);
  const button = must<HTMLButtonElement>('button[type="submit"]', form);
  const hint = must<HTMLDivElement>('.cs-hint');
  const note = must<HTMLDivElement>('.cs-note');
  const confirm = must<HTMLDivElement>('.cs-confirm');
  const confirmEmail = must<HTMLElement>('[data-confirm-email]', confirm);

  function showHint(message: string): void {
    hint.textContent = message;
    hint.hidden = false;
  }
  function clearHint(): void {
    hint.hidden = true;
    hint.textContent = '';
  }

  let submitting = false;

  emailInput.addEventListener('input', clearHint);

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    // Guard the in-flight window: a disabled button doesn't stop Enter-in-input
    // from re-firing the form before the first POST resolves.
    if (submitting) return;
    const email = emailInput.value.trim();
    if (!EMAIL_RE.test(email)) {
      showHint('Enter a valid email address.');
      return;
    }
    clearHint();
    submitting = true;
    button.disabled = true;

    void subscribe(email, honeypot.value)
      .then(() => {
        // success / duplicate — both reveal the confirmation + bingo
        confirmEmail.textContent = email;
        form.hidden = true;
        note.hidden = true;
        confirm.hidden = false;
        win();
      })
      .catch(() => {
        submitting = false;
        button.disabled = false;
        showHint("Couldn't save that — try again.");
      });
  });
}

/* ---- boot ---- */
initTheme();
initBeats();
initForm(initBoard());
