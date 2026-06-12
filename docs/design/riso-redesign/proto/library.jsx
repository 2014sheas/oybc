/* ============================================================
   OYBC · Riso prototype — Library browser (reuse, rich)
   Mirrors the real wizard library: type badges, "N boards"
   usage hints, tap-to-toggle, filter chips, From a board…,
   derive sub-counter on counting rows, expandable compounds.
   Exports: LibraryBrowser, LibrarySheet
   ============================================================ */

const LIB_TYPE = {
  normal: { letter: "N", cls: "normal", label: "Normal" },
  count: { letter: "C", cls: "count", label: "Counting" },
  compound: { letter: "K", cls: "cmnd", label: "Compound" },
};

function libSubtitle(l) {
  if (l.type === "count") return `${l.action || ""} · goal ${l.max} ${l.unit}`.replace(/^ · /, "");
  if (l.type === "compound") {
    const names = (l.subs || []).map(s => s.t);
    const head = names.slice(0, 2).join(", ");
    const more = names.length > 2 ? `, +${names.length - 2} more` : "";
    const rule = l.rule === "ordered" ? "in order" : l.rule === "mOfN" ? `≥${l.threshold} of ${names.length}` : `all of ${names.length}`;
    return `${rule} — ${head}${more}`;
  }
  if (l.childOf && l.childOf.length) return `part of ${l.childOf[0]}`;
  return null;
}

/* one library row */
function LibRow({ l, added, onToggle, onDerive, onAddChild, poolHas }) {
  const [expanded, setExpanded] = React.useState(false);
  const [deriving, setDeriving] = React.useState(false);
  const [dGoal, setDGoal] = React.useState(Math.max(1, Math.round((l.max || 10) / 5)));
  const sub = libSubtitle(l);
  const tm = LIB_TYPE[l.type] || LIB_TYPE.normal;
  const canDerive = l.type === "count";
  const canExpand = l.type === "compound" && (l.subs || []).length > 0;

  const commitDerive = () => {
    const title = `${l.action} ${dGoal} ${l.unit}`;
    onDerive({ t: title, type: "count", action: l.action, max: Number(dGoal), unit: l.unit, linked: l.t });
    setDeriving(false);
  };

  return (
    <div className={"lb-row" + (added ? " added" : "")}>
      <div className="lb-row-main" onClick={() => onToggle(l)}>
        <span className="lb-bar" />
        <span className={"lb-badge " + tm.cls}>{tm.letter}</span>
        <div className="lb-mid">
          <span className="lb-title">{l.t}</span>
          {sub && <span className="lb-sub">{sub}</span>}
        </div>
        <span className="lb-usage">{l.boards} bd{l.boards !== 1 ? "s" : ""}</span>
        <span className="lb-state">{added ? "✓" : "＋"}</span>
      </div>

      {(canDerive || canExpand) && (
        <div className="lb-row-actions">
          {canDerive && !deriving && (
            <button className="lb-act" onClick={() => setDeriving(true)}>⇲ Derive smaller</button>
          )}
          {canExpand && (
            <button className="lb-act" onClick={() => setExpanded(e => !e)}>
              {expanded ? "▾" : "▸"} {(l.subs || []).length} sub-tasks
            </button>
          )}
        </div>
      )}

      {deriving && (
        <div className="lb-derive">
          <span className="lb-derive-l">{l.action}</span>
          <div className="ts-stepper2">
            <button onClick={() => setDGoal(g => Math.max(1, Number(g) - 1))}>−</button>
            <span>{dGoal}</span>
            <button onClick={() => setDGoal(g => Number(g) + 1)}>+</button>
          </div>
          <span className="lb-derive-l">{l.unit}</span>
          <button className="lb-derive-add" onClick={commitDerive}>Add ↔</button>
          <button className="lb-derive-x" onClick={() => setDeriving(false)}>✕</button>
        </div>
      )}
      {deriving && <div className="lb-derive-hint">Linked to “{l.t}” — progress counts up the shared counter.</div>}

      {expanded && (
        <div className="lb-children">
          {(l.subs || []).map((s, i) => {
            const has = poolHas(s.t);
            return (
              <button key={i} className={"lb-child" + (has ? " added" : "")} disabled={has}
                onClick={() => onAddChild({ t: s.t, type: "normal" })}>
                {l.rule === "ordered" && <b>{i + 1}.</b>} {s.t} <span>{has ? "✓" : "＋"}</span>
              </button>
            );
          })}
          <div className="lb-children-hint">Sub-tasks are real tasks — add one on its own.</div>
        </div>
      )}
    </div>
  );
}

/* board picker for "From a board…" */
function FromBoard({ pool, onToggle, poolHas }) {
  const [boardId, setBoardId] = React.useState(null);
  const boards = window.OYBC.sourceBoards;
  const lib = window.OYBC.taskLibrary;

  if (!boardId) {
    return (
      <div className="lb-boards">
        {boards.map(b => (
          <button key={b.id} className="lb-board" onClick={() => setBoardId(b.id)}>
            <div className="lb-board-mid">
              <span className="lb-title">{b.name}</span>
              <span className="lb-sub">{b.tf} · {b.tasks.length} tasks</span>
            </div>
            <span className="lb-board-go">›</span>
          </button>
        ))}
      </div>
    );
  }

  const board = boards.find(b => b.id === boardId);
  return (
    <div className="lb-boardtasks">
      <button className="lb-backrow" onClick={() => setBoardId(null)}>‹ All boards</button>
      {board.tasks.map(name => {
        const l = lib.find(x => x.t === name) || { t: name, type: "normal", boards: 1 };
        return (
          <LibRow key={name} l={l} added={poolHas(l.t)}
            onToggle={(x) => onToggle({ ...x, from: board.name })}
            onDerive={(x) => onToggle({ ...x, from: board.name })}
            onAddChild={(x) => onToggle({ ...x, from: board.name })}
            poolHas={poolHas} />
        );
      })}
    </div>
  );
}

/* the full browser: search + filter chips + list */
function LibraryBrowser({ pool, onToggle, maxH }) {
  const [q, setQ] = React.useState("");
  const [filter, setFilter] = React.useState("all");
  const lib = window.OYBC.taskLibrary;
  const poolHas = (name) => pool.some(p => p.t.toLowerCase() === name.toLowerCase());

  const chips = [["all", "All"], ["normal", "Normal"], ["count", "Counting"], ["compound", "Compound"], ["board", "From a board…"]];
  let rows = lib;
  if (filter !== "all" && filter !== "board") rows = rows.filter(l => l.type === filter);
  if (q.trim()) rows = rows.filter(l => l.t.toLowerCase().includes(q.toLowerCase()));

  return (
    <div className="lb">
      <div className="lb-search">
        <span className="ts-pal-ico">⌕</span>
        <input className="ts-input bare" placeholder="Search your library…" value={q} onChange={e => setQ(e.target.value)} />
        {q && <button className="lb-clear" onClick={() => setQ("")}>✕</button>}
      </div>
      <div className="lb-chips">
        {chips.map(([k, lab]) => (
          <button key={k} className={"lb-chip" + (filter === k ? " on" : "")} onClick={() => setFilter(k)}>{lab}</button>
        ))}
      </div>
      <div className="lb-list" style={maxH ? { maxHeight: maxH, overflowY: "auto" } : null}>
        {filter === "board" ? (
          <FromBoard pool={pool} onToggle={onToggle} poolHas={poolHas} />
        ) : rows.length === 0 ? (
          <div className="lb-none">No matches{q ? ` for “${q}”` : ""}.</div>
        ) : (
          rows.map(l => (
            <LibRow key={l.id} l={l} added={poolHas(l.t)} onToggle={onToggle}
              onDerive={onToggle} onAddChild={onToggle} poolHas={poolHas} />
          ))
        )}
      </div>
    </div>
  );
}

/* bottom-sheet wrapper */
function LibrarySheet({ open, onClose, pool, onToggle, addedCount }) {
  if (!open) return null;
  return (
    <div className="lb-sheetwrap">
      <div className="lb-scrim" onClick={onClose} />
      <div className="lb-sheet">
        <div className="lb-sheet-grab" />
        <div className="lb-sheet-head">
          <span className="lb-sheet-title">Your library</span>
          <button className="lb-sheet-done" onClick={onClose}>Done{addedCount > 0 ? ` · ${addedCount}` : ""}</button>
        </div>
        <div className="lb-sheet-body">
          <LibraryBrowser pool={pool} onToggle={onToggle} />
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { LibraryBrowser, LibrarySheet });
