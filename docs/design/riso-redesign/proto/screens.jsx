/* ============================================================
   OYBC · Riso prototype — screens
   Exports to window: computeLines, PlayBoard, BoardsHome, Wizard, Greenlog
   ============================================================ */

/* ---- bingo line detection (rows, cols, diagonals) ---- */
function computeLines(cells, size = 5) {
  const done = cells.map(c => !!c.done);
  const lines = [];
  for (let r = 0; r < size; r++) lines.push(Array.from({ length: size }, (_, c) => r * size + c));
  for (let c = 0; c < size; c++) lines.push(Array.from({ length: size }, (_, r) => r * size + c));
  lines.push(Array.from({ length: size }, (_, i) => i * size + i));
  lines.push(Array.from({ length: size }, (_, i) => i * size + (size - 1 - i)));
  const complete = lines.filter(ln => ln.every(i => done[i]));
  const cellSet = new Set();
  complete.forEach(ln => ln.forEach(i => cellSet.add(i)));
  return { count: complete.length, cellSet };
}

/* ============================================================
   PLAY BOARD  (priority)
   ============================================================ */
function PlayBoard({ board, cells, lineCells, onToggle, onCount, onBack, serial }) {
  const [stepper, setStepper] = React.useState(null); // index of counting/compound cell
  const doneCount = cells.filter(c => c.done).length;
  const total = cells.length;
  const pct = Math.round(doneCount / total * 100);
  const { count: bingos } = computeLines(cells);

  const handleCell = (i, c) => {
    if (c.type === "free") return;
    if (c.type === "count" || c.type === "compound") {
      setStepper(stepper === i ? null : i);
    } else {
      onToggle(i);
    }
  };

  const stepCell = stepper != null ? cells[stepper] : null;

  return (
    <React.Fragment>
      <div className="r-top">
        <div className="r-play-head">
          <button className="r-back" onClick={onBack} aria-label="Back"><Icon name="back" size={18} sw={2.4} /></button>
          <div style={{ flex: 1, marginLeft: 12 }}>
            <div className="r-kicker">Weekly board</div>
            <div className="r-h2" style={{ marginTop: 3 }}>{board.name}</div>
          </div>
          <span className="r-badge active" style={{ marginTop: 4 }}>Active</span>
        </div>
      </div>

      <div className="r-scroll">
        <div className="r-statbar">
          <div className="r-stat">
            <div className="r-stat-k">Squares</div>
            <div className="r-stat-v">{doneCount}<span style={{ color: "var(--muted)", fontSize: 13 }}>/{total}</span></div>
            <div className="r-progress" style={{ height: 9, margin: "7px 0 0" }}><i style={{ width: pct + "%" }} /></div>
          </div>
          <div className="r-stat">
            <div className="r-stat-k">Left</div>
            <div className="r-stat-v">{board.tf.includes("days") ? "4" : "1"}<span style={{ color: "var(--muted)", fontSize: 13 }}>d</span></div>
            <div style={{ fontSize: 10, fontWeight: 700, color: "var(--muted)", marginTop: 6 }}>to fill it</div>
          </div>
          <div className="r-stat bingo">
            <div className="r-stat-k">Bingos</div>
            <div className="r-stat-v"><span className="star-s" />{bingos}</div>
          </div>
        </div>

        <div className="r-grid">
          {cells.map((c, i) => {
            const cls = ["r-cell"];
            if (c.type === "free") cls.push("free");
            if (c.type === "count") cls.push("count");
            if (c.type === "compound") cls.push("cmnd");
            if (c.done) cls.push("done");
            if (c.justDone) cls.push("just");
            if (lineCells.has(i)) cls.push("line");
            return (
              <div key={i} className={cls.join(" ")} onClick={() => handleCell(i, c)}>
                {serial && c.type !== "free" && <span className="r-serial">{String(i + 1).padStart(2, "0")}</span>}
                {c.type === "free" && <div className="star-c" />}
                {c.type === "count" && <span className="r-cell-tag count">×{c.max}</span>}
                {c.type === "compound" && <span className="r-cell-tag cmnd">C</span>}
                <div className="r-cell-t">{c.t}</div>
                {(c.type === "count" || c.type === "compound") && (
                  <div className={"r-cbar" + (c.type === "compound" ? " cmnd" : "")}>
                    <i style={{ width: Math.round((c.cur / c.max) * 100) + "%" }} />
                    <span>{c.cur}/{c.max}</span>
                  </div>
                )}
                {c.done && <div className="r-cell-check"><Icon name="check" size={8} sw={2.6} /></div>}
              </div>
            );
          })}
        </div>
        <div style={{ height: 14 }} />
      </div>

      {/* counting stepper popover */}
      {stepCell && (
        <React.Fragment>
          <div style={{ position: "absolute", inset: 0, zIndex: 55 }} onClick={() => setStepper(null)} />
          <div style={{ position: "absolute", left: 0, right: 0, bottom: 88, zIndex: 60, display: "flex", flexDirection: "column", alignItems: "center", gap: 10, pointerEvents: "none" }}>
            <div style={{ pointerEvents: "auto", background: "var(--ink)", color: "var(--paper)", fontFamily: "var(--font-head)", fontWeight: 800, fontSize: 13, padding: "6px 14px", borderRadius: 999, letterSpacing: ".02em" }}>
              {stepCell.t} · {stepCell.cur}/{stepCell.max} {stepCell.unit}
            </div>
            <div className="r-stepper" style={{ pointerEvents: "auto" }}>
              <button onClick={() => onCount(stepper, -1)}>−</button>
              <div className="r-step-v">{stepCell.cur}/{stepCell.max}</div>
              <button onClick={() => onCount(stepper, +1)}>+</button>
            </div>
          </div>
        </React.Fragment>
      )}
    </React.Fragment>
  );
}

/* ============================================================
   BOARDS HOME
   ============================================================ */
function MiniGrid({ fill, size }) {
  // render as 5-col regardless; pad/truncate
  return (
    <div className="r-mini">
      {fill.slice(0, 25).map((f, i) => <i key={i} className={f ? "on" : ""} />)}
    </div>
  );
}

function BoardCard({ b, onOpen }) {
  const fill = b.cells ? b.cells.map(c => (c.done ? 1 : 0)) : (b.miniFill || []);
  const done = b.cells ? b.cells.filter(c => c.done).length : (b.done || 0);
  const total = b.cells ? b.cells.length : (b.total || 25);
  const pct = Math.round(done / total * 100);
  const badge = b.expiring && b.status === "active" ? "expiring" : b.status;
  const badgeLabel = b.expiring && b.status === "active" ? "Expiring" : b.status;
  return (
    <div className="r-bcard" onClick={() => onOpen(b)}>
      <div className="r-bcard-top">
        <div className="r-bcard-l">
          <div className="r-bcard-name" style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{b.name}</div>
          <div className="r-bcard-tf">{b.tf}</div>
        </div>
        <div style={{ display: "flex", flexDirection: "column", alignItems: "flex-end", gap: 9 }}>
          <span className={"r-badge " + badge}>{badgeLabel}</span>
          <MiniGrid fill={fill} size={b.size} />
        </div>
      </div>
      <div className={"r-progress" + (b.status === "completed" ? " green" : "")}><i style={{ width: pct + "%" }} /></div>
      <div className="r-bcard-meta">
        <span>{done}/{total} squares</span>
        {b.bingos > 0 && <React.Fragment><span>·</span><span className="bingo"><span className="star" />{b.bingos + " bingo" + (b.bingos > 1 ? "s" : "")}</span></React.Fragment>}
      </div>
    </div>
  );
}

/* timeframe count helper (filter-rail filtering) */
function tfCount(boards, key) { return boards.filter(b => b.tfKey === key).length; }

/* the timeframe core-board strip — three visual layouts (rail / four / grid) */
function TimeframeStrip({ layout }) {
  const tfs = window.OYBC.timeframes;
  const shown = layout === "rail" ? tfs : tfs.slice(0, 4); // four/grid show first 4
  return (
    <div className={"r-core " + layout}>
      {shown.map(tf => (
        <div key={tf.key} className="r-core-card">
          <div className="r-core-k">{tf.label}</div>
          <div className="r-core-v"><span className={"r-core-dot " + tf.state} />{tf.status}</div>
        </div>
      ))}
    </div>
  );
}

function BoardsHome({ boards, onOpen, onCreate, topLayout = "rail", compactHeader = false }) {
  const [filter, setFilter] = React.useState("Active");          // status axis
  const [tfFilter, setTfFilter] = React.useState("all");          // timeframe axis (filter-rail mode)
  const filters = ["All", "Active", "Completed", "Draft"];
  const isFilterRail = topLayout === "filter";

  const shown = isFilterRail
    ? boards.filter(b => tfFilter === "all" ? true : b.tfKey === tfFilter)
    : boards.filter(b => filter === "All" ? true : b.status === filter.toLowerCase());

  return (
    <div className="r-home-wrap">
      <div className="r-scroll r-home">
        <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between" }}>
          <div>
            <div className="r-kicker">Your boards</div>
            {compactHeader
              ? <h1 className="r-h1 compact">Your boards.</h1>
              : <h1 className="r-h1">BINGO,<br />but make it<br />your goals.</h1>}
          </div>
          <button className="r-icon-btn" onClick={onCreate} aria-label="New board"><Icon name="plus" size={22} sw={2.6} /></button>
        </div>

        {isFilterRail ? (
          <React.Fragment>
            <div className="r-tfrail">
              <button className={"r-chip" + (tfFilter === "all" ? " on" : "")} onClick={() => setTfFilter("all")}>All</button>
              {window.OYBC.timeframes.map(tf => (
                <button key={tf.key} className={"r-chip" + (tfFilter === tf.key ? " on" : "")} onClick={() => setTfFilter(tf.key)}>{tf.label}</button>
              ))}
            </div>
          </React.Fragment>
        ) : (
          <React.Fragment>
            <TimeframeStrip layout={topLayout} />
            <div className="r-filters">
              {filters.map(f => <button key={f} className={"r-chip" + (filter === f ? " on" : "")} onClick={() => setFilter(f)}>{f}</button>)}
            </div>
          </React.Fragment>
        )}
        {shown.length === 0 ? (
          <div className="r-empty">
            <div className="r-empty-art"><Blip size={92} mood="calm" /></div>
            <h3>Nothing here yet</h3>
            <p>No {isFilterRail ? (tfFilter === "all" ? "" : tfFilter + " ") : filter.toLowerCase() + " "}boards yet. Start one and Blip will help you fill it in.</p>
            <button className="r-btn primary" onClick={onCreate}><Icon name="plus" size={18} sw={2.6} />New board</button>
          </div>
        ) : (
          <React.Fragment>
            {shown.map(b => <BoardCard key={b.id} b={b} onOpen={onOpen} />)}
            <div style={{ height: 14 }} />
          </React.Fragment>
        )}
      </div>
      <div className="r-fade-bottom" />
    </div>
  );
}

/* ============================================================
   GREENLOG celebration
   ============================================================ */
function Greenlog({ stats, intensity, onShare, onNew }) {
  const confettiCount = Math.round(8 + intensity * 8);
  return (
    <div className="r-greenlog in">
      <Confetti count={confettiCount} />
      <div className="r-gl-mascot"><Blip size={108} mood="cheer" /></div>
      <div className="r-gl-kicker">Board complete</div>
      <div className="r-gl-title">GREENLOG!</div>
      <div className="r-gl-sub">Full board. Every single square.<br />Weekly Wellness — crushed.</div>
      <div className="r-gl-stats">
        <div className="r-gl-stat"><b>{stats.done}/{stats.total}</b><span>Squares</span></div>
        <div className="r-gl-stat"><b>{stats.bingos}</b><span>Bingos</span></div>
        <div className="r-gl-stat"><b>7d</b><span>Streak</span></div>
      </div>
      <div className="r-gl-btns">
        <button className="r-btn primary lg block" onClick={onShare}><Icon name="share" size={18} sw={2.2} />Share my board</button>
        <button className="r-btn block" style={{ background: "transparent", color: "var(--paper)", borderColor: "var(--paper)", boxShadow: "none" }} onClick={onNew}>Start a new board</button>
      </div>
    </div>
  );
}

Object.assign(window, { computeLines, PlayBoard, BoardsHome, BoardCard, Greenlog });
