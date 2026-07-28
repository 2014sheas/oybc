# Play OYBC — Design Document

> **Status:** Living design doc. This is the canonical record for **Play OYBC**,
> the social/competitive sibling to OYBC (Do). It is written before
> implementation and is expected to evolve — decisions get locked in the Decisions
> Log as they're made; open questions stay flagged until resolved. Architecture is
> deliberately left as open questions pending the architecture spike (see
> `play-oybc-architecture-spike.md`).
>
> **Companion docs:** `play-oybc-architecture-spike.md` (the Phase 0 exploration
> that resolves the architecture questions in §6).

---

## 1. What Play OYBC is

Play OYBC is a **real-time, collaborative, competitive party-bingo game**. Where
OYBC (Do) is a solo, local-first habit/goal tracker, Play is a multiplayer *event* —
a group of people in the same place (or remote) racing to complete bingo boards built
from a shared pool of tasks.

**The core loop:**
1. A **host** picks a game mode and basic settings, and opens a **lobby**.
2. Invited **players** join the lobby.
3. Players collaboratively add tasks to a **shared task pool**, in real time.
4. The game **launches** — host-triggered or scheduled. At launch, a board is
   **randomly generated per player** from the shared pool.
5. Players race to complete their board. **First to finish wins.**

**Two flavors of task** (illustrative range, not literal enums):
- **Active** — something a player controls and can choose to do (e.g. "do a shot,"
  "introduce yourself to a stranger").
- **Passive** — something outside the player's control that they observe happening
  (e.g. "a Taylor Swift song plays," "someone new RSVPs").

This active/passive range is what separates Play tasks from OYBC (Do) tasks (which
are all active, completion-controlled goals) and is core to the party-observation
feel.

### Relationship to OYBC (Do)

OYBC is **two products under one brand**:

| | OYBC (Do) | Play OYBC |
|---|---|---|
| **What** | Solo habit/goal bingo tracker | Multiplayer party bingo game |
| **State model** | Local-first, offline-first, LWW sync | Real-time shared session (see §6) |
| **Completion** | Global per-Task across a user's boards | Per-player, per-session, independent |
| **Domain** | `do.oybc.com` | `play.oybc.com` |
| **Status** | Built; in polish; likely deploys first | Exploration; net-new |
| **App** | "OYBC" | "Play OYBC" |

They share a brand, the Riso design system, and (pending the spike) some
`packages/shared` logic — but they are separate apps with materially different state
models. How separate they *really* are is one of the things the architecture spike
exists to determine.

---

## 2. Origin & motivation

Play grew out of a real, repeated, manual practice. Over several years of organizing
parties, the group kept making bingo boards of things that might happen at the
event — a mix of genuine predictions and in-jokes. Real examples from past boards:

> Someone fixates on World Series · Dynasty trade · Cody is in his bag ·
> 6-7 joke (sir, a second free space) · Krispy gets in some situational trouble ·
> Seth says something he shouldn't · Josh convinces someone to get a cat ·
> Cody/Seth asleep on the couch

The recurring "well, *that* wasn't on my bingo card" reaction at these parties is also
the seed of the whole OYBC brand. The practical problem: **no good tool exists for
this.** The group resorted to janky bingo-board generators that capped free board
variants (~10), offered **no real-time collaboration**, and made the actual play
experience feel lacking. Years later, still no great collaborative-bingo option
exists. That gap — proven by repeated real-world use of inadequate workarounds — is
the product thesis. (This same yearly-bingo practice inspired the solo yearly board
that became OYBC (Do).)

**Why this matters strategically:** the social version is plausibly the more viral,
more differentiated, and more defensible product. The solo habit-tracker space is
crowded; real-time collaborative party bingo is nearly empty. The origin story is
also the marketing.

---

## 3. Goals & non-goals

### Goals
- A genuinely good **real-time collaborative** pool-building + play experience — the
  thing every existing tool lacks.
- Fun at **party scale** (handfuls to ~dozens of players), in-person first.
- A **playable internal demo** to friends (web and/or TestFlight) by ~Halloween —
  a forgiving test, explicitly **not** a polished public launch.
- Reuse what's genuinely reusable from OYBC (Do) without forcing a bad architectural
  fit (the spike adjudicates this).

### Non-goals (for now)
- **Not** a polished public launch at the Halloween milestone — that's a later,
  separately-gated event with its own readiness bar (App Store positioning,
  moderation, age rating — see §8).
- **Not** all game modes at once. v1 is **(do)-YBC only** (§5). Other modes are
  post-demo.
- **Not** the `(go)-YBC` geolocation mode in any near-term scope — it is effectively
  a separate app (§5, §8) and must not drive core architecture.
- **Not** OYBC (Do)'s local-first/offline-first guarantees. Play is inherently
  session- and network-dependent; offline play is not a goal.

---

## 4. Players, roles & the session lifecycle

### Roles
- **Host** — creates the game, picks mode + settings, controls launch (or sets a
  scheduled launch), and is the locus of monetization (host-pays; see §7).
- **Player** — joins a lobby, contributes to the pool, plays their board.
  (The host is typically also a player.)

### Session lifecycle (the spine the architecture must support)
1. **Create** — host configures mode + settings, lobby is created, invite/link
   generated.
2. **Lobby / pool-building** — players join; everyone adds tasks to a **shared pool**
   in real time; players see the pool grow live.
3. **Launch** — triggered by host or by a scheduled time. The pool freezes; a board
   is generated **per player** (randomized from the pool; board size/center per
   settings).
4. **Play** — players mark squares on their own board; live race state.
   Bingo/board-completion detection runs per player.
5. **Win / end** — first player (or team) to complete their board wins; end state +
   summary.

Each stage maps to a real-time requirement (live lobby presence, live shared-pool
writes, an atomic synchronized launch fan-out, live per-player progress, authoritative
win detection). These are enumerated as risks in §6 and in the spike brief.

---

## 5. Game modes

> v1 ships **(do)-YBC only.** Everything else is sketched here for the canonical
> record and to inform (but not dictate) architecture. Modes will be workshopped and
> expanded over time; this list is not exhaustive.

### (do)-YBC — Classic *(v1 / MVP)*
Task-based competitive bingo, the base loop in §1. Shared pool, per-player randomized
boards, first to complete wins. **This is the only mode in scope for the demo and the
architecture spike.**

### (co)-YBC — Teams
Like classic, but players are split into teams. **Team members share a board**; first
team to complete it wins. A modest extension of the classic spine once real-time
multiplayer exists — reasonable fast-follow.

### Social / @mention *(unnamed)*
Tasks can be attached to specific joined players — e.g. "@anyone goes to the
bathroom," "@someone takes a shot," "@Cody says his catchphrase." Mostly a task-type
addition on top of the classic spine; arguably the most fun/viral for parties. Good
fast-follow.

### O-(9x9x9)-BC — Baseball *(seasonal)*
Special mode for baseball season. Diagonals are feats from the classic 9-9-9
ballpark challenge (food/drink counts); remaining squares are on-field events
(home/away team home runs, hits, strikeouts, etc.), with home/away configured by the
host pre-launch. Niche and timing-locked; later. **Note:** keep this mode's framing
clear of alcohol references (see §8) — the cultural referent is a drinking challenge,
which is an App Store risk.

### (go)-YBC — Photo / geolocation *(parked — likely separate product)*
Players start at one location, then have a time window to wander and photograph
landmarks/sights. After time's up, teams receive a board of *other* teams' photos
(initially zoomed-in/obscure) and must travel to where each was taken; a square
unlocks only when a player is within a configurable radius (e.g. 100 yd, 0.25 mi) of
the original spot. Photos progressively zoom out over preset intervals until restored
to full size. First team to complete wins. Possible power-ups (proximity check,
early zoom-out, etc.). Inspired by Jet Lag: The Game.

> ⚠️ **Parked deliberately.** This is effectively a separate app: live GPS tracking,
> geofencing/radius validation, photo capture + storage, map rendering,
> location-based unlocking, real-time team state. It also carries real safety and
> liability surface (directing people to physically roam a city) and precise-location
> privacy compliance (Apple sensitive-data rules, GDPR/CCPA). It must **not** influence
> the core architecture decision and is out of scope for the foreseeable roadmap.

---

## 6. Architecture *(OPEN — pending spike)*

> This section is intentionally unresolved. The architecture spike
> (`play-oybc-architecture-spike.md`) exists to answer it. What follows is the set of
> known constraints and open questions, not decisions.

### The central tension
OYBC (Do) is built on a philosophy Play partly **contradicts**: local DB as source of
truth, offline-first, Firestore as background-sync-only, last-write-wins, no server
authority, no real-time presence. Play needs the opposite in several places: a live
shared session, real-time shared-pool writes, a synchronized launch event, per-player
board generation, live race state, and — for competitive integrity — some **server
authority** (board generation and win detection should not be fully client-trusted).

### Open questions (the spike resolves these)
- **Reuse vs. net-new:** which layers carry over (bingo detection, board
  randomization, Riso, render components, shared types) vs. are net-new (the
  real-time spine, session/lobby model, presence)?
- **Real-time backend:** Firestore listeners? Firebase Realtime Database (alongside
  Firestore)? A lightweight game server for true authority? Tradeoffs in latency,
  solo-dev operational burden, cost, and coexistence with the existing Firebase
  project.
- **Server authority:** how much, and where — board generation, win detection,
  timing/"first to finish" trust.
- **Monorepo fit:** third app in the existing monorepo sharing `packages/shared`, or
  separate? (The honest tell for how separate the two products really are.)
- **Persistence:** does Play need local persistence at all, or is session state
  primarily server-side/ephemeral?

### Known hard real-time edge cases (to be designed, not hand-waved)
Enumerated up front because the last 20% of real-time multiplayer is where time goes
and the bugs are timing-dependent / non-deterministic:
- Host disconnects / drops mid-game.
- Player joins late or reconnects after a drop (state resync).
- Simultaneous "I won" claims (race resolution, authority).
- Shared-pool write contention with many concurrent editors.
- Launch-moment fan-out (generating N boards atomically and fairly).
- Clock/timing trust (scheduled auto-launch; first-to-finish timestamps).

The demo may paper over most of these; the public launch must solve them.

### Reusable-from-OYBC candidates (provisional, spike confirms)
- Bingo / line detection (`detectBingos` + line logic in `packages/shared`).
- Board randomization (Fisher-Yates).
- Riso design system (tokens, controls, components).
- Board / cell render components (with adaptation for live competitive state).
- Cross-platform type/validation patterns.

### Does NOT carry over (provisional)
- Global-per-Task completion semantics (Play completion is per-player, per-session).
- Local-first / offline guarantees.
- LWW-only sync model (real-time competitive state needs more than LWW).

---

## 7. Monetization *(provisional)*

**Host-pays model.** The host — the person who organizes and gets the most value —
is the locus of payment; players join free and experience the full game (this protects
the viral surface: every player is a future host).

Provisional split:
- **Free:** classic **(do)-YBC** with **≤4 players**.
- **Subscription (host only):** larger games, teams `(co)`, social/@mention, seasonal
  (baseball), and other premium modes; likely also host power-features (saved
  pools/boards, history, custom settings).

> **Open / to-revisit:** The ≤4-player free cap may fight virality — party games
> spread *because* of group size and variety, and capping the free experience at 4
> players (and paywalling the more interesting modes) could limit word-of-mouth. A
> generous free core that maximizes spread, monetizing on host power-features rather
> than on basic group size, is worth weighing against the current split. The
> host-as-payer *axis* is sound; the specific free/paid line is not locked.

---

## 8. Pre-public-launch gates *(not demo blockers)*

None of these block an internal friends demo. All are real gates before a public
launch. Captured here so they're visible early and don't get architected into a corner.

### Content moderation / UGC
Public user-generated task pools will contain offensive, harassing, or unsafe content.
Apple effectively **requires** UGC apps to provide content reporting, blocking, and a
moderation mechanism. This is a *positioning + UGC-affordance* problem, not a
"pre-censor every task" problem (pre-filtering user tasks is neither feasible nor
desirable). Internal demo with friends: not applicable.

### Alcohol / drinking-game framing (App Store)
Several modes and tasks naturally trend toward drinking ("do a shot"; the 9-9-9
referent is a ballpark drinking challenge). Apple's guidelines restrict apps that
**encourage excessive alcohol consumption** or present it as harmless, and
drinking-game apps have a history of rejection or forced 17+ rating. User-generated
(rather than pre-populated) drinking tasks do **not** fully insulate this — Apple holds
the platform responsible for the app's core loop and UGC. Likely shape of the answer:
a 17+ age rating, framing as general party bingo (not a drinking game), UGC
report/block affordances, and ensuring *first-party* surfaces (mode names, defaults,
marketing) never promote drinking. **Not legal/Apple-review advice — confirm against
the current App Review Guidelines before public launch.**

### Geolocation (only if (go)-YBC is ever pursued)
Precise-location collection (Apple sensitive-data rules, GDPR/CCPA), plus physical
safety/liability from directing users to roam. Another reason (go)-YBC is parked.

### Two-products-one-solo-dev load
Two apps, two domains, two App Store listings, two maintenance/marketing/support
surfaces — alone. The realistic guardrail: get **OYBC (Do)** shipped and showing
traction before Play becomes a second full front. The first-project risk is spreading
thin across half-finished ideas, not running out of ideas.

---

## 9. Roadmap *(provisional)*

1. **Phase 0 — Architecture spike.** Resolve §6. Throwaway lobby PoC proving the
   real-time loop. (See spike brief.) *Current phase.*
2. **Phase 1 — (do)-YBC demo.** Minimum loop (§4/§5 classic) on the chosen backend:
   lobby → real-time shared pool → host launch → per-player randomized boards →
   race → win. Web and/or TestFlight. Target: internal Halloween demo. Rough is fine.
3. **Phase 2 — Harden the demo into a real (do)-YBC.** Solve the §6 edge cases;
   reconnection, host-drop, authoritative win detection.
4. **Phase 3 — Fast-follow modes.** Teams `(co)`, then social/@mention.
5. **Phase 4 — Public-launch readiness.** §8 gates: moderation/UGC affordances,
   App Store positioning + age rating, monetization wiring.
6. **Later / seasonal.** Baseball `9x9x9`. (go)-YBC remains parked.

---

## 10. Decisions log

| Date | Decision | Rationale | Status |
|---|---|---|---|
| (init) | Play is a separate app/product from OYBC (Do), shared brand + Riso, separate domain `play.oybc.com` | Materially different state model; clean brand split | Locked |
| (init) | v1 = (do)-YBC only; other modes deferred | Minimum loop that proves the concept; scope control | Locked |
| (init) | (go)-YBC parked indefinitely | Effectively a separate app; safety/privacy/effort | Locked |
| (init) | Halloween target = playable internal demo, not public launch | Forgiving test; avoids false "ship by date" pressure | Locked |
| (init) | Monetization axis = host-pays | Matches social reality; protects viral surface | Locked (axis) |
| (init) | Free/paid line (≤4 free, modes paywalled) | Provisional | **Open — may fight virality (§7)** |
| TBD | Real-time backend choice | Pending spike | **Open (§6)** |
| TBD | Reuse vs. net-new boundary | Pending spike | **Open (§6)** |
| 2026-07-06 | Monorepo co-habit as `apps/play` in the oybc monorepo (not a separate repo) | See `docs/PLAY_TRANSITION.md` § "Why this shape" decision record | Locked |

---

## 11. Open questions (consolidated)

- §6 (architecture) — remaining items (real-time backend choice, reuse-vs-net-new
  boundary) resolved by the spike. Monorepo co-habit vs. separate is **no longer
  open** — Locked as `apps/play` in this monorepo (see §10 Decisions log,
  `docs/PLAY_TRANSITION.md`).
- §7 free/paid line — needs a virality-vs-revenue call.
- Naming: is "Play OYBC" the final product name, and are the `(do)/(co)/(go)`
  mode-naming puns the real mode names or just working titles?
- Remote vs. in-person: is Play in-person-first only, or is remote/distributed play
  a supported case? (Affects presence/latency expectations.)
- What's the smallest "good" play experience — i.e., what made the janky generators
  "feel lacking," concretely, so v1 explicitly fixes it? (Worth writing down from the
  real party experiences.)
