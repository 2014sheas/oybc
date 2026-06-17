/* ============================================================
   OYBC · Riso prototype — Tasks tab + Profile tab
   Mirrors TasksTabView.swift (filter controls + library list +
   compound grouping + detail/delete + create sheet) and
   ProfileView.swift (account / app / preferences / sign out).
   Exports: TasksTab, ProfileTab
   ============================================================ */

const TT_TYPE = {
  normal: { letter: "N", cls: "normal", label: "Normal" },
  count: { letter: "C", cls: "count", label: "Counting" },
  compound: { letter: "K", cls: "cmnd", label: "Compound" },
  achievement: { letter: "A", cls: "achv", label: "Achievement" },
};

function ttSubtitle(l) {
  if (l.type === "count") return `${l.action || ""} · goal ${l.max} ${l.unit}`.replace(/^ · /, "");
  if (l.type === "compound") {
    const n = (l.subs || []).length;
    const rule = l.rule === "ordered" ? "in order" : l.rule === "mOfN" ? `≥${l.threshold} of ${n}` : `all of ${n}`;
    return `${n} sub-tasks · ${rule}`;
  }
  if (l.type === "achievement") return `Watch ${l.target} · ${l.trigger === "bingo" ? "First Bingo" : "GREENLOG"}`;
  if (l.childOf && l.childOf.length) return `part of ${l.childOf[0]}`;
  return null;
}
/* active placements: derived for the prototype */
function ttActive(l) { return l.boards > 1 ? l.boards - 1 : l.boards; }

/* ---- one library row ---- */
function TTRow({ l, child, expanded, onToggleExpand, onOpen }) {
  const tm = TT_TYPE[l.type] || TT_TYPE.normal;
  const sub = ttSubtitle(l);
  const expandable = l.type === "compound" && (l.subs || []).length > 0;
  return (
    <div className={"tt-row" + (child ? " child" : "")} onClick={() => onOpen(l)}>
      <span className={"lb-badge " + tm.cls}>{tm.letter}</span>
      <div className="lb-mid">
        <span className="lb-title">{l.t}</span>
        {sub && <span className="lb-sub">{sub}</span>}
      </div>
      <div className="tt-usage">
        <span className="tt-n"><b>{l.boards}</b>{" bd" + (l.boards !== 1 ? "s" : "")}</span>
        <span className="tt-active">{ttActive(l)} active</span>
      </div>
      {expandable && (
        <button className="tt-chev" onClick={(e) => { e.stopPropagation(); onToggleExpand(l.id); }}>
          {expanded ? "▾" : "▸"}
        </button>
      )}
    </div>
  );
}

/* ---- detail bottom sheet (view + edit modes) ---- */
function TTDetail({ task, onClose, onDelete, onUpdate }) {
  const [confirming, setConfirming] = React.useState(false);
  const [editing, setEditing] = React.useState(false);
  React.useEffect(() => { setConfirming(false); setEditing(false); }, [task && task.id]);
  if (!task) return null;
  const tm = TT_TYPE[task.type] || TT_TYPE.normal;
  const sub = ttSubtitle(task);
  return (
    <div className="lb-sheetwrap">
      <div className="lb-scrim" onClick={onClose} />
      <div className="lb-sheet tt-sheet">
        <div className="lb-sheet-grab" />
        <div className="lb-sheet-head">
          <span className="lb-sheet-title">Task</span>
          <button className="lb-sheet-done" onClick={onClose}>Done</button>
        </div>
        <div className="lb-sheet-body">
          {editing ? (
            <TTEdit task={task} onCancel={() => setEditing(false)}
              onSave={(patch) => { onUpdate(task.id, patch); setEditing(false); }} />
          ) : (
          <React.Fragment>
          <div className="tt-d-top">
            <span className={"lb-badge lg " + tm.cls}>{tm.letter}</span>
            <div>
              <div className="tt-d-title">{task.t}</div>
              <span className={"ts-li-tag " + tm.cls}>{tm.label}</span>
            </div>
          </div>
          {sub && <div className="tt-d-row"><span className="ts-flabel">Details</span><span className="tt-d-val">{sub}</span></div>}
          <div className="tt-d-row">
            <span className="ts-flabel">Usage</span>
            <span className="tt-d-val">On <b>{task.boards}</b> board{task.boards !== 1 ? "s" : ""} · <b>{ttActive(task)}</b> active · used {task.uses}× all-time</span>
          </div>
          {(task.subs || []).length > 0 && (
            <div className="tt-d-row">
              <span className="ts-flabel">Sub-tasks</span>
              <div className="ts-subs">
                {task.subs.map((s, i) => (
                  <span className="ts-sub" key={i}>{task.rule === "ordered" && <b>{i + 1}.</b>}{s.t}</span>
                ))}
              </div>
            </div>
          )}
          {!confirming ? (
            <div className="tt-d-btns">
              <button className="r-btn" style={{ flex: 1 }} onClick={() => setEditing(true)}>Edit</button>
              <button className="r-btn tt-danger" style={{ flex: 1 }} onClick={() => setConfirming(true)}>Delete</button>
            </div>
          ) : (
            <div className="tt-confirm">
              <div className="tt-confirm-t">Delete “{task.t}”?</div>
              <div className="tt-confirm-s">
                {task.boards > 0
                  ? `It's on ${task.boards} board${task.boards !== 1 ? "s" : ""} — squares using it will be cleared.`
                  : "It isn't placed on any boards."}
              </div>
              <div className="tt-d-btns">
                <button className="r-btn" style={{ flex: 1 }} onClick={() => setConfirming(false)}>Cancel</button>
                <button className="r-btn tt-danger solid" style={{ flex: 1 }} onClick={() => { onDelete(task.id); onClose(); }}>Delete</button>
              </div>
            </div>
          )}
          </React.Fragment>
          )}
        </div>
      </div>
    </div>
  );
}

/* ---- edit form inside the detail sheet ---- */
function TTEdit({ task, onSave, onCancel }) {
  const [title, setTitle] = React.useState(task.t);
  const [action, setAction] = React.useState(task.action || "");
  const [goal, setGoal] = React.useState(task.max || 1);
  const [unit, setUnit] = React.useState(task.unit || "");
  const [rule, setRule] = React.useState(task.rule || "all");
  const [threshold, setThreshold] = React.useState(task.threshold || 2);
  const [subs, setSubs] = React.useState(task.subs || []);
  const [trigger, setTrigger] = React.useState(task.trigger || "greenlog");
  const tm = TT_TYPE[task.type] || TT_TYPE.normal;
  const canSave = title.trim().length > 0 && (task.type !== "compound" || subs.length >= 2);
  const save = () => {
    const patch = { t: title.trim() };
    if (task.type === "count") { patch.action = action.trim(); patch.max = Math.max(1, Number(goal) || 1); patch.unit = unit.trim(); }
    if (task.type === "compound") { patch.rule = rule; patch.subs = subs; if (rule === "mOfN") patch.threshold = Math.min(threshold, subs.length); }
    if (task.type === "achievement") { patch.trigger = trigger; }
    onSave(patch);
  };
  return (
    <div className="tt-edit">
      <div className="tt-d-top" style={{ marginBottom: 0 }}>
        <span className={"lb-badge lg " + tm.cls}>{tm.letter}</span>
        <div>
          <div className="tt-d-title">Edit task</div>
          <span className={"ts-li-tag " + tm.cls}>{tm.label}</span>
        </div>
      </div>
      <div className="ts-frow">
        <label className="ts-flabel">Title</label>
        <input className="ts-tinput" value={title} onChange={e => setTitle(e.target.value)} />
      </div>
      {task.type === "count" && (
        <React.Fragment>
          <div className="ts-frow">
            <label className="ts-flabel">Action</label>
            <input className="ts-tinput" placeholder="Run" value={action} onChange={e => setAction(e.target.value)} />
          </div>
          <div className="ts-frow ts-frow-split">
            <div>
              <label className="ts-flabel">Goal</label>
              <input className="ts-tinput" type="number" min="1" value={goal} onChange={e => setGoal(e.target.value)} />
            </div>
            <div>
              <label className="ts-flabel">Unit</label>
              <input className="ts-tinput" placeholder="km" value={unit} onChange={e => setUnit(e.target.value)} />
            </div>
          </div>
          <div className="ts-preview">reads as <b>{`${action.trim() || title.trim() || "Run"} ${Number(goal) || 1} ${unit.trim()}`.trim()}</b></div>
        </React.Fragment>
      )}
      {task.type === "compound" && (
        <React.Fragment>
          <label className="ts-flabel">Counts as done when…</label>
          <div className="lb-chips">
            {[["all", "All of"], ["any", "Any of"], ["mOfN", `At least ${threshold}`], ["ordered", "In order"]].map(([k, lab]) => (
              <button key={k} className={"lb-chip" + (rule === k ? " on" : "")}
                onClick={() => { if (k === "mOfN" && rule === "mOfN") setThreshold(t => (t % subs.length) + 1); setRule(k); }}>{lab}</button>
            ))}
          </div>
          <label className="ts-flabel">Sub-tasks ({subs.length})</label>
          <div className="ts-subs">
            {subs.map((s, i) => (
              <span className="ts-sub" key={i}>
                {rule === "ordered" && <b>{i + 1}.</b>}{s.t}
                <button className="lb-clear" style={{ marginLeft: 4 }} aria-label={"Remove " + s.t}
                  onClick={() => setSubs(ss => ss.filter((_, j) => j !== i))}>✕</button>
              </span>
            ))}
          </div>
          {subs.length < 2 && <div className="pp-hint">A compound needs at least 2 sub-tasks.</div>}
        </React.Fragment>
      )}
      {task.type === "achievement" && (
        <React.Fragment>
          <label className="ts-flabel">Completes on</label>
          <div className="lb-chips">
            {[["greenlog", "GREENLOG"], ["bingo", "First Bingo"]].map(([k, lab]) => (
              <button key={k} className={"lb-chip" + (trigger === k ? " on" : "")} onClick={() => setTrigger(k)}>{lab}</button>
            ))}
          </div>
          <div className="pp-hint">Watching <b>{task.target}</b> — change the target by recreating the task.</div>
        </React.Fragment>
      )}
      {task.boards > 0 && (
        <div className="tt-edit-note">Changes apply everywhere it's placed — updates {task.boards} board{task.boards !== 1 ? "s" : ""}.</div>
      )}
      <div className="tt-d-btns" style={{ marginTop: 4 }}>
        <button className="r-btn" style={{ flex: 1 }} onClick={onCancel}>Cancel</button>
        <button className="r-btn primary" style={{ flex: 1, opacity: canSave ? 1 : .45 }} disabled={!canSave} onClick={save}>Save</button>
      </div>
    </div>
  );
}

/* ---- create-task sheet (reuses wizard composers) ---- */
function TTCreateSheet({ open, onClose, onAdd }) {
  if (!open) return null;
  return (
    <div className="lb-sheetwrap">
      <div className="lb-scrim" onClick={onClose} />
      <div className="lb-sheet tt-sheet">
        <div className="lb-sheet-grab" />
        <div className="lb-sheet-head">
          <span className="lb-sheet-title">New task</span>
          <button className="lb-sheet-done" onClick={onClose}>Done</button>
        </div>
        <div className="lb-sheet-body">
          <div className="ts-section-k" style={{ marginBottom: 8 }}>Quick add (normal)</div>
          <ComposerA onAdd={onAdd} />
          <div style={{ height: 12 }} />
          <SpecialTaskPanel onAdd={onAdd} />
          <div className="ts-subpicker-hint" style={{ marginTop: 10 }}>Tasks created here land in your library — place them on boards from the Create tab.</div>
        </div>
      </div>
    </div>
  );
}

/* ============================================================
   TASKS TAB
   ============================================================ */
function TasksTab() {
  const [lib, setLib] = React.useState(() => window.OYBC.taskLibrary.map(l => ({ ...l })));
  const [q, setQ] = React.useState("");
  const [type, setType] = React.useState("all");
  const [sort, setSort] = React.useState("recent");
  const [expanded, setExpanded] = React.useState({});
  const [detail, setDetail] = React.useState(null);
  const [createOpen, setCreateOpen] = React.useState(false);

  const toggleExpand = (id) => setExpanded(e => ({ ...e, [id]: !e[id] }));
  const addTask = (task) => setLib(prev => [{ id: "new" + Date.now(), boards: 0, uses: 0, ...task }, ...prev]);
  const deleteTask = (id) => setLib(prev => prev.filter(l => l.id !== id));
  const updateTask = (id, patch) => {
    setLib(prev => prev.map(l => l.id === id ? { ...l, ...patch } : l));
    setDetail(d => (d && d.id === id ? { ...d, ...patch } : d));
  };

  let rows = lib;
  if (type !== "all") rows = rows.filter(l => l.type === type);
  if (q.trim()) {
    const qq = q.toLowerCase();
    // keep compounds whose children match too, so search can auto-expand them
    rows = rows.filter(l => l.t.toLowerCase().includes(qq) || (l.subs || []).some(s => s.t.toLowerCase().includes(qq)));
  }
  if (sort === "name") rows = [...rows].sort((a, b) => a.t.localeCompare(b.t));
  else if (sort === "used") rows = [...rows].sort((a, b) => b.uses - a.uses);
  /* "recent" keeps library order — new tasks are prepended */

  const findByTitle = (t) => lib.find(x => x.t.toLowerCase() === t.toLowerCase());
  // auto-expand compounds when searching (mirrors the app's effectiveExpanded)
  const isExpanded = (l) => q.trim()
    ? (l.subs || []).some(s => s.t.toLowerCase().includes(q.toLowerCase())) || !!expanded[l.id]
    : !!expanded[l.id];

  const typeChips = [["all", "All"], ["normal", "Normal"], ["count", "Counting"], ["compound", "Compound"], ["achievement", "Achievement"]];

  return (
    <React.Fragment>
      <div className="r-top">
        <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between" }}>
          <div>
            <div className="r-kicker">Your library</div>
            <h1 className="r-h1 compact">Tasks</h1>
          </div>
          <button className="r-icon-btn" onClick={() => setCreateOpen(true)} aria-label="New task"><Icon name="plus" size={22} sw={2.6} /></button>
        </div>
        <div className="tt-controls">
          <div className="lb-search">
            <span className="ts-pal-ico">⌕</span>
            <input className="ts-input bare" placeholder="Search tasks…" value={q} onChange={e => setQ(e.target.value)} />
            {q && <button className="lb-clear" onClick={() => setQ("")}>✕</button>}
          </div>
          <div className="lb-chips">
            {typeChips.map(([k, lab]) => (
              <button key={k} className={"lb-chip" + (type === k ? " on" : "")} onClick={() => setType(k)}>{lab}</button>
            ))}
          </div>
          <div className="tt-sortrow">
            <span className="ts-flabel">Sort</span>
            <button className={"ts-subtype-chip" + (sort === "recent" ? " on" : "")} onClick={() => setSort("recent")}>Recent</button>
            <button className={"ts-subtype-chip" + (sort === "used" ? " on" : "")} onClick={() => setSort("used")}>Most used</button>
            <button className={"ts-subtype-chip" + (sort === "name" ? " on" : "")} onClick={() => setSort("name")}>A–Z</button>
            <span className="tt-count">{rows.length} task{rows.length !== 1 ? "s" : ""}</span>
          </div>
        </div>
      </div>

      <div className="r-scroll">
        {rows.length === 0 ? (
          <div className="r-empty">
            <div className="r-empty-art"><Blip size={92} mood="calm" /></div>
            <h3>No matches</h3>
            <p>{lib.length ? "Try clearing the search or switching the type chip back to All." : "No tasks yet — tap + to add one."}</p>
          </div>
        ) : (
          <div className="tt-list">
            {rows.map(l => (
              <React.Fragment key={l.id}>
                <TTRow l={l} expanded={isExpanded(l)} onToggleExpand={toggleExpand} onOpen={setDetail} />
                {isExpanded(l) && (l.subs || []).map((s, i) => {
                  const full = findByTitle(s.t) || { id: l.id + "-c" + i, t: s.t, type: s.type || "normal", boards: 0, uses: 0 };
                  return <TTRow key={full.id} l={full} child onOpen={setDetail} />;
                })}
              </React.Fragment>
            ))}
            <div style={{ height: 14 }} />
          </div>
        )}
        <div className="r-fade-bottom" />
      </div>

      <TTDetail task={detail} onClose={() => setDetail(null)} onDelete={deleteTask} onUpdate={updateTask} />
      <TTCreateSheet open={createOpen} onClose={() => setCreateOpen(false)} onAdd={addTask} />
    </React.Fragment>
  );
}

/* ============================================================
   PROFILE TAB
   ============================================================ */
function PFRow({ icon, label, value, chevron, danger, onClick, badge }) {
  return (
    <button className={"pf-row" + (danger ? " danger" : "")} onClick={onClick}>
      <span className="pf-row-ico">{icon}</span>
      <span className="pf-row-l">{label}</span>
      {badge != null && <span className="ts-lib-count">{badge}</span>}
      {value && <span className="pf-row-v">{value}</span>}
      {chevron && <span className="pf-row-chev">›</span>}
    </button>
  );
}

function ProfileTab({ theme = "system", onTheme, celebration = 7, onCelebration, initialPage = null, profile, onSaveProfile }) {
  const [confirmOut, setConfirmOut] = React.useState(false);
  const [page, setPage] = React.useState(initialPage); // null | prefs | templates | pools
  const [editOpen, setEditOpen] = React.useState(false);
  const [pools, setPools] = React.useState(() => window.PP_POOLS_SEED.map(p => ({ ...p, tasks: [...p.tasks] })));
  const p = profile || { name: "OYBC User", email: "you@example.com", mood: "happy" };
  if (page === "prefs") return <BoardPrefsPage onBack={() => setPage(null)} celebration={celebration} onCelebration={onCelebration} />;
  if (page === "templates") return <TemplatesPage onBack={() => setPage(null)} pools={pools} />;
  if (page === "pools") return <PoolsPage onBack={() => setPage(null)} pools={pools} setPools={setPools} />;
  return (
    <React.Fragment>
      <div className="r-top">
        <div className="r-kicker">Account</div>
        <h1 className="r-h1 compact">Profile</h1>
      </div>
      <div className="r-scroll">
        {/* account card */}
        <div className="pf-card pf-account">
          <div className="pf-avatar"><Blip size={54} mood={p.mood} /></div>
          <div className="pf-acc-mid">
            <button className="pf-name pf-name-btn" onClick={() => setEditOpen(true)}>{p.name} <span className="pf-pencil">✎</span></button>
            <div className="pf-email">{p.email}</div>
          </div>
        </div>

        {/* app */}
        <div className="ts-section-k pf-sec">App</div>
        <div className="pf-card">
          <div className="pf-row static">
            <span className="pf-row-ico">◐</span>
            <span className="pf-row-l">Theme</span>
            <div className="pf-seg">
              {["system", "light", "dark"].map(k => (
                <button key={k} className={theme === k ? "on" : ""} onClick={() => onTheme && onTheme(k)}>{k[0].toUpperCase() + k.slice(1)}</button>
              ))}
            </div>
          </div>
          <div className="pf-row static">
            <span className="pf-row-ico">⟳</span>
            <span className="pf-row-l">Sync</span>
            <span className="pf-row-v"><span className="pf-dot ok" />Synced · just now</span>
          </div>
        </div>

        {/* preferences */}
        <div className="ts-section-k pf-sec">Preferences</div>
        <div className="pf-card">
          <PFRow icon="▦" label="Board preferences" chevron onClick={() => setPage("prefs")} />
          <PFRow icon="↻" label="Recurring templates" badge={3} chevron onClick={() => setPage("templates")} />
          <PFRow icon="▤" label="Default pools" badge={2} chevron onClick={() => setPage("pools")} />
        </div>

        {/* sign out */}
        <div className="pf-card pf-out">
          {!confirmOut ? (
            <PFRow icon="⎋" label="Sign Out" danger onClick={() => setConfirmOut(true)} />
          ) : (
            <div className="tt-confirm" style={{ padding: 12 }}>
              <div className="tt-confirm-t">Sign out?</div>
              <div className="tt-d-btns">
                <button className="r-btn" style={{ flex: 1 }} onClick={() => setConfirmOut(false)}>Cancel</button>
                <button className="r-btn tt-danger solid" style={{ flex: 1 }} onClick={() => setConfirmOut(false)}>Sign Out</button>
              </div>
            </div>
          )}
        </div>
        <div className="pf-ver">OYBC · Riso prototype</div>
        <div style={{ height: 10 }} />
        <div className="r-fade-bottom" />
      </div>
      <EditProfileSheet open={editOpen} name={p.name} email={p.email} mood={p.mood}
        onClose={() => setEditOpen(false)}
        onSave={(patch) => { onSaveProfile && onSaveProfile({ ...p, ...patch }); setEditOpen(false); }} />
    </React.Fragment>
  );
}

Object.assign(window, { TasksTab, ProfileTab });
