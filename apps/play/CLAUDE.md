# Play OYBC (`apps/play`)

Play OYBC is the real-time, multiplayer party-bingo sibling of OYBC (Do).
Design doc: `docs/play/PLAY_OYBC.md`. Transition plan: `docs/PLAY_TRANSITION.md`.

## ⚠️ Root-CLAUDE.md invariants DO NOT apply here

The root file describes OYBC (Do). Play **inverts** its core architecture:

| Root invariant (Do) | Play's rule |
| --- | --- |
| Local DB is the source of truth | **Session state is server-authoritative.** Clients render server state; they do not own it. |
| Offline-first; sync is background-only | **Online-required.** Offline play is an explicit non-goal. |
| LWW conflict resolution | Real-time competitive state; authority + ordering come from the backend (see spike). |
| No server push / lazy detection only | Live push (lobby presence, pool updates, launch fan-out, race state) is the whole point. |
| Global-per-Task completion | **Per-player, per-session completion.** Nothing completes globally. |
| Web↔iOS parity rule 6 | Pairs Do-web with Do-iOS. Play is a separate product — never "mirror" a Do surface here, and Play features don't owe Do a counterpart. |

## Rules that DO carry over

- Shared-boundary: import ONLY `@oybc/bingo-core` + `@oybc/riso-tokens`
  (`@oybc/shared` is ESLint-banned here — the ban is load-bearing, don't
  disable it). Pure game math belongs in bingo-core, session/domain logic here.
- Riso design system: tokens from `@oybc/riso-tokens`; follow
  `docs/RISO_WEB.md` conventions for any UI.
- Code quality + testing standards (types, small functions, Jest/deterministic
  tests) apply as written.

## Status

Scaffold only. Architecture (realtime backend, session model, authority) is
OPEN pending the Phase 0 spike — see design doc §6. Do not pick a backend or
add a persistence layer without that decision being recorded in the design
doc's Decisions Log.
