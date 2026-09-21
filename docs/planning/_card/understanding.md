# Understanding: action-surface-wiring (C13 slice 5)

> Phase 2 output — written after the agent-team dig over the four C13 slice records and the
> shipped code, at the `stdio-transport` tip (`d872309`). Sources cited inline.

## What this work really is

C13's machinery is complete and *unusable*: `ActionGate` (spine), the audit store + real
`AuditActionProvider` (slice 2), `MCPProvider` + protocol + in-memory transport (slice 3), and
`StdioMCPTransport` (slice 4). Every record since slice 1 ends with the same sentence:
**"nothing is wired"** (`docs/STATUS.md:69-70`). This slice builds the surface that makes the
machinery reachable by a human, and the wiring that makes it reachable by the app.

## What must ship (per the card, `docs/planning/_card/issue.md`)

1. **Persisted per-tool enablement store** — N1's deferral is now due: "the persisted store
   (file, tolerant decode, byte-pin, permit rows, the `PersistentConsentStore` shape) lands
   with the slice that introduces real tools to enable" (`action-safety-spine/prd.md:295-297`).
   Real tools exist. `ActionEnablement` is a pure value (`ActionGate.swift:54-93`); nothing
   persists it. Default off; absent is off; declined **before any provider call, including
   before `describe`** (`confirmation-gate/spec.md:27-29`). Per-tool, never wholesale
   (`CAPABILITY_ROADMAP.md:387`).
2. **Confirmation prompt** — renders the provider's `describe` sentence as the only route to
   `invoke` in a shipped configuration (card). Contract: per-invocation only, no "don't ask me
   again" — it "has no representation in the type" (`prd.md:280-282`, M4a). The sentence is
   the entire content of the prompt (M5a). Read-only runs directly, no prompt (M3). The
   approval is constructed by the UI layer — that is where "the human saw the sentence" is
   asserted (`prd.md:288`, N2).
3. **Minimal server-configuration surface** — copy honoring D2: configuring a server is trust
   extended to its author (`README.md:190` commits this copy already). Default configuration
   must still spawn no child (card acceptance 3). Storage and placement are unspecified in the
   files — a decision this unit makes (see open questions).
4. **Additive composition-root wiring** — the C11/C12 recipe: `ActionWiring.swift`-style recipe
   in `VoccaBootstrap/`, nullable root slots on `DictationLoopRoot`, composition in
   `AppBootstrap.configure`, probe drive, expected-lifecycle constant, guard-the-guard test,
   wiring-family lint, **G5 re-anchor of `AppBootstrap.swift` only** — dictation digests
   (`SessionMachine.swift`, `DictationPipeline.swift`) unchanged
   (`TurnTakingComposedAcceptanceTests.swift:317-347`).
5. **First action-path SMOKE rows** — steps ≥144 (arm → confirm → invoke → audit row
   reconstructs). The "reserving numbers nobody could run" caution (`record/spec.md:58-60`) no
   longer applies: a surface now executes.

## Binding decisions inherited (not negotiable in the PRD)

- **M4a** — per-invocation confirmation; no "don't ask again" affordance may exist in the UI.
- **M7** — enablement default off, declined before `describe`; absent is off.
- **N2** — `.granted` asserts a human approved, cannot verify it; must be stated in the unit
  record (card caveat). The tightening reserved for "when a surface exists" (`prd.md:290-293`):
  bind the approval to the exact invocation and sentence shown — **this slice is that moment;
  whether the binding ships here is a PRD decision**.
- **Escalate-only blast radius** — the UI may never de-escalate a provider's claim; a
  provider under-declaring must still confirm (`confirmation-gate/spec.md:31-57`).
- **Raw arguments never persisted; the approved sentence is** — the prompt and the audit
  record must show the same rendered sentence (`mcp-protocol` record, `STATUS.md:126-131`).
- **D2** — server config is trust extended to the server's author; no spawned child in the
  default configuration; `Process` may be named only in
  `VoccaActions/MCP/StdioMCPTransport.swift` (the transport prohibition lint's exactly-one
  permitted entry, `ActionTransportProhibitionTests.swift:200-202`). If config UI code would
  spawn, STOP AND REPORT (`stdio-transport/transport/plan_20260921.md:26-27`).
- **The wiring must choose a real policy floor** — handed forward explicitly:
  "the wiring slice must choose a real floor" (`STATUS.md:158-159`); F2 removed `.none` as a
  default; 42 call sites say `.none` explicitly. The composition root is the first caller
  that may legitimately supply a named floor.
- **`spawnsSubprocess` is a declared value** a composition root folds into a fact (badge),
  the `requiresNetwork` analogue (`STATUS.md:27-28`).

## Open questions the PRD must decide (not addressed in files)

1. **Where does the confirmation prompt live?** The widget "never takes focus"; a confirmation
   needs a human. No prose describes the prompt's shape anywhere (`record/spec.md:62` excluded
   all UI). Candidate shapes: widget-panel sheet, menu-bar-driven, dedicated alert. This is the
   slice's biggest design decision. The widget cannot show a raw server-supplied sentence in a
   focus-stealing alert without the widget's own state machine (reducer row) knowing about it —
   the C12 precedent is a reducer row, never a wiring courtesy (`WidgetStateReducer.swift`).
2. **Where does server configuration live?** Settings tabs today: general/speech/cleanup/
   dictionary/apps/usage (`SettingsTab.swift:29`). No Actions tab; `PRODUCT_SPEC.md` says
   nothing about actions (`_card/understanding.md:196-199`). New tab vs. section in an existing
   tab. Storage file shape (the `PersistentConsentStore` shape: JSON, tolerant decode, byte-pin)
   — one file for enablement+servers or two? N1 commits only to the enablement store's shape.
3. **The policy floor**: what the wiring supplies to `ActionGate.submit`. Candidates: floor
   `.none` (server claim stands) vs. a named floor (e.g. outwardFacing always confirms —
   the §8 escape-valve discussion warned this must not be first-thought-about in the MCP
   slice; it was not decided there, `prd.md:338-344`).
4. **N2's binding** (see above): ship the sentence-binding (e.g. submit compares the sentence
   shown) or record it as deferred with the N2 limit stated?
5. **Scope cuts confirmed**: no intent layer (utterance → tool call; card doesn't include it;
   the "not confident" ask path is C13's remaining machinery, `CAPABILITY_ROADMAP.md:388`),
   no `ShellProvider`, no coding-agent handoff, no reply-text rendering. The confirmation
   prompt is for *machine-initiated* actions this slice can already produce (the gate's
   `.confirmationRequired`), so the intent layer is not a dependency of the surface.
6. **Who is the first configured server?** The card requires a server-configuration *surface*
   but nothing says a server must be configured by default (D2 forbids it). The demonstrable
   end-to-end path can run over `AuditActionProvider` (real, safe, zero-spawn) — the Q1
   answer (`_card/understanding.md:228-235`) — plus `MCPProvider` over `InMemoryMCPTransport`
   for the full MCP surface in the probe.

## Risk the slice mitigates (not retires)

R8 (destructive action the user didn't intend): this is the first human-in-the-loop safety
surface; the "zero unintended actions" P4 gate (`ROADMAP.md:250`) becomes enforceable only
after this slice. The prompt is the enforcement point, and its honesty limit (N2) is
structural, recorded in the unit record per the card.

## Layer / phase placement

Actions layer (P4), continuing C13. Local-only; no cloud, no egress; the MCP server surface
is BYOK-shaped (user configures their own server) and inherits the D2 copy. Does not touch
capture/ASR/cleanup/injection/TTS; the dictation path stays byte-for-byte pinned.