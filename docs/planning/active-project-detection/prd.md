# PRD: Active Project Detection

> Source: `docs/planning/_card/issue.md` (founder request, 2026-10-01) + the touchpoint dig
> (2026-10-01). Founder decisions D1–D3 recorded below. C12-extension + agent-provider
> integration.

## Problem Statement

The founder works across many projects (`~/dev/manifold`, `~/dev/foresight`, `~/dev/at`,
…) and the agent handoff's `projectDirectory` must come from **context, not hand
configuration**. Today a row's directory is either typed into the editor or absent (the
child then runs in Vocca's own cwd — the cwd fix landed). The "active project" is a
real, observable fact: the **focused app's working directory** — you are in VS
Code/terminal/iTerm on `~/dev/manifold`, so that is the project. The AX metadata read
already resolves the focused app's **PID** (`AXContextSource.bundleIdentifier(of:)` —
`AXUIElementGetPid`); the cwd of that PID is one `proc_pidinfo` call away. Nothing here
needs new consent, new configuration, or a project list.

What happens if we don't build this: every agent row either pins one repo forever or the
user types a directory per task — the "voice → my current project" promise stays
hand-operated, and the founder's multi-project workflow pays the per-context cost Vocca
should pay once.

## Goals & Success Metrics

- **G1 — The active project is detected.** When an agent row's `projectDirectory` is
  empty, arming the row resolves the focused app's working directory and the
  confirmation sentence shows it: `Run the coding agent 'claude': … in
  ~/dev/manifold.` — the resolved path rendered verbatim, bound by the sentence binding.
- **G2 — Explicit wins.** A row with a configured directory uses it, deterministically
  (D2). Detection never overrides a row's explicit value.
- **G3 — One resolution per arm.** The directory is resolved **once, at arm time**, and
  carried through the whole confirmation path (invocation → gate render → post-record
  re-render → confirm → invoke's `currentDirectoryURL`) — byte-identical across every
  render, so a focus change mid-card can never produce a mismatch loop or a run in a
  directory the user was not shown.
- **G4 — Metadata privacy posture** (D1). The cwd read is a directory path, not
  content: no per-app consent (the bundleID/windowTitle lane), never persisted, shown in
  the sentence; it does **not** join `ContextSnapshot` (which is the AND-gated BYOK
  payload carrier — a metadata read must not ride that gate's semantics either way).
- **G5 — Measured, never claimed** (D3). `proc_pidinfo(PROC_PIDVNODEPATHINFO)` is
  expected to work for same-user processes on an unsandboxed app but is **unmeasured in
  this repo** — a SMOKE row measures it on the founder's real apps (VS Code, terminal,
  iTerm, Notes) before any "works everywhere" claim; the headless suite pins the seam
  over injected fakes.
- **G6 — Invariants hold.** Composed default still `agents=0 spawnsSubprocess=false`;
  zero network; the dictation path digest-untouched; lints green (a `proc_pidinfo` read
  names no forbidden family — the one hazard: never name an identifier starting with
  `Process`; the cwd adapter names no AX prefix).

## User Personas & Scenarios

- **The founder (primary).** Working in `~/dev/manifold` in VS Code: arm the claude row
  (directory left empty) → card says `… in ~/dev/manifold` → confirm → the agent runs
  there. Switch to `~/dev/at`, arm again → the card says `~/dev/at`.
- **The pinned user.** A row with an explicit directory never changes (CI scripts, a
  repo-specific agent).
- **The skeptic.** No agent rows: nothing resolves, nothing spawns; the default is
  byte-identical.

## Requirements

### Must-have

- **R1 — The cwd source** (`VoccaContext`, a new seam file — e.g.
  `Accessibility/WorkingDirectoryRead.swift`): a seam over an injected libproc closure
  (`proc_pidinfo(PROC_PIDVNODEPATHINFO)` → `vi_cwd`), plus the adapter the composition
  root wires. Names no AX prefix, no FileManager, no `Process`-prefixed identifier.
  `AccessibilityContext` exposes the read (the PID already flows through `AXContextSource`
  — the read may be extended there or handed through the existing seam shapes; Secure
  Input refusal stays first). Returns `nil` on any failure (the never-throw doctrine).
- **R2 — The carrier**: `ActionInvocation` gains `resolvedDirectory: String?` (additive,
  default nil — 59 existing construction sites compile unchanged); the agent provider's
  describe/invoke use `invocation.resolvedDirectory ?? agent.projectDirectory` for the
  sentence's `in <dir>` clause and the `currentDirectoryURL` — the argv-that-runs
  doctrine extended to the directory; **the gap-1 pin (arguments refusal) is untouched**
  (the directory is a separate field, never `arguments`). The sentence becomes
  nil-tolerant: no directory → no `in` clause (the existing render + pins update).
- **R3 — Arm-time resolution** (`composeCodingAgentWiring` gains an injected
  `activeProjectDirectory: @Sendable () async -> String?` closure, default nil-shaped):
  at arm, if the row's `projectDirectory` is empty, resolve once and build the
  invocation **with** `resolvedDirectory`; the signal/card carries it (additive field on
  `WidgetConfirmationSignal`), confirm rebuilds the invocation with the same value —
  one resolution, four identical renders (G3).
- **R4 — Editor copy**: the row editor's Project directory field's caption says "leave
  empty to detect the focused app's project".
- **R5 — Probe/pins**: the composed default facts unchanged; `ActionInvocation`
  Family-A file membership unchanged (a field, not a file); the module-coverage
  cross-check driven by the new VoccaContext file (the probe drive or a witness);
  **G5 re-anchor** if `AppBootstrap` changes (deliberate, computed, dictation digests
  unchanged).
- **R6 — SMOKE 161** (D3): measure the real read on the founder's machine — focused app
  → expected cwd for VS Code/terminal/iTerm (+ a negative row: a non-project app),
  recorded never gated; no rate quoted.

### Should-have

- **S1 — The arm-time fallback chain**: empty row + nil detection → the sentence has no
  `in` clause (the child runs in Vocca's cwd — the pre-fix behavior, now visible and
  honest in the sentence).

### Nice-to-have

- **N1 — A "detected" hint in the row editor** (live preview of the detected path next
  to the empty field).

## Technical Considerations

- **Phase:** P4, C12-extension (the context half) + agent-provider integration.
- **The metadata lane is NOT the resolve slot**: `root.contextResolution` is
  consent-gated (provider declined when consent is off) — the cwd read must not ride it
  (the dig's key finding). The arm-time closure is wired directly in the composition
  root over `AccessibilityContext`'s read.
- **Why the carrier exists**: the sentence binding demands four byte-identical renders;
  re-resolving at each render invites mismatch loops and a wrong-directory run race. The
  resolved value is fixed at arm, per invocation.
- **Lints**: no transport family, no FileManager, no AX prefix, no `Process`-prefixed
  identifier in the new file; `VoccaContext` may import `Darwin` (no import allow-list
  in that module; `ModuleBoundaryTests` permits system frameworks).
- **Privacy**: never persisted (the invocation is never persisted; the audit stores the
  sentence); never in the BYOK payload (not in `ContextSnapshot`, so the grant gate
  never carries it).
- **Local-first, zero network**: `proc_pidinfo` is a local syscall; the interposer is
  unaffected.
- **Dictation path**: untouched (digest-pinned).

## Risks & Open Questions

- **R-A — The read fails on some apps** (permissions, TCC-adjacent behavior, hardened
  processes): never-throw → nil → the honest no-clause sentence (S1). Measured by SMOKE
  161.
- **R-B — Focus change semantics**: the user arms in VS Code but switches to Mail before
  confirming — the run still happens in the directory shown (that is the point of the
  carrier; the confirmed sentence is the contract).
- **R-C — `proc_pidinfo` needs the frontmost PID**: under Secure Input the AX source
  refuses first (existing behavior) → nil → S1. Consistent.
- **Open:** whether the SMOKE row also measures an app whose cwd is `/` (Finder/desktop)
  — yes, as the negative row.

## Out of Scope

- `ContextSnapshot`/BYOK-payload changes (the metadata lane stays separate by design).
- A configured project list, window-title heuristics, per-app directory memory.
- Anything cloud, anything touching the dictation path or the safety spine.