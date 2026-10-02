# PRD: Agent Auth Baseline

> Source: `docs/planning/_card/issue.md` (founder request, 2026-10-01). Decisions D1–D3
> recorded below. C13 follow-on.

## Problem Statement

Agent rows authenticate two ways. Today: an **API key in the row's `environment`**
(e.g. `ANTHROPIC_API_KEY`). The mode the founder actually uses: the CLI's **own
subscription login** — Claude subscription via `claude`'s OAuth login, ChatGPT sign-in
for Codex, Google account for Gemini, and so on — with credentials stored in the user's
home directory (`~/.claude/…`, `~/.codex/…`, `~/.config/gemini/…`). The shipped executor
**scrubs the environment** (`ShellExecutor.swift`: "exactly the configured variables,
never the caller's" — the recorded N2 doctrine): a child with an empty row environment
gets **no HOME at all**, so a subscription-auth CLI cannot find its own credentials and
the run fails. Both auth modes must work — the key mode already does; the subscription
mode is blocked by the scrub, not by the CLIs.

What happens if we don't build this: every agent row requires an API key, the founder's
subscription logins are unusable, and the presets silently mislead (no hint that
subscription works).

## Goals & Success Metrics

- **G1 — Both auth modes work.** A row with an empty `environment` runs a CLI that
  authenticates through its own login (Claude subscription, ChatGPT, Google account) —
  the child receives the declared baseline (HOME) so the CLI finds its credentials.
- **G2 — The scrub is refined, deliberately and narrowly** (D1, D2). The executor's
  `Configuration` gains a declared `baselineEnvironment` (default `[:]` — byte-identical
  when not wired); the merge rule is baseline ∪ configured entries, **configured wins**;
  nothing beyond the declared baseline + the row's entries ever reaches the child. The
  N2 record is rewritten honestly: "never the caller's environment" → "never beyond the
  declared baseline and the row's own entries".
- **G3 — Every child benefits** (D1 — the "most complete" option): the baseline applies
  at the executor level, so agent rows AND shell rows carry it once the composition
  wires it — one rule, no provider special-casing.
- **G4 — The user knows which auth each CLI supports** (D3): per-preset `authHint`
  copy in the catalog, rendered under the editor's Environment field (e.g. Claude: API
  key or subscription login).
- **G5 — Invariants hold.** Zero network; the default still spawns nothing (the
  baseline is a value, not a spawn); the dictation path untouched; lints untouched; the
  composed default facts unchanged.

## User Personas & Scenarios

- **The founder (primary).** Claude subscription logged in (`claude` works in any
  terminal with no `ANTHROPIC_API_KEY`). Row: claude, argv `["-p", "<task>"]`, empty
  environment. Converse: "ask claude to summarize the open PRs" → the card → confirm →
  claude runs with the subscription, no key anywhere.
- **The key user.** The row's environment entries still work exactly as before (and
  override the baseline).
- **The skeptic.** Nothing configured: the default is byte-identical (the baseline
  default is empty); nothing spawns.

## Requirements

### Must-have

- **R1 — The executor baseline**: `ShellExecutor.Configuration.baselineEnvironment:
  [String: String]` (default `[:]`); `run()` merges baseline ∪ configured
  (`merging(_:) { _, new in new }` — configured wins); the existing env pin updates
  (a configured entry beats a baseline entry; an empty default is byte-identical to
  today; the caller's session never leaks).
- **R2 — The providers pass it through**: `CodingAgentProvider` and `ShellProvider`
  gain an injected `baselineEnvironment: [String: String]` (additive init parameter,
  default `[:]` — the doctrine); their `ShellExecutor.Configuration` builds carry it.
- **R3 — The composition wires HOME**: `AppBootstrap` passes
  `baselineEnvironment: ["HOME": NSHomeDirectory()]` into both providers (the
  composition root may name Foundation; VoccaActions never computes home — the lint
  boundary holds). The probe's drives keep the default (byte-identical) or wire a temp
  HOME for the round trips — decide in the aspect (a temp HOME keeps the seeded runs
  honest).
- **R4 — The auth hints**: `KnownAgentPreset` gains `authHint: String?` (pinned copy
  per preset — the key + subscription spellings); the editor renders it under the
  Environment field.
- **R5 — Probe/pins**: the composed default facts unchanged; the G5 re-anchor if
  `AppBootstrap` changes (deliberate, computed, dictation digests unchanged); the
  lints untouched (a Configuration field, init parameters, catalog copy — no new
  family names).
- **R6 — SMOKE 163**: the subscription flow on the founder's machine — a logged-in CLI
  (e.g. `claude`), row with EMPTY environment → arm → card → confirm → the run
  authenticates with the subscription; plus the key-mode control (the existing rows
  still work). Recorded never gated; no rate quoted.

### Should-have

- **S1 — The merge rule pinned twice**: executor-level (the env pin) and
  provider-level (a counting engine receives baseline ∪ entries).

### Nice-to-have

- **N1 — The editor shows which auth the CLI detected** (e.g. "subscription login
  found in ~/.claude") — deferred, recorded (it needs a credential-store probe the
  repo has not reviewed).

## Technical Considerations

- **Phase:** P4, C13 follow-on. Branch from master (c3e01b2).
- **Why executor-level** (D1): one rule for every child; the shell rows' scrub changes
  only when the composition wires the baseline — the reviewed boundary is the
  composition, not the executor's default.
- **Why HOME only** (D2): the minimal thing any CLI needs to find its own credential
  store; row entries win; nothing else from the session.
- **Privacy**: the baseline is a single declared path; Vocca stores no credential; the
  CLI's own login owns its secrets.
- **Lints**: `baselineEnvironment` is a value on the permitted executor file; the
  providers' init parameters name no forbidden family; `NSHomeDirectory()` is named in
  VoccaBootstrap only.
- **Local-first, zero network**: unchanged.

## Risks & Open Questions

- **R-A — A child with HOME but no other vars misbehaves** (some CLIs want LANG/TMPDIR):
  the honest baseline is HOME only (the decision); a future widening is a reviewed edit
  with the same merge rule.
- **R-B — The subscription login is the CLI's own state**: Vocca can't verify it (the
  detection honesty rule — "exists at a path" never "signed in"); the failure is the
  CLI's own loud error in the run's outcome.
- **Open:** whether the probe wires a temp HOME (recommended — keeps the seeded round
  trips honest and the default facts unchanged).

## Out of Scope

- Storing or managing any credential in Vocca; probing the CLI's credential store
  (N1); changing the row `environment` semantics; anything cloud; the dictation path;
  the safety spine.