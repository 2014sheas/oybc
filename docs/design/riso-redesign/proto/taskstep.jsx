/* ============================================================
   OYBC · Riso prototype — redesigned Tasks step (wizard step 2)
   Default = Normal (fast quick-add, 3 switchable styles).
   Counting / Compound / Achievement get a proper type-aware
   authoring panel that mirrors the real app's fields.
   Exports to window: TaskStep
   ============================================================ */

const TYPE_META = {
  normal:      { label: "Normal",      cls: "normal" },
  count:       { label: "Counting",    cls: "count" },
  compound:    { label: "Compound",    cls: "cmnd" },
  achievement: { label: "Achievement", cls: "achv" },
};

/* describe a task's type-specific config for the pool row */
function typeDetail(t) {
  let base = null;
  if (t.type === "count") base = `${t.action || t.t} · goal ${t.max} ${t.unit || ""}`.trim();
  else if (t.type === "compound") {
    if (t.rule === "ordered") base = `${(t.subs || []).length} steps · in order`;
    else base = `${t.rule === "any" ? "Any of" : t.rule === "mOfN" ? `≥${t.threshold} of` : "All of"} ${(t.subs || []).length}`;
  }
  else if (t.type === "achievement") {
    const trig = t.trigger === "bingo" ? "Bingo" : "GREENLOG";
    base = `Watch ${t.target} · ${trig}${t.watch === "template" && t.reqCount ? ` ×${t.reqCount}` : ""}`;
  }
  const extras = [];
  if (t.linked) extras.push(`↔ ${t.linked}`);
  if (t.from) extras.push(`from ${t.from}`);
  if (!base && !extras.length) return null;
  return [base, ...extras].filter(Boolean).join(" · ");
}

/* ---- live pool header (count + pool model) ---- */
function PoolHeader({ count, need }) {
  const remaining = need - count;
  const ready = remaining <= 0;
  const pct = Math.min(100, Math.round(count / need * 100));
  return (
    <div className="ts-head">
      <div className="ts-head-row">
        <span className="ts-head-k">Your task pool</span>
        <span className={"ts-head-v" + (ready ? " ready" : "")}>{count}<span className="ts-head-need">/{need}</span></span>
      </div>
      <div className="ts-prog"><i style={{ width: pct + "%" }} /></div>
      <div className="ts-head-note">
        {ready
          ? <span className="ts-ready">✓ Fills your board{count > need ? ` · ${count - need} extra shuffle in each week` : " exactly"}</span>
          : <span>Add <b>{remaining}</b> more — extras later just shuffle into the mix</span>}
      </div>
    </div>
  );
}

/* ============================================================
   CREATOR A — Inline composer (Normal quick-add) + sub-variants
   variant: "button" | "return" | "smart"
   ============================================================ */
const COMPOSER_PLACEHOLDERS = ["Meditate 10 min", "Drink water", "Read 30 min", "Walk the dog", "No sugar today", "Stretch"];

function ComposerA({ onAdd, pool, variant = "button" }) {
  const [text, setText] = React.useState("");
  const [ph, setPh] = React.useState(0);
  const [flash, setFlash] = React.useState(false);
  const [focused, setFocused] = React.useState(false);
  const inputRef = React.useRef(null);

  const add = (task) => {
    onAdd(task);
    setText("");
    setPh(p => (p + 1) % COMPOSER_PLACEHOLDERS.length);
    setFlash(true); setTimeout(() => setFlash(false), 700);
    if (inputRef.current) inputRef.current.focus();
  };
  const submit = () => { if (text.trim()) add({ t: text.trim(), type: "normal" }); };

  const placeholder = `e.g. ${COMPOSER_PLACEHOLDERS[ph]}`;

  // smart-variant library autocomplete
  const lib = window.OYBC.taskLibrary;
  const inPool = (name) => pool && pool.some(p => p.t.toLowerCase() === name.toLowerCase());
  const matches = variant === "smart" && text.trim()
    ? lib.filter(l => l.t.toLowerCase().includes(text.toLowerCase()) && !inPool(l.t)).slice(0, 3)
    : [];
  const exact = lib.some(l => l.t.toLowerCase() === text.trim().toLowerCase());

  return (
    <div className={"ts-composer v-" + variant + (focused ? " focused" : "")}>
      <div className="ts-comp-row">
        {variant !== "button" && <span className="ts-comp-plus">＋</span>}
        <input ref={inputRef} className="ts-input" placeholder={placeholder} value={text}
          onFocus={() => setFocused(true)} onBlur={() => setTimeout(() => setFocused(false), 120)}
          onChange={e => setText(e.target.value)}
          onKeyDown={e => { if (e.key === "Enter") submit(); }} />
        {variant === "button" && (
          <button className={"ts-addbtn" + (flash ? " flash" : "")} onClick={submit} disabled={!text.trim()}>
            {flash ? "Added ✓" : "Add"}
          </button>
        )}
        {variant === "return" && <span className="ts-comp-hint">{flash ? "added ✓" : "return ↵"}</span>}
      </div>

      {/* smart inline autocomplete */}
      {variant === "smart" && text.trim() && (
        <div className="ts-ac">
          {matches.map(l => (
            <button key={l.id} className="ts-ac-row" onMouseDown={e => e.preventDefault()}
              onClick={() => add({ t: l.t, type: l.type, action: l.action, max: l.max, unit: l.unit })}>
              <span className="ts-ac-i">↩︎</span><span className="ts-ac-t">{l.t}</span>
              <span className={"ts-li-tag " + TYPE_META[l.type].cls}>{TYPE_META[l.type].label}</span>
              <span className="ts-ac-reuse">reuse</span>
            </button>
          ))}
          {!exact && (
            <button className="ts-ac-row create" onMouseDown={e => e.preventDefault()} onClick={submit}>
              <span className="ts-ac-i">＋</span><span className="ts-ac-t">Create “{text.trim()}”</span>
              <span className="ts-ac-new">new</span>
            </button>
          )}
        </div>
      )}
    </div>
  );
}

/* ============================================================
   SPECIAL-TYPE AUTHORING PANEL (Counting / Compound / Achievement)
   The "advanced reveal" — collapsed by default.
   ============================================================ */
function SpecialTaskPanel({ onAdd }) {
  const [open, setOpen] = React.useState(false);
  const [type, setType] = React.useState("count");

  // counting
  const [action, setAction] = React.useState("");
  const [unit, setUnit] = React.useState("");
  const [goal, setGoal] = React.useState(5);
  // compound
  const [cTitle, setCTitle] = React.useState("");
  const [rule, setRule] = React.useState("all");
  const [threshold, setThreshold] = React.useState(2);
  const [subs, setSubs] = React.useState([]);
  const [subText, setSubText] = React.useState("");
  const [subType, setSubType] = React.useState("normal");
  const [subGoal, setSubGoal] = React.useState(5);
  const [subUnit, setSubUnit] = React.useState("");
  // achievement
  const [aTitle, setATitle] = React.useState("");
  const [watch, setWatch] = React.useState("board");
  const [target, setTarget] = React.useState(window.OYBC.watchTargets.boards[0]);
  const [trigger, setTrigger] = React.useState("greenlog");
  const [reqCount, setReqCount] = React.useState(3);

  const reset = () => {
    setAction(""); setUnit(""); setGoal(5);
    setCTitle(""); setRule("all"); setThreshold(2); setSubs([]); setSubText(""); setSubType("normal"); setSubGoal(5); setSubUnit("");
    setATitle(""); setWatch("board"); setTarget(window.OYBC.watchTargets.boards[0]); setTrigger("greenlog"); setReqCount(3);
  };

  const addSub = () => {
    if (!subText.trim()) return;
    let s;
    if (subType === "count") {
      const unit = subUnit.trim() || "reps";
      const goal = Number(subGoal) || 1;
      s = { t: `${subText.trim()} ${goal} ${unit}`, type: "count", action: subText.trim(), max: goal, unit };
    } else {
      s = { t: subText.trim(), type: subType };
    }
    setSubs(prev => [...prev, s]);
    setSubText(""); setSubType("normal"); setSubGoal(5); setSubUnit("");
  };

  const countingTitle = action.trim() ? `${action.trim()} ${goal} ${unit.trim()}`.replace(/\s+/g, " ").trim() : "";
  const canAdd =
    type === "count" ? action.trim() && unit.trim() && Number(goal) > 0 :
    type === "compound" ? cTitle.trim() && subs.length >= 2 :
    /* achievement */ aTitle.trim() && target && (watch !== "template" || Number(reqCount) > 0);

  const commit = () => {
    if (!canAdd) return;
    let task;
    if (type === "count") task = { t: countingTitle, type: "count", action: action.trim(), unit: unit.trim(), max: Number(goal) };
    else if (type === "compound") task = { t: cTitle.trim(), type: "compound", rule, threshold: rule === "mOfN" ? Number(threshold) : undefined, subs: subs.slice() };
    else task = { t: aTitle.trim(), type: "achievement", watch, target, trigger, reqCount: watch === "template" ? Number(reqCount) : undefined };
    onAdd(task); reset(); setOpen(false);
  };

  if (!open) {
    return <button className="ts-special-open" onClick={() => setOpen(true)}>
      <span className="ts-special-plus">＋</span>Add a counting, compound or achievement task
    </button>;
  }

  const watchTargets = watch === "board" ? window.OYBC.watchTargets.boards : window.OYBC.watchTargets.templates;

  return (
    <div className="ts-special">
      <div className="ts-special-head">
        <span className="ts-section-k">Special task</span>
        <button className="ts-special-x" onClick={() => { reset(); setOpen(false); }}>✕</button>
      </div>
      <div className="ts-typechips">
        {["count", "compound", "achievement"].map(k => (
          <button key={k} className={"ts-typechip " + TYPE_META[k].cls + (type === k ? " on" : "")} onClick={() => setType(k)}>{TYPE_META[k].label}</button>
        ))}
      </div>

      {/* COUNTING */}
      {type === "count" && (
        <div className="ts-fields">
          <div className="ts-frow">
            <label className="ts-flabel">Action</label>
            <input className="ts-tinput" placeholder="Run" value={action} onChange={e => setAction(e.target.value)} />
          </div>
          <div className="ts-frow ts-frow-split">
            <div>
              <label className="ts-flabel">Goal</label>
              <input className="ts-tinput" type="number" value={goal} onChange={e => setGoal(e.target.value)} />
            </div>
            <div>
              <label className="ts-flabel">Unit</label>
              <input className="ts-tinput" placeholder="km" value={unit} onChange={e => setUnit(e.target.value)} />
            </div>
          </div>
          <div className="ts-preview"><span className="ts-li-tag count">Counting</span> reads as <b>{countingTitle || "Run 5 km"}</b> — tap +/− to add reps on the board.</div>
        </div>
      )}

      {/* COMPOUND */}
      {type === "compound" && (
        <div className="ts-fields">
          <div className="ts-frow">
            <label className="ts-flabel">Title</label>
            <input className="ts-tinput" placeholder="Morning routine" value={cTitle} onChange={e => setCTitle(e.target.value)} />
          </div>
          <label className="ts-flabel">Counts as done when…</label>
          <div className="ts-rulechips">
            {[["all", "All of"], ["any", "Any of"], ["mOfN", "At least N"], ["ordered", "In order"]].map(([k, l]) => (
              <button key={k} className={"ts-rulechip" + (rule === k ? " on" : "")} onClick={() => setRule(k)}>{l}</button>
            ))}
          </div>
          {rule === "mOfN" && (
            <div className="ts-frow ts-thresh">
              <label className="ts-flabel">How many?</label>
              <div className="ts-stepper2">
                <button onClick={() => setThreshold(Math.max(1, threshold - 1))}>−</button>
                <span>{threshold}</span>
                <button onClick={() => setThreshold(Math.min(Math.max(2, subs.length), threshold + 1))}>+</button>
              </div>
              <span className="ts-thresh-hint">of {subs.length || "…"} sub-tasks</span>
            </div>
          )}
          <label className="ts-flabel">Sub-tasks</label>
          {subs.length > 0 && (
            <div className="ts-subs">
              {subs.map((s, i) => (
                <span className={"ts-sub" + (s.existing ? " existing" : "")} key={i}>
                  {rule === "ordered" && <b>{i + 1}.</b>}
                  {s.type && s.type !== "normal" && <i className={"ts-sub-d " + (s.type === "count" ? "count" : "cmnd")} />}
                  {s.t}
                  <button onClick={() => setSubs(subs.filter((_, j) => j !== i))}>✕</button>
                </span>
              ))}
            </div>
          )}
          <div className="ts-subadd">
            <input className="ts-tinput" placeholder={subType === "count" ? "Action — e.g. Run" : "Add a sub-task…"} value={subText}
              onChange={e => setSubText(e.target.value)} onKeyDown={e => e.key === "Enter" && addSub()} />
            <button className="ts-subbtn" onClick={addSub} disabled={!subText.trim()}>Add</button>
          </div>
          {/* smart autocomplete — existing tasks surface as you type */}
          {subText.trim() && (() => {
            const matches = window.OYBC.taskLibrary
              .filter(l => l.type !== "compound")
              .filter(l => !subs.some(s => s.t.toLowerCase() === l.t.toLowerCase()))
              .filter(l => l.t.toLowerCase().includes(subText.toLowerCase()))
              .slice(0, 3);
            if (!matches.length) return null;
            return (
              <div className="ts-ac insub">
                {matches.map(l => (
                  <button key={l.id} className="ts-ac-row" onClick={() => { setSubs(s => [...s, { t: l.t, type: l.type, max: l.max, unit: l.unit, existing: true }]); setSubText(""); }}>
                    <span className="ts-ac-i">↩︎</span><span className="ts-ac-t">{l.t}</span>
                    {l.type === "count" && <span className="ts-subpicker-d">{l.max} {l.unit}</span>}
                    <span className="ts-ac-reuse">reuse</span>
                  </button>
                ))}
              </div>
            );
          })()}
          {/* type for a NEW typed sub */}
          <div className="ts-subtype">
            <span className="ts-subtype-l">New sub:</span>
            <button className={"ts-subtype-chip" + (subType === "normal" ? " on" : "")} onClick={() => setSubType("normal")}>Normal</button>
            <button className={"ts-subtype-chip count" + (subType === "count" ? " on" : "")} onClick={() => setSubType("count")}>Counting</button>
          </div>
          {subType === "count" && (
            <div className="ts-typecfg">
              <span>Goal</span>
              <input className="ts-mini" type="number" value={subGoal} onChange={e => setSubGoal(e.target.value)} />
              <input className="ts-mini wide" placeholder="reps" value={subUnit} onChange={e => setSubUnit(e.target.value)} />
              <span className="ts-typecfg-hint">reads as <b>{`${subText.trim() || "Run"} ${Number(subGoal) || 1} ${subUnit.trim() || "reps"}`}</b></span>
            </div>
          )}
          {subs.length < 2 && <div className="ts-hint-warn">Add at least 2 sub-tasks.</div>}
        </div>
      )}

      {/* ACHIEVEMENT */}
      {type === "achievement" && (
        <div className="ts-fields">
          <div className="ts-frow">
            <label className="ts-flabel">Title</label>
            <input className="ts-tinput" placeholder="Finish the reading challenge" value={aTitle} onChange={e => setATitle(e.target.value)} />
          </div>
          <label className="ts-flabel">Watch a…</label>
          <div className="ts-rulechips">
            {[["board", "Specific board"], ["template", "Recurring template"]].map(([k, l]) => (
              <button key={k} className={"ts-rulechip" + (watch === k ? " on" : "")} onClick={() => { setWatch(k); setTarget((k === "board" ? window.OYBC.watchTargets.boards : window.OYBC.watchTargets.templates)[0]); }}>{l}</button>
            ))}
          </div>
          <div className="ts-frow">
            <label className="ts-flabel">{watch === "board" ? "Which board" : "Which template"}</label>
            <select className="ts-tinput ts-select" value={target} onChange={e => setTarget(e.target.value)}>
              {watchTargets.map(b => <option key={b} value={b}>{b}</option>)}
            </select>
          </div>
          <label className="ts-flabel">Completes on</label>
          <div className="ts-rulechips">
            {[["greenlog", "GREENLOG"], ["bingo", "First Bingo"]].map(([k, l]) => (
              <button key={k} className={"ts-rulechip" + (trigger === k ? " on" : "")} onClick={() => setTrigger(k)}>{l}</button>
            ))}
          </div>
          {watch === "template" && (
            <div className="ts-frow ts-thresh">
              <label className="ts-flabel">How many times?</label>
              <div className="ts-stepper2">
                <button onClick={() => setReqCount(Math.max(1, reqCount - 1))}>−</button>
                <span>{reqCount}</span>
                <button onClick={() => setReqCount(reqCount + 1)}>+</button>
              </div>
              <span className="ts-thresh-hint">spawns must hit it</span>
            </div>
          )}
        </div>
      )}

      <button className="ts-special-add" onClick={commit} disabled={!canAdd}>Add to board ✦</button>
    </div>
  );
}

/* ============================================================
   TaskStep — quick-add (Normal) + special panel + library access
   libAccess: "drawer" (inline expand) | "sheet" (bottom sheet)
             | "tabs" (Create / Library mode switch)
   ============================================================ */
function TaskStep({ tasks, setTasks, size, centerType, composerStyle, libAccess = "drawer" }) {
  const need = size * size - (centerType === "none" ? 0 : 1);
  const [libOpen, setLibOpen] = React.useState(false);
  const [mode, setMode] = React.useState("create");
  const libCount = window.OYBC.taskLibrary.length;

  const addTask = (task) => setTasks(prev => [task, ...prev]);
  const removeTask = (i) => setTasks(prev => prev.filter((_, j) => j !== i));
  /* library rows toggle: add if absent, remove if present */
  const toggleLib = (task) => setTasks(prev => {
    const ix = prev.findIndex(p => p.t.toLowerCase() === task.t.toLowerCase());
    if (ix >= 0) return prev.filter((_, j) => j !== ix);
    return [task, ...prev];
  });

  const libEntryBtn = (
    <button className="ts-special-open lib" onClick={() => setLibOpen(o => !o)}>
      <span className="ts-special-plus">⌕</span>
      {libOpen && libAccess === "drawer" ? "Hide library" : `Add from your library`}
      <span className="ts-lib-count">{libCount}</span>
    </button>
  );

  /* TABS mode: segmented switch swaps the whole region */
  if (libAccess === "tabs") {
    return (
      <div className="ts-root">
        <PoolHeader count={tasks.length} need={need} />
        <div className="ts-modeseg">
          <button className={mode === "create" ? "on" : ""} onClick={() => setMode("create")}>＋ Create new</button>
          <button className={mode === "library" ? "on" : ""} onClick={() => setMode("library")}>⌕ Library <span className="ts-lib-count">{libCount}</span></button>
        </div>
        {mode === "create" ? (
          <React.Fragment>
            <ComposerA onAdd={addTask} pool={tasks} variant={composerStyle || "button"} />
            <SpecialTaskPanel onAdd={addTask} />
          </React.Fragment>
        ) : (
          <LibraryBrowser pool={tasks} onToggle={toggleLib} />
        )}
        <PoolList tasks={tasks} onRemove={removeTask} />
      </div>
    );
  }

  return (
    <div className="ts-root">
      <PoolHeader count={tasks.length} need={need} />

      <div className="ts-section-k ts-create-label">Add tasks</div>
      <ComposerA onAdd={addTask} pool={tasks} variant={composerStyle || "button"} />
      <SpecialTaskPanel onAdd={addTask} />

      {libEntryBtn}
      {libAccess === "drawer" && libOpen && (
        <div className="ts-libdrawer">
          <LibraryBrowser pool={tasks} onToggle={toggleLib} />
        </div>
      )}
      {libAccess === "sheet" && (
        <LibrarySheet open={libOpen} onClose={() => setLibOpen(false)} pool={tasks} onToggle={toggleLib}
          addedCount={tasks.filter(t => window.OYBC.taskLibrary.some(l => l.t.toLowerCase() === t.t.toLowerCase()) || t.linked || t.from).length} />
      )}

      <PoolList tasks={tasks} onRemove={removeTask} />
    </div>
  );
}

Object.assign(window, { TaskStep, ComposerA, SpecialTaskPanel });
function PoolList({ tasks, onRemove }) {
  if (tasks.length === 0) {
    return <div className="ts-pool-empty">Nothing in your pool yet — reuse a task, type your own, or add a special type.</div>;
  }
  return (
    <div className="ts-pool">
      <div className="ts-section-k">On your board <span className="ts-lib-count">{tasks.length}</span></div>
      <div className="ts-poollist">
        {tasks.map((t, i) => {
          const detail = typeDetail(t);
          return (
            <div className="ts-poolrow" key={i}>
              <span className="ts-pr-grip">⋮⋮</span>
              <div className="ts-pr-main">
                <span className="ts-pr-name">{t.t}</span>
                {detail && <span className="ts-pr-detail">{detail}</span>}
              </div>
              <span className={"ts-pr-tag " + TYPE_META[t.type].cls}>{TYPE_META[t.type].label}</span>
              <button className="ts-pr-x" onClick={() => onRemove(i)} aria-label="Remove">✕</button>
            </div>
          );
        })}
      </div>
    </div>
  );
}
