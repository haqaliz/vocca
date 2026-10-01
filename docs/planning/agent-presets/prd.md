# PRD: Agent Presets & Discovery

> Source: `docs/planning/_card/issue.md` (inline brief, 2026-10-01) + the Wispr Flow deep
> dive (2026-10-01). Founder decisions Q1–Q3 recorded in the requirements below.
> Follow-on unit to `coding-agent-handoff` (C13 slice 9) — branches from it.

## Problem Statement

The coding-agent handoff shipped with hand-written JSON authoring: users create
`coding-agents.json` by hand with absolute executable paths, argv, a project directory and
API-key environment entries. The founder's own first-run feedback — and the Wispr Flow
deep dive — say the same thing: a commercial dictation tool earns its zero-friction
authoring (in-app snippets, learned dictionary) by keeping the blast radius tiny; our
agent rows genuinely execute code, so the safety spine stays — but **the authoring UX
does not have to**. Today `CodingAgentRegistry.save` is reachable from exactly one place:
the probe (`CodingAgentDrive.swift:224`). No UI closure can write a row.

What happens if we don't build this: the wedge's most powerful surface ("voice → a coding
agent") stays a JSON-editing exercise, users fall back to copy-pasting configs from
READMEs, and the founder's own stack (claude, codex, gemini, opencode — all non-interactive
CLIs with near-identical shapes) pays a per-agent setup cost Vocca should pay once.

## Goals & Success Metrics

- **G1 — A row can be authored without touching the file.** The Coding agents section
  gains "Add coding agent": choose a known preset (or blank), edit all row fields,
  Save writes a real row through `CodingAgentRegistry.save`. The file remains the source
  of truth (byte-pinned, tolerant load unchanged) — the editor is a writer, never a
  second store.
- **G2 — Installed CLIs are visible.** On section open, the known agents render with a
  "Detected / not detected" fact, resolved from known absolute paths and the app's own
  PATH over the injected file-system seam. Honest limit recorded: detection = the binary
  exists at a path, never that it runs or its version.
- **G3 — Presets are seeds, not magic.** The known-agents catalog is a code-level,
  reviewed-edit seed (the `EngineCandidate` precedent): eight CLIs, each with candidate
  binary names and a non-interactive argv template. Selecting a preset pre-fills the
  editor — the user can change anything before Save. No placeholder execution, no
  auto-created rows.
- **G4 — Safety unchanged.** Presets are outwardFacing by construction, always-confirm,
  no readOnly; nothing spawns and nothing is created by the catalog or by detection; the
  composed default still reads `agents=0 spawnsSubprocess=false`; the transport lint and
  the FileManager seam tables stay untouched (detection rides `ActionConfigFileSystem`).
- **G5 — Every row a user can see is a row that round-trips.** The editor refuses
  duplicate ids (the registry's first-wins would otherwise silently skip), validates
  before save (the definition's own `init?` rules — absolute paths, timeout range), and
  folds save failure loudly (`saveSucceeded`/`saveFailed`, the Servers editor pattern).

Measurement: CI-gated probe/catalog/round-trip assertions. Real observation: SMOKE rows
(157→~160) — the founder adds a preset row on the real surface — recorded, never gated.

## User Personas & Scenarios

- **The founder (primary).** First run with Vocca after this slice: Settings → Actions →
  Coding agents shows "claude — detected ✓, opencode — detected ✓, codex — not detected";
  picks claude, the editor is pre-filled (`/opt/homebrew/bin/claude`, argv template),
  adds the project directory + API key, Save, enables the row, arms it by voice. Never
  opened a JSON file.
- **The power user.** Uses the editor for everything except exotic rows; still hand-edits
  `coding-agents.json` when she wants to, and the editor reflects her file edits on next
  open (load is per-call; the file is the memory).
- **The skeptic.** Configures nothing: the section shows the presets with their detection
  facts and the empty-state copy; the default configuration still spawns nothing.

## Requirements

### Must-have

- **R1 — Known-agents catalog** (code-level seed in `VoccaActions`, the
  `EngineCandidate` precedent; a reviewed edit, pinned by tests). Eight presets
  (founder decision Q1), each: `id`, `displayName`, candidate binary names
  (e.g. `claude`; `claude-code` as an alternate), non-interactive argv template
  (e.g. `claude`: `["-p", "<task>"]`; `codex`: `["exec", "<task>"]`; `gemini`:
  `["-p", "<task>"]`; `opencode`: `["run", "<task>"]`; `aider`: `["--message", "<task>"]`;
  `cursor`: `["run", "<task>"]`; `q` (Amazon Q): `["-p", "<task>"]`; and one more
  reviewed-in (e.g. `crush`): each template a seed — pinned verbatim, retuned by
  reviewed edit, never a claim about the CLI's real behavior). The `<task>` placeholder
  is a *string the user edits in the form*; it is never executed as a substitution this
  slice (N1 stays deferred).
- **R2 — Detection** (founder decision Q3): on section open, resolve each preset's
  candidate names against a candidate path list (the injected `ActionConfigFileSystem`
  seam — no new FileManager-naming file, no lint table edit) + the app process's own
  `PATH`; render "Detected / not detected" per preset. Detection spawns nothing, reads
  nothing but the filesystem. Honest limit on the surface copy: "detected" = the binary
  exists at that path.
- **R3 — The row editor** (founder decision Q2): an "Add coding agent" affordance in the
  Coding agents section — choose a preset (pre-fills executable/argv) or blank; fields:
  id, executablePath, arguments, projectDirectory, timeoutSeconds, environment
  (key/value pairs), clause; Save validates via the definition rules and writes through a
  new `saveAgents` binding → `CodingAgentRegistry.save` (the root's `agentRegistry` slot
  already exists). Refuses duplicate ids and invalid rows loudly; folds
  `saveSucceeded`/`saveFailed` (the Servers editor pattern, stable UUID minted once).
- **R4 — Surface wiring**: `SettingsBindings` gains `saveAgents` (+ a no-op default,
  the doctrine); `AppBootstrap.showSettings` fills it from `agentRegistry`;
  `ActionsTabState` gains the draft/editor rows (the `.serverAdded`/`.serverEdited`
  template); `ActionsTabPage` renders the editor; copy follows `ActionsTabCopy`
  conventions.
- **R5 — Probes/pins**: the catalog seed pin; detection over an injected path source
  (no real `which` in CI); the editor's save round trip (write → reload → row present,
  byte-stable); the composed default still `agents=0 spawnsSubprocess=false`
  (PROBE-CODING-AGENT post-condition unchanged); the G5 pin untouched unless
  `AppBootstrap` changes (it does — the binding; re-anchor deliberate, dictation digests
  unchanged); the Family A/transport/FileManager lints untouched.

### Should-have

- **S1 — Edit + remove existing rows** from the section (mirror the Servers editor's
  edit/remove, including the enablement cascade on remove). If the unit runs short, the
  add path ships first; edit/remove is the recorded follow-on.
- **S2 — The editor pre-fills projectDirectory** from a remembered last value (in-memory
  only this slice; persistence is a later call).

### Nice-to-have

- **N1 — `{{task}}` utterance seeding** — still deferred (N1 of the parent unit); the
  form's placeholder string is the stopgap.
- **N2 — Detection refresh** — a re-detect affordance after installing a CLI.

## Technical Considerations

- **Phase:** P4, C13 follow-on (slice 10). Branch: `feat/agent-presets/aliz` from
  `feat/coding-agent-handoff/aliz` (stacked; the parent merges first).
- **Seam:** none new — the registry, provider, wiring and gate all ship. This slice is
  surface + a code-level catalog + a save path.
- **The save path is the one-line gap:** `agentRegistry` is already a root slot
  (`AppBootstrap.swift:1741`); the wiring closure is `try await agentRegistry.save(file)`.
- **FileManager lint:** detection must NOT name FileManager — ride the injected
  `ActionConfigFileSystem.fileExists` seam (already injected into the registry).
- **Safety:** no readOnly anywhere; presets outwardFacing; always-confirm; the catalog
  and detection create nothing.
- **Local-first:** detection is local; the catalog is code; nothing egresses. The
  <task> string never substitutes (no execution of templates).
- **Dictation path:** untouched (digest-pinned).

## Risks & Open Questions

- **R-A — Detection lies about usefulness.** A detected binary may be stale, wrong-arch,
  or require sign-in. Mitigation: the copy says "exists at path", never "ready"; the
  run's failure is a loud returned value (parent unit).
- **R-B — Preset argv templates drift** as CLIs change their non-interactive flags.
  Mitigation: seeds pinned verbatim, retuned by reviewed edit (the synonym-table
  precedent); the form lets users fix argv per row without a code change.
- **R-C — The editor and the hand-edited file diverge.** Mitigation: the editor writes
  the same file the tolerant loader reads; no separate store; load is per-call; a
  hand-edit shows up on next open (byte pin unchanged).
- **Open:** the 8th preset's identity (proposed `crush` — a reviewed edit during
  planning); whether edit/remove (S1) fits in this unit's calendar.

## Out of Scope

- `{{task}}` utterance seeding (N1, deferred), `$N` parameter slots, interactive
  sessions, desktop-app (MCP-host) integrations, anything cloud.
- Learning/auto-dictionary (the Wispr "learns your words" pattern is a C5/dictionary
  concern, not this unit).
- Changing the safety spine: the gate, the card, the audit, the always-confirm floor.
- Any change to the dictation path or the intent seam.