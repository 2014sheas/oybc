---
name: audit
description: Run the periodic four-dimension deep-dive audit (code quality, architecture, iOS-guidelines/x-platform, security) as parallel read-only agents, consolidate into one prioritized report, verify top findings. Diagnosis-first — no fixes until the user decides.
user-invocable: true
---

# Deep-Dive Audit Skill

**Usage**: `/audit` (optionally `/audit <focus area or path>` to narrow)

**Purpose**: Catch drift-out-of-spec that the mechanical CI guardrails *can't* — the judgment-level findings (is this actually a bug, is this file doing too much, is this a real security gap). Runs the same four-dimension sweep that produced the 2026-08 baseline. **Read-only diagnosis. No code changes until the user picks what to fix.**

This is the judgment half of the drift-prevention system. The **mechanical** half runs automatically in CI and already covers: dead web exports (`scripts/check-knip.mjs`), god-file regrowth (`scripts/check-file-sizes.mjs`), and sync-contract ↔ `firestore.rules` consistency (`scripts/check-sync-contract-rules.mjs`). **Don't re-derive those by hand — assume CI holds them and focus the agents on what a script can't judge.**

---

## Workflow

### Phase 1 — Scope

1. Confirm the working tree is clean and on `dev` (or note the branch under audit). `git fetch` + note the range since the last audit if one is recorded in `docs/ROADMAP.md` / memory (`project_deep_dive_audit_2026_08`).
2. If the user gave a focus/path, narrow all four agents to it; otherwise sweep the whole repo.

### Phase 2 — Fan out (four parallel read-only agents)

Launch these **concurrently** (one message, multiple Agent calls), each **read-only** (no edits), each scored against the invariants in `CLAUDE.md`. Give each the "verified-safe baseline" (Phase 4) so it reports **new** drift, not settled facts.

1. **Code quality & maintainability** — `@ts-ignore`/`as!`/force-unwraps, swallowed catches, `Task {` shadow trap, dead code beyond what knip catches, extract-at-three violations + cross-platform divergence, test-coverage gaps, stale TODOs. Model: use the `feature-dev:code-reviewer` or a `general-purpose` agent.
2. **Architecture** — the invariants in CLAUDE.md scoped to Do: local-DB-source-of-truth, offline-first, LWW + soft-delete + per-mutation `sync_queue` enqueue, atomic pull-path, `SYNC_COLLECTIONS` mirroring, package purity, Play/Do boundary (`bingo-core`/`riso-tokens` only), DB-injection seam, denormalized-stat + version-bump discipline. Flag god-files + duplication (note these feed ROADMAP B6).
3. **iOS-guidelines & cross-platform consistency** — Riso token usage (the adaptive-ink-on-gold/fixed-fill trap: `--riso-ink` vs `--riso-ink-static`/`--riso-on-color`; iOS `Color.risoInk` vs `.risoInkStatic`), no hardcoded hex on production surfaces, `dlog` release-gating, snapshot hygiene, web↔iOS parity (rule 6), documented divergences NOT re-flagged.
4. **Security** — Firestore rules (cross-user isolation, version-monotonicity, owner-match, default-deny), Cloud Functions auth gates, no committed secrets, no PII in logs, dev-bypass DEV/DEBUG-gating, injection surfaces.

Each agent returns findings as `Severity | Finding | Evidence (file:line) | Suggested fix`, severity = Critical / Major / Minor / Nit, plus a short "verified clean" list of invariants it checked and confirmed.

### Phase 3 — Consolidate & verify

1. Merge the four reports into ONE table, **deduped**, ranked Critical → Nit. Note which dimension each came from.
2. **Personally verify the top findings** (read the cited code) before presenting — agent audits mis-call callers/severity. Downgrade or drop what doesn't hold.
3. Map any finding a mechanical guardrail *should* have caught → that's a guardrail gap; note it (maybe the guardrail needs extending).
4. Present the consolidated report + a **tiered fix recommendation** (quick-wins / real fixes / tracked-refactor), then **stop and let the user choose**. Do not start fixing.

### Phase 4 — Verified-safe baseline (carry forward)

Seed each re-run's agents with what the last audit confirmed clean, so they spend effort on new drift, not re-litigating settled invariants. As of the 2026-08 baseline (`project_deep_dive_audit_2026_08`), verified clean: sync enqueue coverage across all entities, atomic+LWW pull path (both platforms, mirrored), `SYNC_COLLECTIONS` single-sourced + fixture-enforced, `shared`/`bingo-core` purity, Play/Do boundary, DB-injection seam, `_Concurrency.Task` discipline, `dlog` release-gating, no committed secrets, cross-user isolation, `signups` default-denied, Admin-only parent delete, `deleteUserData` uses `auth.uid`. Re-confirm cheaply; deep-dive only where the diff since the last audit touched them.

---

## Notes

- **Cost**: four parallel agents is token-heavy. Scale the finder pool to the request — a focused `/audit apps/web/src/components/pools` is much cheaper than a full sweep.
- **Don't duplicate CI**: if a finding is one the guardrails enforce, it means either the guardrail regressed or the finding is a false positive — investigate rather than re-report.
- **Record the outcome**: update/append the `project_deep_dive_audit_2026_08`-style memory (or a new dated one) with what shipped and what's newly tracked, so the next run's baseline is current.
