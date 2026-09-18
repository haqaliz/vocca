# Understanding — C12 context provider (active app and selection)

Synthesis of the Phase 1 brief + the agent dig (2026-09-18). Source of truth:
`CAPABILITY_ROADMAP.md:345-359` (C12), `ARCHITECTURE.md:151,281` (the module reservation
and the seam table), `ROADMAP.md:225-227,352-354` (P4 context deliverables), the C11 unit
records, and the code map.

## What the work really is

C12 gives Vocca the **context-awareness half of the wedge** ("context-awareness (active app +
selection)" — CLAUDE.md): a `ContextProvider` seam yielding active bundle ID, window title,
and current selected text via AX — gated by per-app opt-in (default off), a visible
indicator, a one-action global kill switch, never persisted, never in a BYOK payload without
a separate explicit grant. C13 (Actions and MCP) blocks on this capability
(`CAPABILITY_ROADMAP.md:379`); the P3 gate's conversational leg stays formally unmet until
C13 (`docs/STATUS.md:97-99`).

Concretely, from the records:

1. **The seam and its implementations are already reserved.** `ARCHITECTURE.md:281` names
   `ContextProvider` → `AccessibilityContext`, `NullContext`, hosted tier **No — by design**.
   The two-implementation seam doctrine (`CAPABILITY_ROADMAP.md:414`) is therefore **met**:
   `NullContext` is the honest shipped default (nothing read), `AccessibilityContext` the
   real AX adapter. The card caveat "record the exemption instead" (issue.md:46-49) is
   superseded — amend it: no exemption is needed, the architecture doc already resolves it.
2. **The seam protocol lives in `VoccaCore`** (the §2 rule — `ARCHITECTURE.md:82-84`: "It owns
   the seams"). The module reservation `VoccaContext/` (`ARCHITECTURE.md:151`) does **not
   exist in `Package.swift` today** — ten targets, no VoccaContext. Creating the target is
   part of this unit (test-first, like C1's scaffolding).
3. **AX names are lint-confined.** The `kAX*`/`AXUIElement` family is permitted in exactly
   one file: `Sources/VoccaInject/Accessibility/AXSource.swift`
   (`Tests/HarnessTests/InjectionSeamBoundaryTests.swift:529-531`). Adapters "import
   `VoccaCore` and no other Vocca module" (`ARCHITECTURE.md:84-86`) — so `VoccaContext`
   cannot import `VoccaInject`; the selected-text read needs **its own permitted AX file**
   in the new module (a reviewed per-seam lint amendment, the `KeystrokeSource` precedent —
   `ARCHITECTURE.md:169-180`).
4. **The never-read precedent exists.** `AccessibilityRungStrategy.tryInject` declines an
   unallowlisted bundle ID **before a single AX call** (`AccessibilityRungStrategy.swift:99-104`)
   — "not read-then-discard, but never read". C12's per-app opt-in gate mirrors it.
5. **Bundle ID + window title are already read by the dictate path** (for the failsafe copy
   and matrix evidence): `AXSource.focusedApp()` (`:85-94`), `TargetContext` (bundleID +
   windowTitle, `VoccaCore/TargetContext.swift:35-42`), `CleanupContext.target` already
   carries them into every cleanup call (`CleanupContext.swift:37`). So C12's privacy test
   must be scoped to **content reads** (selected text), not the metadata the injection path
   legitimately reads. "Never persisted" and "never in the BYOK payload" then attach to
   selected text.
6. **The BYOK payload is built in exactly one place**: `BYOKCleanupProvider.clean`
   (`VoccaText/LLM/BYOKCleanupProvider.swift:90-129`) — user message is `transcript.text`,
   no context field today. The separate-explicit-grant test has a single seam to assert
   against.
7. **Per-app persisted stores have a proven shape**: `strategies.json`
   (`PersistentInjectionStrategyStore` — versioned `{"version":1,...}`, atomic
   temp-write + `replaceItemAt`, tolerant decode, 512-app cap). C12's consent store mirrors
   it. The Apps tab already renders per-app rows with overrides
   (`VoccaUI/Apps/AppsTabState.swift`) — the natural consent home.
8. **Indicator + kill switch have ready homes.** The `WidgetReducerState.egress` badge is the
   precedent for a launch/session-derived, non-dismissable widget marker
   (`WidgetStateReducer.swift:75-80`, `WidgetView.egressMarker`); the menu-bar mode rows are
   the precedent for a one-action kill switch (`MenuBarItem.menu(for:mode:)`, `MenuBarCopy`).
   `PRODUCT_SPEC.md` has **no context section today** (grep finds no "context" in it) — the
   indicator's exact behavior is a design decision for the interview, defaulting to the
   egress-badge pattern.
9. **Test infrastructure:** floor `MINIMUM_EXECUTED_TESTS=2350`
   (`Scripts/test-with-floor.sh:1770`), ratcheted in the same commit as every test-adding
   task; the G5 pin (`TurnTakingComposedAcceptanceTests.swift:311-347`) pins
   `SessionMachine.swift`, `DictationPipeline.swift`, **and `AppBootstrap.swift`
   (`6d98acf4…`)** — C12's wiring lands in AppBootstrap, so the pin gets a **deliberate,
   reviewed re-anchor** (the C11 contract: never an edit-to-match); the zero-network
   interposer with `PROBE-*` drives every composed default — C12 needs its own probe leg or
   coverage via an existing one.
10. **The ≥95% matrix-resolution acceptance** is real-app work: the 20-app matrix lives in
    `Scripts/injection-matrix.sh` `ROWS` (22 rows). Per the recorded pattern
    (turn-commitment), CI runs a **scripted corpus over a stub AX adapter**; real resolution
    is env-gated + SMOKE rows — recorded, never gated.

## Affected areas (file map)

| Area | Today | C12 change |
|---|---|---|
| `Package.swift` | ten targets, no VoccaContext | new `VoccaContext` target (test-first) |
| `VoccaCore` | no ContextProvider | seam protocol + plain-data vocabulary (`ContextSnapshot`, consent types) |
| `VoccaContext/` (new) | — | `AccessibilityContext` (its own permitted AX file — lint amendment), `NullContext`, consent store |
| `VoccaInject/Accessibility/AXSource.swift` | one permitted AX file | unchanged (or one added read primitive if the design routes through it — decision) |
| `VoccaText/LLM/BYOKCleanupProvider.swift` | payload = transcript only | context field gated by the separate explicit grant |
| `VoccaUI` | egress badge; Apps tab; menu bar rows | context indicator, consent rows, kill-switch row |
| `AppBootstrap.configure` | G5-pinned | context wiring — **deliberate re-anchor, recorded** |
| `ZeroNetworkTests` | PROBE-* legs | PROBE-CONTEXT or covered leg |
| `Scripts/test-with-floor.sh` | floor 2350 | ratchet per test-adding commit |

## Ambiguities / open questions (for the interview)

- **Q1 — Module placement.** New `VoccaContext` target (the architecture reservation) owning
  the AX adapter + its own lint permit, with the seam protocol in `VoccaCore`? Or the AX
  adapter inside `VoccaInject` (which would then implement the seam)? The dependency rule
  (adapters import only the core) makes the new module the natural reading of
  `ARCHITECTURE.md:151` — confirm.
- **Q2 — Consent store shape.** New `context-consent.json` mirroring `strategies.json`
  (versioned, atomic, capped), vs. an extension of an existing store? And is the Apps tab the
  consent UI home?
- **Q3 — The privacy test's read scope.** "No AX read of that app's content occurs at all"
  must be scoped to **content** (selected text) — bundle ID + window title are already read
  by the dictate path. Pin the exact wording in the acceptance so the lint + test agree.
- **Q4 — The visible indicator's semantics.** Persistent badge while consent is active for
  the focused app (egress-badge pattern), vs. transient "reading now" states? Recommend
  persistent — transient is unobservable and un-auditable.
- **Q5 — Kill switch placement.** Menu-bar row (one action) + a Settings surface? Global
  kill switch vs per-app consent both required; kill switch is off-everything, consent is
  per-app.
- **Q6 — The BYOK separate grant's shape.** One global "allow context in cleanup payloads"
  toggle (off by default, surfaced near BYOK config / egress badge), or per-app too?
- **Q7 — What consumes context in C12.** Nothing user-visible yet (C13 consumes; C12 is
  provider + consent + indicator + kill switch, the C10 "machinery, not surface" posture
  with the roadmap's surface parts), or does the dictate path's cleanup gain a context field
  (only under the separate grant)? CleanupContext already carries target metadata — selected
  text must NOT flow without the grant.
- **Q8 — The matrix-resolution acceptance's shape.** Scripted corpus over a stub in CI +
  env-gated real run + SMOKE row (the turn-commitment pattern), recorded never gated?
- **Q9 — AppBootstrap pin.** C12's wiring re-anchors the G5 `AppBootstrap` digest —
  confirm the deliberate re-anchor contract (it is the C11 precedent).

## Contradictions surfaced (flag, don't paper over)

1. **The card's seam-doctrine caveat is stale.** issue.md says "record the exemption — do not
   invent a second provider"; `ARCHITECTURE.md:281` already names `NullContext` as the
   shipped second implementation. No exemption is needed; the understanding corrects the
   card.
2. **PRODUCT_SPEC.md has no context surface at all** while ROADMAP P4 mandates the indicator
   + kill switch. The unit defines the surface; PRODUCT_SPEC gains the section (or the
   record notes the gap).
3. **"Default off for every app" vs the global kill switch** are different axes (grant vs
   revoke) — both required; no blanket-allow; the kill switch must never read as an
   invitation to grant.
4. **AX content reads for context vs the injection path's metadata reads** share the AX
   family — the lint table must keep them distinct so the never-read test can't be
   laundered through the dictate path.

## Guardrail check

- **In scope**: macOS-only, local-first, no cloud, no egress surface (the seam has no hosted
  counterpart **by design**). ✓
- **Dictation-first**: the P0 loop stays digest-pinned; C12 adds AX *reads* only, never an
  injection-path change. ✓
- **Latency/injection battles**: untouched — context reads are off the latency path
  (session-start metadata), and no new write to any app. ✓
- **Zero-network + transcript-never-lost**: consent store is local shape-only (bundle IDs),
  no transcript text; nothing new reaches a URL — the BYOK payload exclusion is the point.
  ✓
- **Seam doctrine**: two implementations at ship (`AccessibilityContext`, `NullContext`),
  both local — met, not exempted. ✓
- **Gates**: P2/P3 uncleared — fourth unit built ahead under the recorded posture.

## Phase placement

P4 (context + actions), the wedge's context half; it unblocks C13. Not a dictation-core
change; the seam is local-only by design.