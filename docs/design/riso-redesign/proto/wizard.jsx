/* ============================================================
   OYBC · Riso prototype — Create wizard (3 steps)
   Exports to window: Wizard
   ============================================================ */
function Wizard({ onClose, onFinish, composerStyle = "button", libAccess = "drawer" }) {
  const [step, setStep] = React.useState(0);
  const [name, setName] = React.useState("");
  const [tf, setTf] = React.useState("Weekly");
  const [size, setSize] = React.useState(5);
  const [center, setCenter] = React.useState("Free Space");
  const [tasks, setTasks] = React.useState([]);

  const tfNote = {
    Daily: "Today · resets at midnight",
    Weekly: "This week · Jun 8 – 14",
    Monthly: "June 2026 · 30 days",
    Yearly: "2026 · the long game",
  }[tf];

  const cells = size * size;
  const need = cells - (center === "None" ? 0 : 1);
  const steps = ["Setup", "Tasks", "Preview"];

  const next = () => (step < 2 ? setStep(step + 1) : onFinish({ name: name || "Weekly Wellness", tf, size, tasks }));
  const back = () => (step > 0 ? setStep(step - 1) : onClose());

  return (
    <React.Fragment>
      <div className="r-top">
        <div className="r-wiz-head">
          <div>
            <div className="r-kicker">{step === 2 ? "Last look" : "New board"}</div>
            <div className="r-h2" style={{ marginTop: 3 }}>{steps[step]}</div>
          </div>
          <button className="r-back" onClick={onClose} aria-label="Close" style={{ background: "var(--paper-2)" }}><Icon name="close" size={18} sw={2.4} /></button>
        </div>
        <div className="r-stepper-bar">
          {steps.map((s, i) => (
            <React.Fragment key={s}>
              <div className={"r-step" + (i === step ? " on" : i < step ? " done" : "")}>
                <span className="r-step-dot">{i < step ? <Icon name="check" size={11} sw={2.6} /> : i + 1}</span>
                <span className="r-step-lbl">{s}</span>
              </div>
              {i < 2 && <div className="r-step-line" />}
            </React.Fragment>
          ))}
        </div>
      </div>

      <div className="r-scroll">
        {step === 0 && (
          <React.Fragment>
            <div className="r-field">
              <div className="r-field-l">Board name <span className="req">*</span></div>
              <input className="r-input" placeholder="Weekly Wellness" value={name} onChange={e => setName(e.target.value)} />
            </div>
            <div className="r-field">
              <div className="r-field-l">Timeframe</div>
              <div className="r-seg">
                {["Daily", "Weekly", "Monthly", "Yearly"].map(o => (
                  <button key={o} className={tf === o ? "on" : ""} onClick={() => setTf(o)}>{o}</button>
                ))}
              </div>
              <div className="r-note">🗓 <span>{tfNote}</span></div>
            </div>
            <div className="r-field">
              <div className="r-field-l">Board size</div>
              <div className="r-sizes">
                {[3, 4, 5].map(n => (
                  <div key={n} className={"r-sizecard" + (size === n ? " on" : "")} onClick={() => setSize(n)}>
                    <div className="sg" style={{ gridTemplateColumns: `repeat(${n}, 7px)` }}>
                      {Array.from({ length: n * n }).map((_, k) => <i key={k} />)}
                    </div>
                    <div className="sl">{n}×{n}</div>
                  </div>
                ))}
              </div>
            </div>
            <div className="r-field">
              <div className="r-field-l">Center square</div>
              <div className="r-seg">
                {["Free Space", "I'll choose", "None"].map(o => (
                  <button key={o} className={center === o ? "on" : ""} onClick={() => setCenter(o)}>{o}</button>
                ))}
              </div>
            </div>
            <div style={{ height: 8 }} />
          </React.Fragment>
        )}

        {step === 1 && (
          <TaskStep
            tasks={tasks} setTasks={setTasks} size={size}
            centerType={center === "None" ? "none" : "free"} composerStyle={composerStyle} libAccess={libAccess}
          />
        )}

        {step === 2 && (
          <React.Fragment>
            <div style={{ textAlign: "center", margin: "4px 0 16px" }}>
              <div style={{ fontFamily: "var(--font-head)", fontWeight: 800, fontSize: 24, letterSpacing: "-.02em" }}>{name || "Weekly Wellness"}</div>
              <div style={{ fontSize: 12, fontWeight: 700, color: "var(--muted)", marginTop: 4 }}>{tf} · {size}×{size} · {tasks.length} tasks</div>
            </div>
            <div className="r-preview-grid" style={{ gridTemplateColumns: `repeat(${size}, 1fr)` }}>
              {Array.from({ length: cells }).map((_, i) => {
                const mid = Math.floor(cells / 2);
                const isFree = center !== "None" && i === mid;
                const task = tasks[i % tasks.length];
                return <i key={i} className={isFree ? "free" : ""}>{!isFree && task ? task.t : ""}</i>;
              })}
            </div>
            <div className="r-note" style={{ marginTop: 16, justifyContent: "center" }}>
              <Star size={13} /> <span>Tap <b>Create</b> and your board goes live right away.</span>
            </div>
            <div style={{ height: 8 }} />
          </React.Fragment>
        )}

        <div className="r-fade-bottom" />
      </div>

      <div style={{ padding: "0 20px", position: "relative", zIndex: 6, background: "var(--paper)" }}>
        <div className="r-wiz-foot">
          <button className="r-btn" onClick={back} style={{ flex: 1 }}>{step === 0 ? "Cancel" : "Back"}</button>
          <button className="r-btn primary" onClick={next} style={{ flex: 1.7 }}>
            {step === 2 ? "Create board ✦" : "Next ›"}
          </button>
        </div>
      </div>
    </React.Fragment>
  );
}

Object.assign(window, { Wizard });
