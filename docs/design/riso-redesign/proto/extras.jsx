/* ============================================================
   OYBC · Riso prototype — remaining screens
   Onboarding (first run) · Share board sheet · Edit profile sheet
   Exports: Onboarding, ShareSheet, EditProfileSheet
   ============================================================ */

/* ---- small poster board art (5×5, all done) reused in share ---- */
function PosterGrid() {
  return (
    <div className="sh-grid">
      {Array.from({ length: 25 }, (_, i) => (
        <i key={i} className={i === 12 ? "free" : "on"}>{i === 12 ? <Star size={9} /> : null}</i>
      ))}
    </div>
  );
}

/* ============================================================
   1 · ONBOARDING — first-run intro carousel + sign-in
   ============================================================ */
const OB_SLIDES = [
  {
    mood: "happy",
    kicker: "Welcome to",
    title: "OYBC",
    body: "Own Your Bingo Card. Turn the goals you keep meaning to hit into a board you actually want to fill.",
    art: "wordmark",
  },
  {
    mood: "happy",
    kicker: "The idea",
    title: "Fill squares,\nscore bingos.",
    body: "Every square is a habit or goal. Complete a row, column, or diagonal and it locks in as a bingo.",
    art: "lines",
  },
  {
    mood: "cheer",
    kicker: "The payoff",
    title: "Clear it for a\nGREENLOG.",
    body: "Fill the whole board and the page goes loud — confetti, streaks, the works. Then you start fresh.",
    art: "full",
  },
];

function OnboardArt({ kind }) {
  if (kind === "wordmark") {
    return (
      <div className="ob-art">
        <PosterGrid />
      </div>
    );
  }
  if (kind === "lines") {
    // a board with one row + one diagonal lit, gold rings on the lines
    const line = new Set([5, 6, 7, 8, 9, 0, 12, 24, 18]); // row 2 + diagonal
    const ring = new Set([5, 6, 7, 8, 9]);
    return (
      <div className="ob-art">
        <div className="sh-grid demo">
          {Array.from({ length: 25 }, (_, i) => (
            <i key={i} className={(i === 12 ? "free" : line.has(i) ? "on" : "") + (ring.has(i) ? " ring" : "")}>
              {i === 12 ? <Star size={9} /> : null}
            </i>
          ))}
        </div>
      </div>
    );
  }
  return (
    <div className="ob-art">
      <PosterGrid />
    </div>
  );
}

function Onboarding({ onDone }) {
  const [i, setI] = React.useState(0);
  const [auth, setAuth] = React.useState(false);
  const last = OB_SLIDES.length - 1;
  const slide = OB_SLIDES[i];

  if (auth) {
    return (
      <div className="ob">
        <button className="ob-skip" onClick={onDone}>Skip</button>
        <div className="ob-auth">
          <div className="ob-auth-mascot"><Blip size={84} mood="happy" /></div>
          <div className="r-kicker" style={{ textAlign: "center" }}>One last thing</div>
          <h1 className="ob-auth-h">Save your streak.</h1>
          <p className="ob-auth-p">Sign in so your boards sync across your devices and your GREENLOG history never resets.</p>
          <div className="ob-auth-btns">
            <button className="r-btn block ob-apple" onClick={onDone}><Icon name="apple" size={18} />Continue with Apple</button>
            <button className="r-btn block" onClick={onDone}><Icon name="msg" size={17} sw={2} />Continue with email</button>
            <button className="ob-later" onClick={onDone}>Maybe later</button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="ob">
      <button className="ob-skip" onClick={onDone}>Skip</button>
      <div className="ob-stage" key={i}>
        <OnboardArt kind={slide.art} />
        <div className="ob-copy">
          <div className="r-kicker">{slide.kicker}</div>
          <h1 className={"ob-title" + (slide.art === "wordmark" ? " wordmark" : "")}>{slide.title}</h1>
          <p className="ob-body">{slide.body}</p>
        </div>
      </div>
      <div className="ob-foot">
        <div className="ob-dots">
          {OB_SLIDES.map((_, n) => <span key={n} className={"ob-dot" + (n === i ? " on" : "")} />)}
        </div>
        <button className="r-btn primary block lg" onClick={() => (i === last ? setAuth(true) : setI(i + 1))}>
          {i === last ? "Get started" : "Next"}
        </button>
        {i > 0 && <button className="ob-back" onClick={() => setI(i - 1)}>Back</button>}
      </div>
    </div>
  );
}

/* ============================================================
   2 · SHARE BOARD — bottom sheet with a poster + targets
   ============================================================ */
const SH_TARGETS = [
  { id: "msg", icon: "msg", label: "Messages", cls: "green" },
  { id: "story", icon: "camera", label: "Stories", cls: "red" },
  { id: "save", icon: "image", label: "Save image", cls: "ink" },
  { id: "more", icon: "dots", label: "More", cls: "paper" },
];

function ShareSheet({ open, board, stats, onClose }) {
  const [copied, setCopied] = React.useState(false);
  const [withStats, setWithStats] = React.useState(true);
  React.useEffect(() => { if (open) { setCopied(false); } }, [open]);
  if (!open) return null;
  const name = (board && board.name) || "Weekly Wellness";
  const s = stats || { done: 25, total: 25, bingos: 5 };
  return (
    <div className="lb-sheetwrap">
      <div className="lb-scrim" onClick={onClose} />
      <div className="lb-sheet tt-sheet">
        <div className="lb-sheet-grab" />
        <div className="lb-sheet-head">
          <span className="lb-sheet-title">Share board</span>
          <button className="lb-sheet-done" onClick={onClose}>Done</button>
        </div>
        <div className="lb-sheet-body">
          {/* the shareable poster card */}
          <div className="sh-poster">
            <div className="sh-poster-top">
              <span className="sh-badge">GREENLOG</span>
              <span className="sh-wordmark">OYBC</span>
            </div>
            <div className="sh-poster-name">{name}</div>
            <PosterGrid />
            {withStats && (
              <div className="sh-stats">
                <div><b>{s.done}/{s.total}</b><span>Squares</span></div>
                <div><b>{s.bingos}</b><span>Bingos</span></div>
                <div><b>7d</b><span>Streak</span></div>
              </div>
            )}
            <div className="sh-poster-foot">Own Your Bingo Card</div>
          </div>

          <button className={"sh-statline" + (withStats ? " on" : "")} onClick={() => setWithStats(v => !v)}>
            <span className={"pp-switch" + (withStats ? " on" : "")}><i /></span>
            Include stats on the card
          </button>

          {/* copy link row */}
          <button className={"sh-copy" + (copied ? " done" : "")} onClick={() => setCopied(true)}>
            <span className="sh-copy-ico"><Icon name={copied ? "check" : "link"} size={18} sw={2.2} /></span>
            <span className="sh-copy-txt">
              <b>{copied ? "Link copied" : "Copy link"}</b>
              <span>oybc.app/b/wkwell-25</span>
            </span>
          </button>

          {/* targets */}
          <div className="sh-targets">
            {SH_TARGETS.map(t => (
              <button key={t.id} className="sh-target">
                <span className={"sh-target-ico " + t.cls}><Icon name={t.icon} size={22} sw={2} /></span>
                <span className="sh-target-lbl">{t.label}</span>
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

/* ============================================================
   3 · EDIT PROFILE — name + Blip avatar mood
   ============================================================ */
const EP_MOODS = [["happy", "Happy"], ["cheer", "Cheer"], ["calm", "Calm"]];

function EditProfileSheet({ open, name, email, mood, onClose, onSave }) {
  const [n, setN] = React.useState(name || "");
  const [m, setM] = React.useState(mood || "happy");
  React.useEffect(() => { if (open) { setN(name || ""); setM(mood || "happy"); } }, [open]); // eslint-disable-line
  if (!open) return null;
  const canSave = n.trim().length > 0;
  return (
    <div className="lb-sheetwrap">
      <div className="lb-scrim" onClick={onClose} />
      <div className="lb-sheet tt-sheet">
        <div className="lb-sheet-grab" />
        <div className="lb-sheet-head">
          <span className="lb-sheet-title">Edit profile</span>
          <button className="lb-sheet-done" onClick={onClose}>Done</button>
        </div>
        <div className="lb-sheet-body">
          <div className="ep-avatar-wrap">
            <div className="ep-avatar"><Blip size={84} mood={m} /></div>
          </div>
          <div className="ts-section-k" style={{ marginBottom: 8 }}>Blip mood</div>
          <div className="ep-moods">
            {EP_MOODS.map(([k, lab]) => (
              <button key={k} className={"ep-mood" + (m === k ? " on" : "")} onClick={() => setM(k)}>
                <Blip size={40} mood={k} />
                <span>{lab}</span>
              </button>
            ))}
          </div>
          <div className="ts-frow" style={{ marginTop: 14 }}>
            <label className="ts-flabel">Display name</label>
            <input className="ts-tinput" value={n} onChange={e => setN(e.target.value)} placeholder="Your name" maxLength={32} autoFocus />
          </div>
          <div className="ts-frow">
            <label className="ts-flabel">Email</label>
            <input className="ts-tinput" value={email || "you@example.com"} disabled />
            <div className="pp-hint" style={{ marginTop: 5 }}>Change your email from Account security.</div>
          </div>
          <button className="r-btn primary block lg" style={{ marginTop: 6, opacity: canSave ? 1 : .45 }}
            disabled={!canSave} onClick={() => onSave({ name: n.trim(), mood: m })}>Save profile</button>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { Onboarding, ShareSheet, EditProfileSheet, PosterGrid });
