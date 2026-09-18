# PRD: context-provider — C12, active app and selection

**Date:** 2026-09-18 · **Phase:** P4 (context + actions) · **Unit type:** capability (test-first)
**Source:** `docs/planning/_card/issue.md` + `docs/planning/_card/understanding.md`
**Branch:** `feat/context-provider/aliz`

---

## Problem Statement

The wedge is "great dictation + a voice-agent loop that *does things*" — and "doing things"
starts with knowing what the user is looking at. Today Vocca can inject text into the focused
field but cannot see it: `TargetContext` carries only `bundleID` + `windowTitle`
(`Sources/VoccaCore/TargetContext.swift:35-42`), and no `ContextProvider` exists anywhere in
`Sources/` (dig: zero code matches; only the architecture reservation at
`docs/technical/ARCHITECTURE.md:151,281`). The next capability — C13, Actions and MCP — is
**blocked on this one** (`CAPABILITY_ROADMAP.md:379`: "Dependencies: C10, C11, C12"), and the
P3 gate's conversational leg stays formally unmet until C13's real agent
(`docs/STATUS.md:97-99`). "Summarize this", "send this to Slack", "make this a Jira ticket"
all presuppose that Vocca can resolve what "this" is.

The hard half is not the AX read — it is the **privacy contract**. Reading other apps'
content is the sharpest privacy edge in the roadmap (`CAPABILITY_ROADMAP.md:347`: "reading
other apps' content is exactly the power a privacy-first tool must be most careful with, and
must be most visible about"). The C12 acceptance exists to make that claim **auditable rather
than promised**: with capture off for an app, no content read of that app occurs at all — not
read-then-discard, but never read; and context never reaches a BYOK request payload without a
separate, explicit grant (`CAPABILITY_ROADMAP.md:353-355`).

## Goals & Success Metrics

| Goal | Metric | Where it's judged |
|---|---|---|
| Correct resolution | ≥95% correct app + selection resolution across the C8 20-app matrix | Scripted corpus over a stub adapter in CI; env-gated real run + SMOKE row, recorded never gated (the turn-commitment pattern, `STATUS.md` turn-taking entry) |
| Never read without consent | With consent off for an app, **zero** content AX reads of that app — asserted structurally, not by discipline | The never-read acceptance test, CI |
| Never egress without a separate grant | Context absent from every BYOK request payload until the separate global grant is on | The never-in-payload acceptance test, CI |
| Visible by default | Context indicator + one-action kill switch present when consent is active | Widget + menu-bar contract tests, CI |
| Zero-network invariant | Default configuration still makes zero network calls; consent store holds bundle IDs only | `PROBE-CONTEXT` inside the interposer, CI |

**Non-goals as metrics:** no context-accuracy percentage may be quoted until a real run
exists (recorded-never-gated posture); no gate passes in this unit.

## User Personas & Scenarios

**Persona — the privacy-aware power user (the ICP).** A Mac user who lives in dictation all
day and won't send audio or text to the cloud. They will grant context to apps *they* decide
deserve it — e.g. their editor and browser — and expect Vocca to say loudly, at all times,
when that reading is armed, and to stop the moment they say stop.

> **Validity note (assumed, not validated):** no external users exist yet — the P2 gate's
> external-users leg is unmet and the founder has not run this surface. The persona and
> scenarios below are inferred from `CAPABILITY_ROADMAP.md` and the P2/P3 gate language,
> not observed. The SMOKE rows this unit adds are the first real observation of the surface;
> no claim of validated demand is made here.

**Scenario A — the C13 future (the reason this exists).** The user is in a document,
dictates "summarize this", and C13 resolves "this" to the selected text. Every part of that
resolution is gated here: the app was consented, the indicator was visible, the kill switch
was one action away, and nothing was persisted or egressed.

**Scenario B — the audit.** A skeptical user inspects what Vocca does. The never-read test,
the never-in-payload test, the consent file (bundle IDs only), and the badge are the whole
answer. No telemetry, no logs of selection text, no silent reads.

## Requirements

### Must-have

- **M1 — The seam.** `ContextProvider` protocol declared in `VoccaCore` (the §2 rule —
  `ARCHITECTURE.md:82-84`: the core owns every seam). Yields a `ContextSnapshot`: active
  bundle ID, window title, selected text. Plain-data, `Sendable`.
- **M2 — Two implementations, both local.** `NullContext` (the shipped default — resolves to
  an empty snapshot, reads nothing) and `AccessibilityContext` (the real AX adapter) behind
  the seam (`ARCHITECTURE.md:281`). The seam-doctrine guardrail (`CAPABILITY_ROADMAP.md:414`)
  is **met, not exempted**.
- **M3 — The new module.** `VoccaContext` target added to `Package.swift` (the
  `ARCHITECTURE.md:151` reservation), importing only `VoccaCore`. It owns the AX adapter and
  its own **reviewed per-seam AX lint permit** (the `KeystrokeSource` precedent,
  `ARCHITECTURE.md:169-180`); `VoccaInject/Accessibility/AXSource.swift` stays untouched.
- **M4 — Per-app consent, default off.** A persisted consent store keyed by bundle ID
  (mirroring `strategies.json`: versioned shape, atomic temp-write + `replaceItemAt`,
  tolerant decode, capped entries — `PersistentInjectionStrategyStore` pattern). The gate
  **declines before any AX call** for an unconsented app — the `AccessibilityRungStrategy`
  precedent (`AccessibilityRungStrategy.swift:99-104`): not read-then-discard, never read.
  No blanket "allow all" anywhere.
- **M5 — The never-read acceptance.** With consent off for an app, no content read of that
  app occurs at all. Scoped to **content** (selected text): bundle ID + window title are
  already read by the dictate path for the failsafe copy and matrix evidence
  (`AXSource.focusedApp()`; `TargetContext`) — the test and the lint must agree on exactly
  which AX reads count as content reads, so the guarantee can't be laundered through the
  dictate path.
- **M5b — Secure Input refusal.** Content reads return an **empty snapshot on Secure Input
  fields** — the honest-refusal precedent the dictate path already sets (roadmap R2:
  "Detect Secure Input explicitly, skip, and *say why*"; `TargetResolution` already reads
  Secure Input state at resolution time). Reading a password field's selection would be the
  one context incident that kills trust; refusal is asserted by a test, and the indicator
  never lights for a Secure Input field.
- **M6 — The never-in-payload acceptance.** Context never appears in a BYOK cleanup request
  payload without the separate grant. The payload is built in exactly one place
  (`BYOKCleanupProvider.clean`, `VoccaText/LLM/BYOKCleanupProvider.swift:90-129`) — the test
  asserts against it.
- **M7 — The separate BYOK grant.** One global, off-by-default toggle: "allow active-app
  context in cloud cleanup". Surfaced near the BYOK config / egress badge. Context reaches
  the payload only when **both** gates hold — the app is per-app-consented **and** the
  global grant is on (an explicit AND-gate, never either alone). When on, the granted
  context (bundle ID, window title, bounded selected text of the consented focused app) is
  added to the payload; when off, never.
- **M8 — The visible indicator.** A persistent, non-dismissable widget badge while context
  consent is active for the focused app — the `WidgetReducerState.egress` pattern (badge
  state on the reducer, folded at wiring time, glyph in `WidgetView`) — distinct copy from
  the egress ☁ badge, explaining what is being read. It never lights for a Secure Input
  field (M5b).
- **M9 — The one-action kill switch.** A menu-bar row that turns context off globally in one
  action (the mode-row pattern, `MenuBarItem.menu(for:mode:)`), plus the equivalent control
  in Settings. Kill switch ≠ blanket allow: it is a revoke, and it never reads as an
  invitation to grant. **Mid-turn semantics:** throwing it stops all further reads
  immediately and discards the current turn's snapshot (context is never persisted, so the
  discard is total) — asserted by a test; the badge clears in the same fold.
- **M10 — Never persisted beyond the turn.** The consent store holds bundle IDs only — no
  transcript text, no selection text, no wall-clock timestamps reach the file (the
  usage-ledger byte-level pin precedent). `ContextSnapshot` is ephemeral per turn.
- **M11 — Zero-network invariant.** `PROBE-CONTEXT` drives the composed context default work
  (NullContext path) inside the dyld interposer; no URL reaches any new port.

### Should-have

- **S1 — Resolution accuracy harness.** The ≥95% matrix-resolution acceptance: scripted
  corpus over the stub in CI (planted failures fail loudly, like the
  `TurnCommitmentScorer` corpus), plus the env-gated real run and a SMOKE row for the
  founder's machine — recorded, never gated.
- **S2 — Context section in `PRODUCT_SPEC.md`.** The spec has no context surface today (dig:
  zero "context" matches); this unit defines the surface — the badge, the consent UI, the
  kill switch — and the record keeps the doc in sync.

### Nice-to-have

- **N1 — Settings tab section** for consent review (a "which apps can Vocca see" list) beyond
  the Apps-tab rows — only if it falls out of the Apps-tab work without scope creep.

## Technical Considerations

- **Architecture fit:** seam protocol + plain-data vocabulary in `VoccaCore` (imports
  nothing); new `VoccaContext` target is an adapter importing only the core — the
  dependency rule (`ARCHITECTURE.md:84-86`: "each imports `VoccaCore` and no other Vocca
  module"). `VoccaBootstrap` composes, and is the only module that may name the adapter —
  its `AppBootstrap.swift` is G5-pinned (`TurnTakingComposedAcceptanceTests.swift:311-347`),
  so C12's wiring is a **deliberate, reviewed re-anchor** (the C11 contract: four re-anchors
  recorded, never an edit-to-match).
- **Latency budget:** context reads happen at turn start, off the key-release → text-on-screen
  critical path; the read itself inherits `AXSource`'s timed-call discipline (serial queue,
  0.5 s per-call timeout) via the new adapter's own equivalent. No latency-path change.
- **Injection reliability:** untouched. C12 adds AX *reads* only; the injection ladder,
  `TextInjector`, and the dictate pipeline are byte-for-byte pinned. No new write to any app.
- **Privacy/local-first:** the whole capability is the privacy contract — consent default-off,
  content reads gated, indicator persistent, kill switch one action, consent store
  bundle-IDs-only, BYOK payload exclusion with a single explicit global grant. Local-only by
  design; the seam has **no hosted counterpart** (`ARCHITECTURE.md:281`).
- **Converse mode:** untouched. Converse never injects; context reads apply to the focused
  app on the dictate path (and C13 later). No converse-path changes.
- **Phase placement:** P4 (context + actions) — the wedge's context half, built under the
  recorded posture (fourth unit ahead of the uncleared P2/P3 gates; every record says "No
  gate passes"). C13 blocks on this capability.

## Risks & Open Questions

- **R1 — AX silent behavior, inverted (new).** The AX family's documented failure is
  *silent no-op* on writes (roadmap R1); for *reads*, the failure is stale or empty
  selection. Mitigation: the adapter's read is best-effort with timeout, returns an empty
  snapshot rather than throwing on failure, and `NullContext`-style honesty when the app
  isn't consented. The resolution harness measures it; never gated.
- **R2 — The privacy test's read scope.** "Never read" must be pinned to content reads — the
  dictate path legitimately reads bundle ID + window title today. If the lint and the test
  disagree on the boundary, the guarantee becomes theatre. Mitigation: M5's test + lint
  agreement is a first-class requirement; the per-seam AX permit table names exactly which
  files may read which attributes.
- **R2b — Secure Input (the sharpest edge).** Context reading a Secure Input field's
  selection would be the one incident that kills the privacy promise (the injection path
  already short-circuits on Secure Input with an honest message — roadmap R2). Mitigation:
  M5b refuses content reads on Secure Input fields by test, and the indicator never lights
  for one.
- **R2c — The kill switch mid-turn.** A kill thrown mid-session must stop future reads and
  discard the in-flight snapshot, or the badge lies. Mitigation: M9's mid-turn semantics
  are asserted by test (discard is total because nothing persists).
- **R3 — Real-app resolution is env-gated by nature.** The ≥95% number cannot exist in CI —
  real apps need a real machine with an Accessibility grant (the tap-adapter precedent:
  "executed by nothing in CI, now or ever"). Mitigation: scripted corpus in CI proves the
  decisions; the SMOKE row and env-gated run record the real number, never gated. No
  percentage may be quoted until a real run exists.
- **R4 — AppBootstrap G5 pin.** C12's wiring re-anchors the pinned `AppBootstrap` digest.
  Contract: deliberate, reviewed re-anchor per commit, recorded; the dictation files' digests
  stay byte-for-byte.
- **Open Q1 — payload context shape.** What exactly travels when the BYOK grant is on:
  `{bundleID, windowTitle, selectedText}` of the consented focused app, selected text
  truncated at a bound (a budget, like the cleanup budget). Resolved in the `byok-context-grant`
  aspect; default: bounded selected text (e.g. ≤4 KB) + metadata.
- **Open Q2 — indicator copy.** The exact badge copy ("See" / "Reading" / glyph) is decided
  in the widget aspect; the requirement is that it is distinct from the egress badge and says
  plainly that the focused app's content is readable.

## Out of Scope

- **C13 consumption** — the real agent, intent layer, MCP client, action confirmation, audit
  log. C12 ships the provider, consent, indicator, and kill switch; nothing consumes
  context beyond the BYOK grant field and the tests.
- **Converse-mode context** — no conversation-state changes; converse stays byte-for-byte.
- **Per-app BYOK grants** — the grant is one global toggle (interview decision).
- **Context persistence** — no history, no caching across turns; `ContextSnapshot` is
  ephemeral.
- **Context in Ollama (local LLM) payloads** — local egress is not egress; the grant governs
  the BYOK cloud provider only. (The roadmap's language is "when a BYOK cleanup provider is
  active" — scoped accordingly.)
- **Any cross-platform work, cloud in the OSS core, or weakening of the local core** — the
  seam is local-only by design.

## Aspect decomposition

| Aspect | One-line boundary | Key acceptance |
|---|---|---|
| `context-seam` | The `ContextProvider` protocol + `ContextSnapshot` vocabulary in `VoccaCore`, `NullContext`, and the seam-family lint | Contract tests: NullContext resolves empty, reads nothing; lint confines the seam family |
| `accessibility-context` | The new `VoccaContext` target, `AccessibilityContext` adapter with its own AX permit, stub-driven in CI | Resolution over the scripted corpus; planted failures fail loudly; Secure Input refusal (M5b); env-gated real run + SMOKE |
| `consent-store` | Per-app consent persistence (bundle IDs only, atomic, capped) + the never-read gate | Consent off → zero content reads, asserted structurally; store shape pin; no text/timestamps reach the file |
| `widget-indicator` | The persistent context badge + the one-action kill switch (menu bar + Settings) | Badge present iff consent active for focused app; never lights on Secure Input; kill switch revokes globally in one action incl. mid-turn discard (M9); copy distinct from egress |
| `byok-context-grant` | The global off-by-default grant and the grant-gated payload field in `BYOKCleanupProvider` | Never-in-payload without the grant; payload shape + bound with the grant; key never in logs |
| `bootstrap-wiring` | AppBootstrap composition: provider resolution, consent wiring, indicator fold, kill-switch routing, `PROBE-CONTEXT` | Probe drives the composed default (NullContext) under the interposer; G5 re-anchor; floor ratchet |
| `record` | STATUS/CLAUDE/ARCHITECTURE/PRODUCT_SPEC sync, SMOKE rows, the unit record | Docs describe the tree this commit ships in |

---

## Guardrail check (recorded, not assumed)

- **In scope:** macOS-only, local-first, open-core, no cloud — the seam is local-only **by
  design** (`ARCHITECTURE.md:281`). ✓
- **Dictation-first:** the P0 loop is digest-pinned; C12 adds reads only, no injection-path
  change. ✓
- **Latency/injection battles:** untouched — reads are off the critical path; injection is
  byte-for-byte. ✓
- **Zero-network + transcript-never-lost:** PROBE-CONTEXT under the interposer; consent store
  is bundle-IDs-only. ✓
- **Seam doctrine:** two local implementations at ship (`AccessibilityContext`, `NullContext`)
  — met. ✓
- **Gates:** P2/P3 uncleared — fourth unit built ahead under the recorded posture; no gate
  passes. ✓