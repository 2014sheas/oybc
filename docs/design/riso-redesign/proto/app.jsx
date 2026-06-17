/* ============================================================
   OYBC · Riso prototype — App orchestrator
   ============================================================ */

const PALETTES = {
  "Classic Riso": ["#2C44C9", "#EB4D2E", "#1F9B6B"],
  "Ink & Tangerine": ["#1E2A78", "#F2862E", "#2FA36B"],
  "Berry Press": ["#6B3FB0", "#D6336C", "#2E8B57"],
  "Sea & Coral": ["#127C8A", "#F0513C", "#2E8B57"],
};

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "palette": ["#2C44C9", "#EB4D2E", "#1F9B6B"],
  "celebration": 7,
  "serial": false,
  "brightPaper": false,
  "topLayout": "grid",
  "compactHeader": false,
  "composerStyle": "button",
  "libAccess": "sheet",
  "themePref": "system",
  "blipMotion": true
}/*EDITMODE-END*/;

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const data = window.OYBC;

  const [screen, setScreen] = React.useState("home"); // home | board | wizard
  const [activeBoard, setActiveBoard] = React.useState(null);
  const [cells, setCells] = React.useState(() => data.boards[0].cells.map(c => ({ ...c })));
  const [toast, setToast] = React.useState(null);
  const [greenlog, setGreenlog] = React.useState(false);
  const prevBingos = React.useRef(computeLines(data.boards[0].cells).count);
  const toastTimer = React.useRef(null);
  const [shareOpen, setShareOpen] = React.useState(false);
  const [profile, setProfile] = React.useState({ name: "OYBC User", email: "you@example.com", mood: "happy" });
  const [onboarded, setOnboarded] = React.useState(() => {
    try { return localStorage.getItem("oybc_onboarded") === "1"; } catch (e) { return false; }
  });
  const finishOnboarding = () => {
    try { localStorage.setItem("oybc_onboarded", "1"); } catch (e) {}
    setOnboarded(true);
  };
  const [layoutOverride, setLayoutOverride] = React.useState(null); // dev capture only
  const [taskFlowOverride, setTaskFlowOverride] = React.useState(null); // dev capture only
  const [composerOverride, setComposerOverride] = React.useState(null); // dev capture only
  const [libAccessOverride, setLibAccessOverride] = React.useState(null); // dev capture only
  const [profileJump, setProfileJump] = React.useState(null); // dev capture only

  // dev-only: load a specific state for screenshots via URL hash
  React.useEffect(() => {
    const h = (window.location.hash || "").toLowerCase();
    if (h === "#gl") {
      setActiveBoard(data.boards[0]); setScreen("board");
      setCells(cs => cs.map(c => ({ ...c, done: true, cur: c.max != null ? c.max : c.cur })));
      setTimeout(() => setGreenlog(true), 60);
    } else if (h.startsWith("#wiz")) {
      setScreen("wizard");
      if (h === "#wiz-sheet") setLibAccessOverride("sheet");
      else if (h === "#wiz-tabs") setLibAccessOverride("tabs");
      else if (h === "#wiz-a2") setComposerOverride("return");
    }
    else if (h === "#board") { setActiveBoard(data.boards[0]); setScreen("board"); }
    else if (h === "#share") { setActiveBoard(data.boards[0]); setScreen("board"); setCells(cs => cs.map(c => ({ ...c, done: true, cur: c.max != null ? c.max : c.cur }))); setShareOpen(true); }
    else if (h === "#onboard") { try { localStorage.removeItem("oybc_onboarded"); } catch (e) {} setOnboarded(false); }
    else if (h === "#tasks") { setScreen("tasks"); }
    else if (h === "#profile") { setScreen("profile"); }
    else if (["#prefs", "#templates", "#pools"].includes(h)) { setScreen("profile"); setProfileJump(h.slice(1)); }
    else if (["#rail", "#four", "#grid", "#filter"].includes(h)) { setLayoutOverride(h.slice(1)); }
  }, []); // eslint-disable-line

  const total = cells.length;
  const doneCount = cells.filter(c => c.done).length;
  const { count: bingos, cellSet: lineCells } = computeLines(cells);

  // fire bingo toast / greenlog on changes
  React.useEffect(() => {
    if (bingos > prevBingos.current) {
      showToast(bingos);
    }
    prevBingos.current = bingos;
    if (doneCount === total && total > 0 && !greenlog) {
      const tmo = setTimeout(() => setGreenlog(true), 520);
      return () => clearTimeout(tmo);
    }
  }, [bingos, doneCount]); // eslint-disable-line

  function showToast(count) {
    setToast({ count, key: Date.now() });
    clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast(null), 2800);
  }

  function clearJust() {
    setTimeout(() => setCells(cs => cs.map(c => (c.justDone ? { ...c, justDone: false } : c))), 360);
  }

  function toggle(i) {
    setCells(cs => cs.map((c, j) => {
      if (j !== i) return c;
      const nowDone = !c.done;
      return { ...c, done: nowDone, justDone: nowDone };
    }));
    clearJust();
  }

  function count(i, delta) {
    setCells(cs => cs.map((c, j) => {
      if (j !== i) return c;
      const cur = Math.max(0, Math.min(c.max, c.cur + delta));
      const nowDone = cur >= c.max;
      return { ...c, cur, done: nowDone, justDone: nowDone && !c.done };
    }));
    clearJust();
  }

  function openBoard(b) {
    if (b.status === "draft") { setScreen("wizard"); return; }
    if (b.id === "wellness") {
      setActiveBoard(b); setScreen("board");
    } else {
      // other boards: load a quick stand-in from miniFill
      setActiveBoard(b); setScreen("board");
      const standin = (b.miniFill || []).map((f, i) => ({
        t: ["Task", "Goal", "Habit", "Win", "Step"][i % 5] + " " + (i + 1),
        type: i === 12 ? "free" : "normal", done: i === 12 ? true : !!f,
      }));
      setCells(standin.length ? standin : data.boards[0].cells.map(c => ({ ...c })));
      prevBingos.current = computeLines(standin).count;
    }
  }
  function backHome() {
    setScreen("home");
    setToast(null);
  }
  function loadWellness() {
    setCells(data.boards[0].cells.map(c => ({ ...c })));
    prevBingos.current = computeLines(data.boards[0].cells).count;
    setGreenlog(false);
  }
  function resetDemo() {
    loadWellness();
    setActiveBoard(data.boards[0]);
    setScreen("board");
    setToast(null);
  }
  function finishWizard(cfg) {
    loadWellness();
    setActiveBoard({ ...data.boards[0], name: cfg.name });
    setScreen("board");
  }

  // CSS vars from tweaks
  const night = t.themePref === "dark";
  const [blue, red, green] = t.palette && t.palette.length === 3 ? t.palette : PALETTES["Classic Riso"];
  const risoVars = night ? {
    /* night press — warm near-black paper, cream ink, brightened inks */
    "--blue": "#6678F2", "--red": "#FF6A4A", "--green": "#3BCB92",
    "--paper": "#171310", "--paper-2": "#221C15",
    "--ink": "#F1E9D9", "--muted": "#A39781",
  } : {
    "--blue": blue, "--red": red, "--green": green,
    "--paper": t.brightPaper ? "#FBFAF4" : "#F1E9D9",
    "--paper-2": t.brightPaper ? "#FFFFFF" : "#FBF6EA",
  };

  return (
    <IOSDevice dark={night}>
      <div className={"riso" + (night ? " night" : "") + (t.blipMotion ? " blip-live" : "")} style={risoVars}>
        {screen === "home" && (
          <BoardsHome boards={data.boards} onOpen={openBoard} onCreate={() => setScreen("wizard")} topLayout={layoutOverride || "grid"} compactHeader={t.compactHeader} />
        )}
        {screen === "board" && activeBoard && (
          <PlayBoard
            board={activeBoard} cells={cells} lineCells={lineCells}
            onToggle={toggle} onCount={count} onBack={backHome} serial={t.serial}
          />
        )}
        {screen === "wizard" && (
          <Wizard onClose={backHome} onFinish={finishWizard} composerStyle={composerOverride || t.composerStyle} libAccess={libAccessOverride || t.libAccess} />
        )}
        {screen === "tasks" && <TasksTab />}
        {screen === "profile" && <ProfileTab key={profileJump || "pf"} theme={t.themePref} onTheme={(v) => setTweak("themePref", v)} celebration={t.celebration} onCelebration={(v) => setTweak("celebration", v)} initialPage={profileJump} profile={profile} onSaveProfile={setProfile} />}

        {/* tab bar */}
        {(
          <nav className="r-tabs">
            {[["boards", "Boards"], ["tasks", "Tasks"], ["create", "Create"], ["profile", "You"]].map(([k, l]) => {
              const on = (k === "boards" && (screen === "home" || screen === "board")) || (k === "create" && screen === "wizard") || (k === "tasks" && screen === "tasks") || (k === "profile" && screen === "profile");
              return (
                <button key={k} className={"r-tab" + (on ? " on" : "")} onClick={() => {
                  if (k === "create") setScreen("wizard");
                  else if (k === "boards") backHome();
                  else if (k === "tasks") setScreen("tasks");
                  else if (k === "profile") setScreen("profile");
                }}>
                  <span className="r-tab-ico"><Icon name={k} size={20} /></span>
                  <span className="r-tab-lbl">{l}</span>
                </button>
              );
            })}
          </nav>
        )}

        {/* bingo toast */}
        {toast && screen === "board" && (
          <div className="r-toast in" key={toast.key}>
            <div className="r-toast-art"><Blip size={42} mood="happy" /></div>
            <div className="r-toast-txt">
              <div className="r-toast-h">BINGO!</div>
              <div className="r-toast-s">Line locked in. Keep going — fill the board.</div>
            </div>
            <div className="r-toast-cnt">×{toast.count}</div>
          </div>
        )}

        {/* GREENLOG */}
        {greenlog && (
          <Greenlog
            stats={{ done: doneCount, total, bingos }}
            intensity={t.celebration}
            onShare={() => setShareOpen(true)}
            onNew={() => { setGreenlog(false); setScreen("wizard"); }}
          />
        )}

        {/* Share board */}
        <ShareSheet open={shareOpen} board={activeBoard} stats={{ done: doneCount, total, bingos }} onClose={() => setShareOpen(false)} />

        {/* Onboarding (first run) */}
        {!onboarded && <Onboarding onDone={finishOnboarding} />}

        {/* Tweaks */}
        <TweaksPanel>
          <TweakSection label="Ink palette" />
          <TweakRadio label="Theme" value={t.themePref}
            options={["system", "light", "dark"]}
            onChange={(v) => setTweak("themePref", v)} />
          <TweakColor label="Inks" value={t.palette}
            options={Object.values(PALETTES)}
            onChange={(v) => setTweak("palette", v)} />
          <TweakToggle label="Brighter paper" value={t.brightPaper} onChange={(v) => setTweak("brightPaper", v)} />

          <TweakSection label="Boards home" />
          <TweakToggle label="Compact headline" value={t.compactHeader} onChange={(v) => setTweak("compactHeader", v)} />

          <TweakSection label="Board" />
          <TweakToggle label="Serial numbers (01–25)" value={t.serial} onChange={(v) => setTweak("serial", v)} />

          <TweakSection label="Celebration" />
          <TweakSlider label="Intensity" value={t.celebration} min={1} max={10} step={1}
            onChange={(v) => setTweak("celebration", v)} />
          <TweakToggle label="Animated Blip" value={t.blipMotion} onChange={(v) => setTweak("blipMotion", v)} />

          <TweakSection label="Demo" />
          <TweakButton label="▶ Replay onboarding" onClick={() => { try { localStorage.removeItem("oybc_onboarded"); } catch (e) {} setOnboarded(false); }} />
          <TweakButton label="↗ Share board sheet" onClick={() => { setActiveBoard(data.boards[0]); setScreen("board"); setCells(cs => cs.map(c => ({ ...c, done: true, cur: c.max != null ? c.max : c.cur }))); setShareOpen(true); }} />
          <TweakButton label="▶ Replay demo board" onClick={resetDemo} />
          <TweakButton label="✦ Trigger GREENLOG" onClick={() => {
            setActiveBoard(data.boards[0]); setScreen("board");
            setCells(cs => cs.map(c => ({ ...c, done: true, cur: c.max != null ? c.max : c.cur })));
            setTimeout(() => setGreenlog(true), 200);
          }} />
        </TweaksPanel>
      </div>
    </IOSDevice>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
