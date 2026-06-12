/* ============================================================
   OYBC · Riso prototype — shared components & art
   Exports to window: Blip, Icon, Star, Confetti
   ============================================================ */

/* ---- Blip mascot: overprint sticker character ---- */
function Blip({ size = 96, mood = "happy" }) {
  const s = size / 96;
  const px = (n) => n * s;
  // mood tweaks the mouth
  const mouth = {
    happy: { w: 24, h: 11, radius: `0 0 ${px(14)}px ${px(14)}px`, top: 50, fill: "var(--gold)" },
    cheer: { w: 26, h: 18, radius: `0 0 ${px(15)}px ${px(15)}px`, top: 48, fill: "var(--gold)" },
    calm:  { w: 18, h: 6,  radius: `0 0 ${px(9)}px ${px(9)}px`,  top: 52, fill: "transparent" },
  }[mood];
  return (
    <div style={{ position: "relative", width: px(96), height: px(96), flex: "0 0 auto" }}>
      {/* back overprint circle (red, multiply) */}
      <div style={{ position: "absolute", left: px(8), top: px(14), width: px(64), height: px(64), borderRadius: "50%", background: "var(--red)", border: `${px(2)}px solid var(--ink)`, mixBlendMode: "multiply" }} />
      {/* body (blue) */}
      <div style={{ position: "absolute", right: px(6), top: px(8), width: px(66), height: px(66), borderRadius: "50%", background: "var(--blue)", border: `${px(2)}px solid var(--ink)`, overflow: "hidden" }}>
        <div style={{ position: "absolute", inset: 0, backgroundImage: "radial-gradient(circle, rgba(24,18,11,.4) 24%, transparent 26%)", backgroundSize: `${px(9)}px ${px(9)}px` }} />
      </div>
      {/* eyes */}
      <div style={{ position: "absolute", right: px(42), top: px(30), width: px(11), height: px(13), borderRadius: "50%", background: "var(--paper)", border: `${px(2)}px solid var(--ink)` }} />
      <div style={{ position: "absolute", right: px(22), top: px(30), width: px(11), height: px(13), borderRadius: "50%", background: "var(--paper)", border: `${px(2)}px solid var(--ink)` }} />
      <div style={{ position: "absolute", right: px(45), top: px(36), width: px(5), height: px(5), borderRadius: "50%", background: "var(--ink)" }} />
      <div style={{ position: "absolute", right: px(25), top: px(36), width: px(5), height: px(5), borderRadius: "50%", background: "var(--ink)" }} />
      {/* mouth */}
      <div style={{ position: "absolute", right: px(26), top: px(mouth.top), width: px(mouth.w), height: px(mouth.h), border: `${px(2.2)}px solid var(--ink)`, borderTop: 0, borderRadius: mouth.radius, background: mouth.fill }} />
      {/* spark */}
      <div style={{ position: "absolute", left: px(2), top: px(2), width: px(14), height: px(14), background: "var(--gold)", border: `${px(1.6)}px solid var(--ink)`, clipPath: "polygon(50% 0,61% 35%,98% 35%,68% 57%,79% 91%,50% 70%,21% 91%,32% 57%,2% 35%,39% 35%)" }} />
    </div>
  );
}

function Star({ size = 14, fill = "var(--gold)", stroke = "var(--ink)" }) {
  return <div style={{ width: size, height: size, background: fill, border: `1px solid ${stroke}`, clipPath: "polygon(50% 0,61% 35%,98% 35%,68% 57%,79% 91%,50% 70%,21% 91%,32% 57%,2% 35%,39% 35%)" }} />;
}

/* ---- line icons (stroke = currentColor) ---- */
const ICONS = {
  boards: <path d="M3.5 3.5h7v7h-7zM13.5 3.5h7v7h-7zM3.5 13.5h7v7h-7zM13.5 13.5h7v7h-7z" />,
  tasks: <g><path d="M4 7h11M4 12h11M4 17h7" /><path d="M19 5.6l-1.7 1.8L16.4 6.6" /></g>,
  create: <g><circle cx="12" cy="12" r="8.5" /><path d="M12 8v8M8 12h8" /></g>,
  profile: <g><circle cx="12" cy="9" r="3.4" /><path d="M5.5 19c1.2-3.2 4-4.4 6.5-4.4S17.3 15.8 18.5 19" /></g>,
  back: <path d="M15 5l-7 7 7 7" />,
  close: <path d="M6 6l12 12M18 6L6 18" />,
  plus: <path d="M12 5v14M5 12h14" />,
  check: <path d="M2.5 6.5l2.2 2.2L9.5 3.5" />,
  share: <g><path d="M12 3v13M12 3l-4 4M12 3l4 4" /><path d="M5 12v7h14v-7" /></g>,
};
function Icon({ name, size = 22, sw = 2 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round">
      {ICONS[name]}
    </svg>
  );
}

/* ---- confetti for GREENLOG (count scales with celebration intensity) ---- */
function Confetti({ count = 40 }) {
  const colors = ["var(--red)", "var(--gold)", "var(--green)", "var(--paper)"];
  const bits = React.useMemo(() => {
    const arr = [];
    for (let i = 0; i < count; i++) {
      const c = colors[i % colors.length];
      const left = Math.round((i * 53 + 7) % 100);
      const delay = ((i * 137) % 1000) / 1000;
      const dur = 1.6 + ((i * 71) % 100) / 100 * 1.6;
      const sz = 6 + (i % 4) * 2;
      const shape = i % 3 === 0 ? "0" : i % 3 === 1 ? "50%" : "2px";
      const rot = (i * 47) % 360;
      arr.push({ c, left, delay, dur, sz, shape, rot });
    }
    return arr;
  }, [count]);
  return (
    <div className="r-gl-confetti">
      {bits.map((b, i) => (
        <i key={i} style={{
          left: b.left + "%", width: b.sz, height: b.sz * (b.shape === "50%" ? 1 : 1.3),
          background: b.c, borderRadius: b.shape, border: "1.5px solid var(--ink)",
          transform: `rotate(${b.rot}deg)`,
          animation: `confFall ${b.dur}s linear ${b.delay}s infinite`,
        }} />
      ))}
    </div>
  );
}

Object.assign(window, { Blip, Star, Icon, Confetti });
