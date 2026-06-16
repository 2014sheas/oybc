/* ============================================================
   OYBC · Riso prototype — Profile sub-pages
   Board preferences · Recurring templates · Default pools
   Pushed screens inside the Profile tab (back square header).
   Exports: BoardPrefsPage, TemplatesPage, PoolsPage
   ============================================================ */

/* ---- shared sub-page chrome ---- */
function PPShell({ title, onBack, children }) {
  return (
    <React.Fragment>
      <div className="r-top">
        <div className="pp-head">
          <button className="r-back" onClick={onBack} aria-label="Back to Profile"><Icon name="back" size={18} sw={2.4} /></button>
          <div style={{ flex: 1, marginLeft: 12 }}>
            <div className="r-kicker">Profile</div>
            <div className="r-h2" style={{ marginTop: 3 }}>{title}</div>
          </div>
        </div>
      </div>
      <div className="r-scroll">
        {children}
        <div style={{ height: 16 }}></div>
        <div className="r-fade-bottom"></div>
      </div>
    </React.Fragment>
  );
}

function PPSwitch({ on, onChange }) {
  return (
    <button className={"pp-switch" + (on ? " on" : "")} role="switch" aria-checked={on} onClick={() => onChange(!on)}><i></i></button>
  );
}

/* stacked row: label + hint + segmented / control below */
function PPSegRow({ label, hint, options, value, onChange }) {
  return (
    <div className="pp-row">
      <div className="pp-row-top">
        <span className="pf-row-l">{label}</span>
        <div className="pf-seg" style={{ marginLeft: "auto" }}>
          {options.map(([k, lab]) => (
            <button key={k} className={value === k ? "on" : ""} onClick={() => onChange(k)}>{lab}</button>
          ))}
        </div>
      </div>
      {hint && <div className="pp-hint">{hint}</div>}
    </div>
  );
}

function PPToggleRow({ icon, label, hint, on, onChange }) {
  return (
    <div className="pp-row">
      <div className="pp-row-top">
        <span className="pf-row-ico">{icon}</span>
        <span className="pf-row-l">{label}</span>
        <PPSwitch on={on} onChange={onChange} />
      </div>
      {hint && <div className="pp-hint">{hint}</div>}
    </div>
  );
}

/* ============================================================
   1 · BOARD PREFERENCES — defaults for new boards + play feel
   ============================================================ */
const PP_INTENSITY_WORDS = ["Whisper", "Whisper", "Quiet", "Quiet", "Steady", "Steady", "Full press", "Full press", "Loud", "Detonate"];

function BoardPrefsPage({ onBack, celebration, onCelebration }) {
  const [size, setSize] = React.useState("5");
  const [center, setCenter] = React.useState("free");
  const [weekStart, setWeekStart] = React.useState("mon");
  const [haptics, setHaptics] = React.useState(true);
  const [expireWarn, setExpireWarn] = React.useState(true);
  const [autoArchive, setAutoArchive] = React.useState(false);
  return (
    <PPShell title="Board preferences" onBack={onBack}>
      <div className="ts-section-k pf-sec">New boards</div>
      <div className="pf-card">
        <PPSegRow label="Default size" value={size} onChange={setSize}
          options={[["3", "3×3"], ["4", "4×4"], ["5", "5×5"]]} />
        <PPSegRow label="Center square" value={center} onChange={setCenter}
          options={[["free", "Free"], ["pick", "Choose"], ["none", "None"]]} />
        <PPSegRow label="Week starts" value={weekStart} onChange={setWeekStart}
          hint="Sets when weekly boards reset and renew."
          options={[["mon", "Mon"], ["sun", "Sun"]]} />
      </div>

      <div className="ts-section-k pf-sec">Playing</div>
      <div className="pf-card">
        <div className="pp-row">
          <div className="pp-row-top">
            <span className="pf-row-ico">✦</span>
            <span className="pf-row-l">Celebration intensity</span>
            <span className="pp-tickval">{celebration} · {PP_INTENSITY_WORDS[celebration - 1]}</span>
          </div>
          <div className="pp-ticks">
            {Array.from({ length: 10 }, (_, i) => (
              <button key={i} aria-label={"Intensity " + (i + 1)}
                className={(i < celebration ? "on" : "") + (i >= 7 && i < celebration ? " hot" : "")}
                onClick={() => onCelebration(i + 1)}></button>
            ))}
          </div>
          <div className="pp-hint">How loud bingos and GREENLOGs get — confetti scales with it.</div>
        </div>
        <PPToggleRow icon="◌" label="Haptics" on={haptics} onChange={setHaptics} />
      </div>

      <div className="ts-section-k pf-sec">Housekeeping</div>
      <div className="pf-card">
        <PPToggleRow icon="!" label="Expiring reminders" hint="Nudge me the day before a board runs out."
          on={expireWarn} onChange={setExpireWarn} />
        <PPToggleRow icon="▣" label="Auto-archive completed" hint="Move GREENLOGed boards out of the list after a week."
          on={autoArchive} onChange={setAutoArchive} />
      </div>

      <div className="pp-foot">Defaults apply to new boards — existing boards keep their settings.</div>
    </PPShell>
  );
}

/* ---- shared timeframe + pool seed data ---- */
const PP_TFS = [["Daily", "gold"], ["Weekly", "blue"], ["Monthly", "green"], ["Yearly", "red"]];
const PP_TF_CLS = { Daily: "gold", Weekly: "blue", Monthly: "green", Yearly: "red" };
const PP_DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const PP_DOMS = ["the 1st", "the 15th", "the last day"];

const PP_POOLS_SEED = [
  { id: "p1", name: "Weekly staples", feeds: "Weekly", feedsCls: "blue",
    tasks: ["Meditate 10 min", "Drink water", "Read 30 min", "10k steps", "Journal", "Stretch", "Sleep 8h", "Cook at home", "Call a friend", "Tidy space", "No phone in bed", "Gratitude note", "Walk outside", "Plan tomorrow"] },
  { id: "p2", name: "Daily non-negotiables", feeds: "Daily", feedsCls: "gold",
    tasks: ["Make bed", "Stretch", "Floss", "Sunlight 15 min", "Vitamins", "Water on waking"] },
];

function renewText(tf, day, dom) {
  if (tf === "Weekly") return day + "s";
  if (tf === "Monthly") return dom;
  if (tf === "Yearly") return "Jan 1";
  return "every morning";
}

/* ============================================================
   2 · RECURRING TEMPLATES — rebuild a core board each cycle
   ============================================================ */
const PP_TEMPLATES = [
  { id: "t1", name: "Daily Routine", tf: "Daily", size: "3×3", poolId: "p2", day: "Monday", dom: "the 1st", on: true },
  { id: "t2", name: "Weekly Reset", tf: "Weekly", size: "5×5", poolId: "p1", day: "Monday", dom: "the 1st", on: true },
  { id: "t3", name: "Monthly Goals", tf: "Monthly", size: "5×5", poolId: "p1", day: "Monday", dom: "the 1st", on: false },
];

function TemplatesPage({ onBack, pools }) {
  const [tpls, setTpls] = React.useState(PP_TEMPLATES);
  const [edit, setEdit] = React.useState(null); // null | {} (new) | template (edit)
  const poolOf = (id) => pools.find(p => p.id === id) || pools[0];
  const toggle = (id) => setTpls(ts => ts.map(t => t.id === id ? { ...t, on: !t.on } : t));
  const save = (tpl) => {
    if (tpl.id) setTpls(ts => ts.map(t => t.id === tpl.id ? tpl : t));
    else setTpls(ts => [...ts, { ...tpl, id: "t" + Date.now() }]);
    setEdit(null);
  };
  const remove = (id) => { setTpls(ts => ts.filter(t => t.id !== id)); setEdit(null); };
  return (
    <PPShell title="Recurring templates" onBack={onBack}>
      <div className="pp-cap">Templates press a fresh core board each cycle — same pool, reshuffled squares.</div>
      <div className="pp-stack">
        {tpls.map(t => {
          const pool = poolOf(t.poolId);
          return (
            <div className={"pp-card tap" + (t.on ? "" : " off")} key={t.id} onClick={() => setEdit(t)}>
              <div className="pp-card-top">
                <span className="pp-card-name">{t.name}</span>
                <span className={"pp-tag " + PP_TF_CLS[t.tf]}>{t.tf}</span>
                <span onClick={(e) => e.stopPropagation()}><PPSwitch on={t.on} onChange={() => toggle(t.id)} /></span>
              </div>
              <div className="pp-meta">
                <span><b>{t.size}</b> board</span>·<span><b>{pool.tasks.length}</b>-task pool</span>·
                <span>{t.on ? "renews " + renewText(t.tf, t.day, t.dom) : "paused"}</span>
              </div>
            </div>
          );
        })}
      </div>
      <button className="pp-dashedbtn" onClick={() => setEdit({})}>＋ New template</button>
      <div className="pp-foot">Pausing a template keeps its pool — it just stops printing new boards.</div>
      <TemplateEditSheet open={!!edit} initial={edit} pools={pools}
        onClose={() => setEdit(null)} onSave={save} onDelete={remove} />
    </PPShell>
  );
}

function TemplateEditSheet({ open, initial, pools, onClose, onSave, onDelete }) {
  const editing = !!(initial && initial.id);
  const [name, setName] = React.useState("");
  const [tf, setTf] = React.useState("Weekly");
  const [size, setSize] = React.useState("5×5");
  const [poolId, setPoolId] = React.useState(pools[0].id);
  const [day, setDay] = React.useState("Monday");
  const [dom, setDom] = React.useState("the 1st");
  const [on, setOn] = React.useState(true);
  React.useEffect(() => {
    if (!open) return;
    const i = initial || {};
    setName(i.name || ""); setTf(i.tf || "Weekly"); setSize(i.size || "5×5");
    setPoolId(i.poolId || pools[0].id); setDay(i.day || "Monday"); setDom(i.dom || "the 1st");
    setOn(i.on != null ? i.on : true);
  }, [open]); // eslint-disable-line
  if (!open) return null;
  const pool = pools.find(p => p.id === poolId) || pools[0];
  const canSave = name.trim().length > 0;
  const submit = () => onSave({ ...(initial || {}), name: name.trim(), tf, size, poolId, day, dom, on });
  return (
    <div className="lb-sheetwrap">
      <div className="lb-scrim" onClick={onClose} />
      <div className="lb-sheet tt-sheet">
        <div className="lb-sheet-grab" />
        <div className="lb-sheet-head">
          <span className="lb-sheet-title">{editing ? "Edit template" : "New template"}</span>
          <button className="lb-sheet-done" onClick={onClose}>Close</button>
        </div>
        <div className="lb-sheet-body">
          <div className="ppe-field">
            <label className="ts-flabel">Name</label>
            <input className="ts-tinput" value={name} onChange={e => setName(e.target.value)} placeholder="e.g. Weekly Reset" autoFocus />
          </div>
          <div className="ppe-field">
            <label className="ts-flabel">Timeframe</label>
            <div className="ppe-seg tone">
              {PP_TFS.map(([k, cls]) => (
                <button key={k} className={tf === k ? "on " + cls : ""} onClick={() => setTf(k)}>{k}</button>
              ))}
            </div>
          </div>
          <div className="ppe-field">
            <label className="ts-flabel">Board size</label>
            <div className="ppe-seg">
              {["3×3", "4×4", "5×5"].map(k => (
                <button key={k} className={size === k ? "on" : ""} onClick={() => setSize(k)}>{k}</button>
              ))}
            </div>
          </div>
          {tf === "Weekly" && (
            <div className="ppe-field">
              <label className="ts-flabel">Renews on</label>
              <div className="ppe-seg ppe-days">
                {PP_DAYS.map(d => (
                  <button key={d} className={day === d ? "on" : ""} onClick={() => setDay(d)}>{d.slice(0, 1)}</button>
                ))}
              </div>
            </div>
          )}
          {tf === "Monthly" && (
            <div className="ppe-field">
              <label className="ts-flabel">Renews on</label>
              <div className="ppe-seg">
                {PP_DOMS.map(d => (
                  <button key={d} className={dom === d ? "on" : ""} onClick={() => setDom(d)}>{d.replace("the ", "")}</button>
                ))}
              </div>
            </div>
          )}
          <div className="ppe-field">
            <label className="ts-flabel">Deals from pool</label>
            <div className="ppe-seg">
              {pools.map(p => (
                <button key={p.id} className={poolId === p.id ? "on" : ""} onClick={() => setPoolId(p.id)}>{p.name}</button>
              ))}
            </div>
          </div>
          <div className="pp-row" style={{ padding: "14px 0 0" }}>
            <div className="pp-row-top">
              <span className="pf-row-l">Start active</span>
              <PPSwitch on={on} onChange={setOn} />
            </div>
            <div className="pp-hint">Paused templates keep their pool but stop printing boards.</div>
          </div>
          <div className="ppe-preview">
            <b>{size}</b> board · <b>{pool.tasks.length}</b>-task pool · renews <b>{renewText(tf, day, dom)}</b>
          </div>
          <div className="ppe-btns">
            <button className="r-btn" style={{ flex: 1 }} onClick={onClose}>Cancel</button>
            <button className="r-btn primary" style={{ flex: 1, opacity: canSave ? 1 : .45 }} disabled={!canSave} onClick={submit}>{editing ? "Save" : "Create template"}</button>
          </div>
          {editing && <button className="ppe-del" onClick={() => onDelete(initial.id)}>Delete template</button>}
        </div>
      </div>
    </div>
  );
}

/* ============================================================
   3 · DEFAULT POOLS — tasks that shuffle into core boards
   ============================================================ */
function PoolsPage({ onBack, pools, setPools }) {
  const [edit, setEdit] = React.useState(null);
  const save = (pool) => {
    if (pool.id) setPools(ps => ps.map(p => p.id === pool.id ? pool : p));
    else setPools(ps => [...ps, { ...pool, id: "p" + Date.now() }]);
    setEdit(null);
  };
  const remove = (id) => { setPools(ps => ps.filter(p => p.id !== id)); setEdit(null); };
  return (
    <PPShell title="Default pools" onBack={onBack}>
      <div className="pp-cap">When a core board renews, its squares are dealt from these pools. Extras shuffle into the mix each cycle.</div>
      <div className="pp-stack">
        {pools.map(p => (
          <div className="pp-card tap" key={p.id} onClick={() => setEdit(p)}>
            <div className="pp-card-top">
              <span className="pp-card-name">{p.name}</span>
              <span className={"pp-tag " + p.feedsCls}>feeds {p.feeds}</span>
              <span className="pp-edit-ico">✎</span>
            </div>
            <div className="pp-chips">
              {p.tasks.slice(0, 5).map((c, i) => <span className="ts-sub" key={i}>{c}</span>)}
              {p.tasks.length > 5 && <span className="pp-more">+{p.tasks.length - 5} more</span>}
            </div>
            <div className="pp-meta"><span><b>{p.tasks.length}</b> tasks</span>·<span>tap to edit</span></div>
          </div>
        ))}
      </div>
      <button className="pp-dashedbtn" onClick={() => setEdit({})}>＋ New pool</button>
      <PoolEditSheet open={!!edit} initial={edit} onClose={() => setEdit(null)} onSave={save} onDelete={remove} />
    </PPShell>
  );
}

function PoolEditSheet({ open, initial, onClose, onSave, onDelete }) {
  const editing = !!(initial && initial.id);
  const [name, setName] = React.useState("");
  const [feeds, setFeeds] = React.useState("Weekly");
  const [tasks, setTasks] = React.useState([]);
  const [draft, setDraft] = React.useState("");
  React.useEffect(() => {
    if (!open) return;
    const i = initial || {};
    setName(i.name || ""); setFeeds(i.feeds || "Weekly"); setTasks(i.tasks ? [...i.tasks] : []); setDraft("");
  }, [open]); // eslint-disable-line
  if (!open) return null;
  const add = () => { const v = draft.trim(); if (!v) return; setTasks(t => [...t, v]); setDraft(""); };
  const canSave = name.trim().length > 0 && tasks.length > 0;
  const submit = () => onSave({ ...(initial || {}), name: name.trim(), feeds, feedsCls: PP_TF_CLS[feeds], tasks });
  return (
    <div className="lb-sheetwrap">
      <div className="lb-scrim" onClick={onClose} />
      <div className="lb-sheet tt-sheet">
        <div className="lb-sheet-grab" />
        <div className="lb-sheet-head">
          <span className="lb-sheet-title">{editing ? "Edit pool" : "New pool"}</span>
          <button className="lb-sheet-done" onClick={onClose}>Close</button>
        </div>
        <div className="lb-sheet-body">
          <div className="ppe-field">
            <label className="ts-flabel">Name</label>
            <input className="ts-tinput" value={name} onChange={e => setName(e.target.value)} placeholder="e.g. Weekly staples" autoFocus />
          </div>
          <div className="ppe-field">
            <label className="ts-flabel">Feeds</label>
            <div className="ppe-seg tone">
              {PP_TFS.map(([k, cls]) => (
                <button key={k} className={feeds === k ? "on " + cls : ""} onClick={() => setFeeds(k)}>{k}</button>
              ))}
            </div>
          </div>
          <div className="ppe-field">
            <label className="ts-flabel">Tasks ({tasks.length})</label>
            <div className="ppe-tasks">
              {tasks.map((t, i) => (
                <span className="ppe-task" key={i}>{t}
                  <button aria-label={"Remove " + t} onClick={() => setTasks(ts => ts.filter((_, j) => j !== i))}>✕</button>
                </span>
              ))}
              {tasks.length === 0 && <span className="pp-hint">Add a few tasks — boards deal their squares from this list.</span>}
            </div>
            <div className="ppe-addrow">
              <input className="ts-tinput" value={draft} onChange={e => setDraft(e.target.value)}
                onKeyDown={e => { if (e.key === "Enter") add(); }} placeholder="Add a task…" />
              <button className="ppe-add" disabled={!draft.trim()} onClick={add}>Add</button>
            </div>
          </div>
          <div className="ppe-preview">
            Feeds <b>{feeds}</b> boards · <b>{tasks.length}</b> task{tasks.length !== 1 ? "s" : ""} in the deck
          </div>
          <div className="ppe-btns">
            <button className="r-btn" style={{ flex: 1 }} onClick={onClose}>Cancel</button>
            <button className="r-btn primary" style={{ flex: 1, opacity: canSave ? 1 : .45 }} disabled={!canSave} onClick={submit}>{editing ? "Save" : "Create pool"}</button>
          </div>
          {editing && <button className="ppe-del" onClick={() => onDelete(initial.id)}>Delete pool</button>}
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { BoardPrefsPage, TemplatesPage, PoolsPage, PP_POOLS_SEED });
