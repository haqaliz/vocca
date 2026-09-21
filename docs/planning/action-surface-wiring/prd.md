# PRD: action-surface-wiring — C13 slice 5

> **Phase:** P4 (Actions/MCP) · **Slug:** `action-surface-wiring` · **Branch:**
> `feat/action-surface-wiring/aliz`
>
> Source: `docs/planning/_card/issue.md` (inline brief, 2026-09-21) + the deep-dig
> understanding note at `docs/planning/_card/understanding.md`. Inherited decisions cited
> from the four prior C13 slice records; decisions made in this unit are marked **[decided
> here]**.

## Problem Statement

Four C13 slices shipped the action layer's *machinery*: the safety spine (`ActionGate`,
`ActionProvider` seam, slice 1), the audit store and the first real provider
(`AuditActionProvider`, slice 2), the MCP protocol layer and `MCPProvider` (slice 3), and the
`StdioMCPTransport` (slice 4). Every one of those records ends with the same sentence:
**"nothing is wired"** (`docs/STATUS.md:69-70`). No human has ever seen a confirmation
sentence; no tool can be enabled persistently; no server can be configured; no action has
ever executed in a shipped configuration. The R8 mitigation — the gate that makes a
destructive action without confirmation structurally impossible — exists but has no
human-in-the-loop surface, so the P4 gate's "zero unintended actions"
(`docs/ROADMAP.md:250`) is not enforceable, only assertable in tests.

This slice is the one that makes the machinery reachable: the persisted per-tool enablement
store that slice 1 explicitly deferred ("the persisted store … lands with the slice that
introduces real tools to enable", `action-safety-spine/prd.md:295-297`), the confirmation
prompt as the only route to `invoke`, the minimal server-configuration surface with the D2
copy, and the additive composition-root wiring that C11/C12 established as the recipe.

## Goals & Success Metrics

| Goal | Metric |
|------|--------|
| A human can enable a tool, arm it, see the concrete sentence, confirm, and reconstruct it from the audit log | Card acceptance 5: the arm → confirm → invoke → audit-row-reconstructs path exists on the real surface and is observable by the founder (SMOKE ≥144) |
| The gate remains the only route to `invoke` | The existing construction-confining lint stays green; the shipped configuration's only invoke path runs through `ActionGate.submit` |
| Per-tool enablement persists and defaults to off | Enable → invoke → disable refuses the next invocation with **no carry-over**, and enablement survives relaunch (card acceptance 2, M7) |
| The N2 tightening ships | Approving a sentence different from the one the gate renders is refused **by attempting the call** (card caveat + `prd.md:290-293`) |
| The default configuration still spawns no child and makes zero network calls | The zero-network probe stays green over the new wiring; the probe reports the composed default's `spawnsSubprocess == false` (card acceptance 3, D2) |
| Dry-run never touches a provider's `invoke` | Card acceptance 4: zero provider side effects on the dry-run path, asserted on the stub's call log |
| Test floor | Every new acceptance is a test written before its code; floor rises from 2629 |

Success is **not** gated: no gate passes; this is the ninth unit built ahead of the
uncleared gates under the recorded posture.

## User Personas & Scenarios

- **The founder (today's only user).** Wants to see the action layer do something real:
  enable `audit.count`/`audit.clear`, arm `audit.clear`, read the concrete sentence
  ("Permanently delete 12 entries from the action audit log. This cannot be undone."), click
  Confirm, and find the record in the audit log. Also wants to point Vocca at one real MCP
  server (`node server.js`) and see its tools listed, enabled individually, and invoked —
  with the honest copy that this is trust extended to the server's author.
- **A future MCP-server user.** Wants to add/remove servers and see their tools without a
  blanket "enable all". Defaults off everywhere; never a wholesale grant
  (`CAPABILITY_ROADMAP.md:387`).
- **The reviewer/contributor adding the next provider.** Hits the seam the four slices
  built; the surface must not special-case `MCPProvider` or `AuditActionProvider` — it
  drives `ActionProvider` + `ActionGate` and nothing else.

## Requirements

### Must-have

**R1 — Persisted per-tool enablement store.** [decided here: placement] A byte-pinned,
tolerant-decode JSON store in `VoccaActions` (the `PersistentConsentStore` shape promised by
N1: file, tolerant decode to empty on corruption, byte-pin on the key set, cap) holding
per-`providerID`+`toolID` enablement rows. Default off; absent is off (M7). Enablement
survives relaunch. Membership is by whole `ActionInvocation` — the existing
`ActionEnablement` value's semantics — persisted as provider/tool rows, never raw arguments.

**R2 — Confirmation prompt as the only route to `invoke`.** [decided here: widget panel
card] The widget shows a confirmation card: the provider's `describe` sentence, verbatim,
plus Confirm/Decline. Per-invocation only — **no "don't ask me again" affordance exists**
(M4a; the type has no representation for it and the reducer must not add one). Read-only
invocations run directly with no card (M3). The card is a widget state reached via a reducer
row — the C12 precedent ("the reducer row, never a wiring courtesy",
`WidgetStateReducer.swift`). **Arming is refused while a session is in flight** (the
hotkey-rebinding in-flight refusal precedent, `CAPABILITY_ROADMAP.md:53`); the card cannot
appear mid-dictation. The Confirm action constructs `.granted` — that construction is the
UI layer's assertion that "the human saw the sentence" (`prd.md:288`). The card's rendered
UI is SwiftUI and is executed by nothing in CI (the `MenuBarItem`/CGEvent-tap precedent);
the reducer row and the wiring closures are what CI asserts, and SMOKE 145 observes the
rendered surface.

**R3 — N2 sentence binding.** [decided here: ship now] `ActionGate.submit` gains an
additive `approvedSentence: String? = nil` parameter. With `approval == .granted` and a
non-nil value, the gate compares it to its own freshly-rendered sentence and refuses on
mismatch with a bounded decline key (`approvedSentenceMismatch`). `nil` keeps every existing
call site compiling with byte-identical behaviour. The surface **always** supplies the
sentence it showed. Acceptance: a granted approval for a sentence that differs from what the
gate renders is refused by attempting the call.

**R4 — Minimal server-configuration surface.** [decided here: new Settings tab "Actions",
one store file] Servers: name, absolute executable path (no PATH lookup — the
`StdioMCPTransport.Configuration` contract), arguments. **No server is configured out of the
box** (D2: the default configuration cannot create a child). The surface carries the D2 copy
verbatim in spirit: configuring a server is trust extended to its author, not a guarantee
(`README.md:190`). **Tool discovery is an explicit user action, and it spawns.** Listing a
server's tools requires `MCPProvider.discover`, which requires a live session — for a stdio
server that means running the configured executable. Discovery therefore happens only on the
user's explicit "Discover tools" action, the D2 copy is shown at that moment, and the
default configuration still never spawns (no server exists until the user adds one). A
server's discovered tools are listed with per-tool enablement rows, default off. Tests that
spawn for discovery run outside the interposer — the suite's own D2 instance (the
`/bin/cat` precedent, `docs/STATUS.md:73`).

**R5 — Arm surface.** [decided here: Actions-tab invoke rows] Each enabled tool shows an
"Invoke" row (the onboarding TRY IT precedent) that submits an invocation with empty
arguments through the gate. The gate returns `.confirmationRequired(summary)` for
destructive/outward-facing tools (or `.previewed` in dry-run); the confirmation card then
appears. No argument-building UI — that is the intent layer's job (out of scope).

**R6 — Dry-run.** The arm surface offers "Preview" alongside Invoke: submits with
`mode: .dryRun`, renders the sentence, performs **zero** side effects — `invoke` is called
zero times (M5, asserted on the provider's call log).

**R7 — Composition-root wiring.** The C11/C12 additive recipe
(`docs/STATUS.md:344-346, 476-478`): an `ActionWiring.swift`-style recipe in `VoccaBootstrap`
composing the executor (gate → audit recorder), the config store, the policy floor, and the
surface bindings; nullable root slots on `DictationLoopRoot`; composition in
`AppBootstrap.configure`; **G5 re-anchor of `AppBootstrap.swift` only** — the dictation
digests (`SessionMachine.swift`, `DictationPipeline.swift`) remain unchanged
(`TurnTakingComposedAcceptanceTests.swift:317-347`). The wiring folds the
`spawnsSubprocess` facts it composes into the probe report (the `requiresNetwork` analogue,
`STATUS.md:27-28`).

**R8 — The executor between gate and store.** [the gap the probe must close] A
`VoccaActions` actor that submits through `ActionGate` and records **every** decision
(`autoRanReadOnly` / `confirmed` / `refused` / `dryRun`) to `FileSystemActionAuditStore` —
the gate cannot write the store (VoccaCore is Foundation-free), so the caller owns
recording; this is the only complete round trip the probe and the surface share. The
"approved sentence is what reaches disk" property (`STATUS.md:126-131`) holds by
construction: the executor records the gate's decision, whose summary is the rendered
sentence.

**R9 — Probe + guard-the-guard.** The zero-network probe drives the composed action wiring
over real temp-directory stores (the `PROBE-ACTIONS`/`PROBE-MCP` pattern): arm → confirm →
invoke → reload → reconstruct, plus the composed default's fact report
(`servers=0`, `spawnsSubprocess=false`). Expected-lifecycle constant + guard-the-guard test
that refuses a weakened golden string (`ZeroNetworkTests.swift:1789, 1854` precedent).
No new module is added; the module-coverage cross-check stays green.

**R10 — First action-path SMOKE rows.** Steps 144+ in `docs/SMOKE_CHECKLIST.md`, recorded
never gated: (144) Actions tab shows the D2 copy and no default server; (145) arm → confirm
→ invoke → audit row reconstructs through the real surface; (146) enablement survives
relaunch; (147) the widget card shows the gate's sentence verbatim before invoke.

### Should-have

**S1 — Policy floor decision, named.** [decided here: `.none`, recorded] The wiring supplies
`ActionRadiusPolicy.none` and the choice is **recorded as a decision, not an unexamined
default**: the F1/F2 fail-safes already force confirmation on anything without a genuine
`readOnlyHint` (absent means unsafe, `STATUS.md:94-95`), so a floor of `.destructive` would
force confirmation even on genuinely read-only tools and break M3's read-only-runs-directly
contract. Escalate-only means the floor can only raise; `.none` is the minimal honest floor.
The decision is stated in the unit record and in `ARCHITECTURE.md`'s policy row.

**S2 — Enablement UI in the Actions tab.** Per-tool toggles; a tool's row shows provider,
tool id, and the radius the provider claims; a disabled tool's row is clearly inert.

### Nice-to-have

**N1 — Per-server enable/disable.** A whole-server toggle that disables all of its tools at
once (still per-tool rows underneath; never a blanket enable of an unknown server).

## Technical Considerations

- **Layer:** Actions (P4), continuing C13. Touches `VoccaCore` (`ActionGate`), `VoccaActions`
  (store, executor, providers), `VoccaBootstrap` (wiring), `VoccaUI` (card, tab), the probe,
  and `Tests/HarnessTests`. Does **not** touch capture/ASR/cleanup/injection/TTS; the
  dictation path stays byte-for-byte pinned.
- **Phase/sequencing:** P4. Prerequisites (C10/C11/C12 and C13 slices 1-4) shipped. No gate
  passes; the recorded posture is building ahead of the uncleared gates.
- **Module boundaries (the load-bearing constraints):**
  - `VoccaCore` imports nothing (empty import allow-list) — `ActionGate`'s new parameter and
    the new decline reason are stdlib-only. No Foundation anywhere in `VoccaCore`.
  - `VoccaActions` depends on exactly `["VoccaCore"]` — the config store and the executor
    live here (the FileManager seam + JSON machinery precedent:
    `ActionAuditFileSystem`, `FileSystemActionAuditStore`).
  - `VoccaUI` depends on exactly `["VoccaCore"]` — the widget card renders `ActionSummary`
    (a Core type) but must never name a provider instance; Confirm/Decline are closures
    supplied by the wiring (the `MenuBarItem`/`SettingsBindings` closure-seam precedent).
  - `Process` may be named in exactly one file
    (`VoccaActions/MCP/StdioMCPTransport.swift`) — any config code that would spawn must
    route through it or STOP AND REPORT (`stdio-transport/transport/plan_20260921.md:26-27`).
    The Actions-tab server rows never spawn at config time; spawning happens only at
    session use.
- **Latency:** not on the dictation latency path. The confirmation card adds no
  capture/ASR/inject latency; the executor's audit write is post-decision.
- **Privacy/local-first:** raw arguments never persist; the approved sentence is what
  reaches disk (`STATUS.md:126-131`). Server configuration is BYOK-shaped (the user's own
  server); the D2 copy is on the surface. Zero network and zero spawn in the default
  configuration (R7/R9).
- **The G5 pin:** `AppBootstrap.swift` will change exactly as often as the wiring aspect
  commits touch it; recompute `shasum -a 256` in the same commit, never edit-to-match
  (`TurnTakingComposedAcceptanceTests.swift:340-345`).
- **Test floor:** every acceptance is a failing test first; the floor ratchet rises in the
  same commit as the tests (`Scripts/test-with-floor.sh`).

## Risks & Open Questions

| Risk / question | Notes |
|-----------------|-------|
| **R8 — destructive actions the user didn't intend** (mitigated, not retired) | The card's caveat: this slice is the first human-in-the-loop surface. N2's limit — an approval asserts a human said yes and cannot verify it — is stated in the unit record. The prompt is the enforcement point; the sentence binding (R3) narrows the replay window but does not verify the human. |
| **D2 — the child is not observable** | Not eliminated by this slice; the default configuration cannot create one (R4) and the copy says where the claim stops (R10-144). **Discovery spawns on explicit user action** (R4) — that spawn is the trust the user extends, and it is refused-by-absence in the default configuration. Any config-surface code that names `Process` trips the lint — the review must catch it. |
| **The binding's refusal UX is undefined** | When the gate's sentence differs from the one the card showed, the card gets a declined outcome. Does the surface re-render the fresh sentence for a second prompt, or show the mismatch plainly? Open question for the confirmation-card aspect — the default should be: show the fresh sentence as a new card (the binding's refusal is a *re-prompt*, not a dead end). |
| **The rendered card is executed by nothing in CI** | SwiftUI, like `MenuBarItem` and the CGEvent tap. CI asserts the reducer row and the wiring closures; SMOKE 145 observes the rendered surface (recorded, never gated). |
| **The widget "never takes focus"** | The confirmation card is on Vocca's own surface, not the target app's; the never-focus contract is about not stealing focus from the target app. Buttons only — no hotkey affordance in this slice (the hotkey space is the capture chords'). |
| **Sentence drift between show and confirm** | R3 addresses it via the gate's comparison; the residual window (UI shows S, gate renders S' at submit) is closed by the binding. Any drift that survives (provider that returns different sentences for identical invocations) still gets caught by the binding. |
| **`summary` overload** | The executor records gate decisions; the two existing summary producers (gate decline keys, provider sentences) don't change. If a third kind appears, split the field (`prd.md:183-186`) — not this slice. |
| **MCP argument rendering on the arm surface** | Arm rows submit empty arguments; `MCPProvider.describe` renders `key = value` from them. Tools requiring arguments will refuse (`mcp.unreadableArguments` / refusal) — honest, and the intent layer's later job. |
| **Enablement row semantics vs tool discovery** | Enablement rows are keyed `providerID`+`toolID`; a server's tools are discovered at config time. A tool that disappears from a server keeps its row (stale) until the server re-lists — tolerant-decode keeps it valid; noted in the store's doc. |

## Out of Scope

- **Intent layer** (utterance → tool call, the "not confident" ask path) — C13's remaining
  machinery (`CAPABILITY_ROADMAP.md:388`), explicitly not this slice (card).
- **Argument-building UI** for MCP tools.
- **`ShellProvider`** — highest-blast-radius component, deferred (`prd.md:213`).
- **Coding-agent handoff** and reply-text rendering.
- **Voice-triggered actions** (converse-mode action flow) — the arm surface is
  tab-initiated; the voice path needs the intent layer.
- **"Don't ask again" / time-boxed trust / any §8 escape valve** — M4a binds this slice;
  the §8 shapes (`prd.md:338-344`) are flagged as the *next* slice's conversation.
- Any change to the dictation path, capture, ASR, cleanup, injection, or TTS surfaces.
- Cloud anything: no hosted provider, no telemetry, no egress.

## Decisions made in this unit (for the record)

1. Confirmation prompt = **widget panel card** (reducer row; buttons; no focus theft).
2. Server configuration = **new Settings tab "Actions"**, **one store file**
   (`action-config.json`-shaped) holding servers + enablement, byte-pinned, tolerant decode.
3. Policy floor = **`.none`, recorded as a decision** (F1/F2 fail-safes already confirm
   absent claims; a stricter floor breaks M3).
4. N2 sentence binding = **ships now** (additive `approvedSentence` parameter, nil = today's
   behaviour).
5. Arm surface = **Actions-tab Invoke/Preview rows**, empty arguments, through the gate.
6. Executor = a `VoccaActions` actor owning gate-submit + audit-record; the only complete
   round trip the probe and the surface share.

## Aspect decomposition (proposal)

| Aspect | Boundary |
|--------|----------|
| `enablement-store` | Persisted config store (servers + enablement) in `VoccaActions`: tolerant decode, byte-pin, cap, permit rows |
| `sentence-binding` | `ActionGate.submit` `approvedSentence` parameter + `approvedSentenceMismatch` decline key, test-first |
| `executor` | The gate→audit recorder actor in `VoccaActions`, mapping every `ActionDecision` to a recorded entry |
| `confirmation-card` | Widget reducer row + card state + `WidgetStateStore` entry points + panel rendering |
| `actions-tab` | `SettingsTab.actions` case, `ActionsTabState/Page/Copy`, bindings closures (load/save config, arm, preview, enable/disable) |
| `wiring` | `ActionWiring` recipe, root slots, `AppBootstrap.configure` composition, probe drive + expected lifecycle + guard-the-guard, G5 re-anchor, wiring-family lint |
| `record` | Unit record, STATUS/CLAUDE.md updates, SMOKE 144-147, floor ratchet, ARCHITECTURE.md policy row |