# PRD: Spoken Task Seeding (N1)

> Source: `docs/planning/_card/issue.md` (founder workflow feedback, 2026-10-01) + the
> N1 deferral records of `coding-agent-handoff` (`docs/planning/coding-agent-handoff/
> prd.md` N1) and `agent-presets` (`prd.md` N1). The design was settled with the founder
> in the 2026-10-01 session — decisions D1–D4 recorded in the requirements.

## Problem Statement

The agent handoff's rows are **fixed-argv**: a row runs exactly the task its `arguments`
spell at save time. The founder's actual workflow is "arm it and ask whatever I want" —
one claude row, any task, per conversation. The `<task>` placeholder in the preset
templates exists precisely because a fixed task is the wrong unit; but the editor refuses
to save it (correctly — a row that means nothing must not save), and the voice leg
"arms rows, never task text" (the N1 deferral, blocker named: the phrase resolver
produces no arguments and the agent's gap-1 pin refuses them). The result: the user hits
a save refusal on every preset, and the wedge's most natural sentence — "ask the agent to
X" — is unbuildable.

What happens if we don't build this: every agent row is a task-specific row forever; the
founder types a task into the editor per row and still can't ask anything ad hoc; the
voice loop's "do things" promise stops at fixed recipes.

## Goals & Success Metrics

- **G1 — The spoken task fills the argv.** A phrase row names an agent whose argv
  carries `<task>`; in conversation, the utterance is substituted in; the confirmation
  card shows the substituted argv verbatim; confirm runs it; the audit sentence shows
  it. One row, any task.
- **G2 — The sentence and the run cannot drift.** describe and invoke share one
  substitution render (the argv-derived doctrine): the argv that runs is the argv the
  sentence showed, with the spoken words in place.
- **G3 — The surface stays honest.** Arming a placeholder row from the Actions tab
  (no utterance exists) is refused loudly; the editor's `<task>`-Save refusal stays;
  the file may carry placeholder rows (hand-edited; a surface affordance is a recorded
  follow-on).
- **G4 — Bounds refuse, never truncate.** A `taskText` over the bound refuses; the
  gap-1 pin (arguments refused) is untouched — the task rides an additive invocation
  field, never `arguments`.
- **G5 — Invariants hold.** Composed default `agents=0 spawnsSubprocess=false`; zero
  network; dictation digests unchanged; lints untouched.

## User Personas & Scenarios

- **The founder (primary).** Phrase row: `{"phrase": "ask claude to summarize the open PRs", "providerID": "vocca.agent", "toolID": "claude"}` with the row's argv `["-p", "<task>"]` (hand-edited file). Converse: "ask claude to summarize the open PRs" → the card shows `Run the coding agent 'claude': /opt/homebrew/bin/claude -p "summarize the open PRs" in <detected project>.` → confirm → the agent runs with exactly that prompt.
- **The skeptical user.** No phrase rows, no placeholder rows: the default is byte-identical; nothing fills anything.

## Requirements

### Must-have

- **R1 — The carrier**: `ActionInvocation.taskText: String?` (additive, default nil —
  the `resolvedDirectory` precedent; Foundation-free; never `arguments` — the gap-1 pin
  intact).
- **R2 — The substitution**: the provider substitutes every literal `taskPlaceholder`
  occurrence in the row's argv with `invocation.taskText` when present; describe and
  invoke share one render (`substitutedArguments`-shaped pure function); a `taskText`
  present with NO placeholder in the argv → refused (the task has nowhere to go — the
  loud refusal, never a silent ignore); a placeholder present with NO `taskText` →
  refused loudly (the sentence would show a meaningless literal) — reachable only by a
  hand-built invocation (the surface refuses earlier); `taskText` over the bound
  (4096 UTF-8 bytes, the arguments precedent) → refused, never truncated.
- **R3 — The threading**: `ConverseLoopDriver`'s intent-action handler gains the
  utterance (the deliberate-widening precedent — the driver's fourteen init parameters
  were widened before); the intent wiring fills `taskText` from the utterance when the
  resolved tool is an agent row whose argv carries the placeholder; otherwise nil
  (byte-identical to today).
- **R4 — The surface refusal**: arming a placeholder row from the Actions tab → refused
  loudly (the loud copy; recorded, never a card). The editor's `<task>`-Save refusal
  unchanged.
- **R5 — Probe/pins**: the composed default facts unchanged; the Family-A file
  membership unchanged (a field); the G5 re-anchor if `AppBootstrap` changes
  (deliberate, computed, dictation digests unchanged); the module-coverage cross-check
  green.
- **R6 — SMOKE 162**: the real voice round trip on the founder's machine — phrase row +
  placeholder row → converse → card shows the substituted argv → confirm → the agent
  runs with the spoken task → the audit sentence reconstructs. Recorded never gated; no
  rate quoted.

### Should-have

- **S1 — The sentence's substitution bound**: the substituted argv in the sentence
  respects the audit summary's 1024-byte bound naturally (the existing truncation) —
  verified, never changed.

### Nice-to-have

- **N1 — A surface affordance to create placeholder rows** (a checkbox in the editor
  that knowingly allows `<task>` with the caption "filled by your spoken task") —
  deferred, recorded.

## Technical Considerations

- **Phase:** P4, C13 follow-on. Branch stacked on `feat/active-project-detection/aliz`.
- **The utterance's path**: the driver's intent step calls `intentProvider(utterance)`
  then `intentActionHandler(invocation)` — the utterance is in scope at the call site;
  the handler signature widening is the honest change (the closure default updates too).
- **The one-render rule**: the substitution lives in the provider (or a shared pure
  helper both describe and invoke call) — never in the wiring (the wiring has no render;
  the sentence and the run share the provider's view).
- **Safety**: the spoken words appear verbatim in the sentence and the audit; the
  binding applies; the always-confirm floor is untouched (agent rows are outwardFacing).
- **Privacy**: taskText is never persisted outside the sentence (the audit records the
  rendered sentence only); zero network; local.
- **Lints**: a field, not a file — Family A/B and the transport lint untouched; the
  driver's signature change touches `ConverseLoopDriver.swift` (its compile pins update
  deliberately).

## Risks & Open Questions

- **R-A — A long utterance**: bounded by the 4096-byte refusal (G4); the refusal is
  loud and the turn falls through to the echo (the intent step's existing fallback).
- **R-B — The user edits the placeholder row's argv at runtime**: the row is read per
  call in the wiring (the per-turn registry read); a changed argv next turn is a new
  render — the binding covers the shown sentence.
- **R-C — Voice + surface drift**: the surface refuses placeholder rows; the voice leg
  fills them — the two paths cannot disagree because only one of them can reach a
  placeholder row (asserted by tests).
- **Open:** whether the editor gains the S1 checkbox in this unit or a follow-on
  (recorded; the file is hand-editable meanwhile).

## Out of Scope

- Surface-side task entry (the editor checkbox — N1/nice-to-have), `$N` parameter
  slots, interactive sessions, anything cloud, any change to the safety spine or the
  dictation path.