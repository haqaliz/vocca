# Understanding: intent-layer (C13 slice 6)

> Phase 2 output — written after the agent-team dig over the converse loop (`ConverseWiring.swift`,
> `ConverseLoopDriver.swift`, `VoccaCore/Reply/`), the action machinery (`VoccaCore/Actions/`,
> `VoccaActions/`, `VoccaBootstrap/ActionWiring.swift`, `VoccaUI` card), the lints and probes
> (`ZeroNetworkTests.swift`, `ActionWiringSeamBoundaryTests.swift`, `NetworkInterposer.swift`),
> and the planning docs, at the `action-surface-wiring` tip (`53a8f79`).

## What this work really is

The action layer is machinery-complete **and** surface-complete (gate, executor, config store,
audit store, MCP protocol + stdio transport, confirmation card, Actions tab), and the converse
loop ships with an honest stand-in reply generator (`EchoReplyGenerator` — "the real agent is
C13's", `CAPABILITY_ROADMAP.md:338`). The missing piece is the one that joins them: **nothing
maps a spoken utterance to a tool call, and nothing connects the converse pipeline to the
action machinery.** Today the only gate callers are the Actions tab (mouse) and the probe;
`ConverseLoopDriver.runUtterancePipeline` ends at `replyGenerator → scheduleReply`
(`ConverseLoopDriver.swift:326-331`). Until the intent layer exists, the P4 gate's "≥3 distinct
MCP tool integrations working end-to-end **from voice**" (`ROADMAP.md:251`) is structurally
unreachable — the wedge ("voice that *does things*") has no voice.

This slice is also the one the §8 escape-valve conversation was reserved for — the
"next slice's conversation" named in three places (`action-safety-spine/prd.md:343-344`,
`action-surface-wiring/prd.md:223-224`, `CAPABILITY_ROADMAP.md:453-455`): *when the user says
yes once, what exactly did they say yes to?*

## What must ship (per the card, `docs/planning/_card/issue.md`)

1. **A new intent seam** — the first utterance-meaning component in the repo. The `ReplyGenerator`
   precedent (`ReplyGenerator.swift:40-43`: "C13's real agent replaces the deterministic stand-in
   behind this seam") plus `ActionProvider.swift:70` ("an empty `toolIDs` … means there is nothing
   for an intent layer to resolve an utterance against") both point to `VoccaCore`: a resolver over
   the cleaned transcript whose output is a Core-vocabulary resolution (tool call / ask / none),
   with a **local, deterministic implementation first** and a second implementation for guardrail
   7 — no LLM in the OSS core, the empty import allow-list (`CoreBoundaryTests.swift:116`) holds.
2. **Converse-pipeline integration** — an async intent step between `clean` and the reply
   (`ConverseLoopDriver.swift:326`), in the exact shape of the lazy `asrProvider`/`cleanupProvider`
   closures. `ReplyGenerator` is synchronous by frozen doctrine and its async leg is explicitly "a
   C13 signature reconsideration, recorded here rather than added now" (`ReplyGenerator.swift:29-31`)
   — so the async leg lands as a new closure on the driver, and the compile pin
   (`ConverseLoopDriverTests.swift:362-374`) makes that a reviewed edit by design.
3. **The "not confident" ask path** — an ambiguous utterance resolves to a spoken question, zero
   provider side effects (the ask must not touch `invoke`), and the natural follow-up loop is the
   utterance pipeline itself: the user's clarifying next turn re-resolves. "A guess never executes"
   (card acceptance 3) is the gate's structural refusal made reachable from voice.
4. **Voice-issued actions through the existing round trip** — `executor.submit(…, .withheld)`
   → `.confirmationRequired` → the existing widget card (`WidgetConfirmationSignal`, generation
   tokens, stale-card guard, re-render-after-record, `approvedSentence` binding — all reusable
   verbatim; `ActionWiring.swift:264-368` is the reference path) → confirm/decline closures →
   every decision recorded. The audit store is untouched; the composed default still resolves
   nothing and spawns nothing.
5. **The §8 decision, made and pinned** — the three shapes (`action-safety-spine/prd.md:341-342`):
   time-boxed scoping, a blast-radius floor that can never be silenced (outward-facing always
   confirms), per-tool trust that decays. The never-silenceable floor is the shape that ships
   **as a pinned invariant** (card acceptance 4); the others are decided-and-deferred with the
   reason recorded. M4a binds this slice too: no trust mechanism can enter the gate this slice.
6. **Probe + SMOKE** — a `PROBE-INTENT` leg inside the zero-network interposer (the
   `PROBE-ACTIONS` quartet shape: expected-lifecycle constant, verbatim assertion, payload
   accessor, guard-the-guard), SMOKE 148+ rows recorded never gated, floor ratchet in the same
   commit.

## Binding decisions inherited (not negotiable in the PRD)

- **M4a** — confirmation is strictly per-invocation; "don't ask again" has no representation in
  the type and the reducer must not add one (`action-safety-spine/prd.md:332-336`).
- **M7 never-read** — enablement is checked *before* any provider call; a disabled tool is never
  described (`ActionGate.submit` check order ①, `ActionGate.swift:378-414`).
- **N2 sentence binding** — a granted approval binds to the sentence the card showed;
  `approvedSentence` is forwarded verbatim, never defaulted (`ActionExecutor.swift:120-141`).
- **Escalate-only blast radius** — local policy may only raise the provider's claim, never lower
  it (`ActionRadiusPolicy.escalated`, `ActionGate.swift:152`).
- **Policy floor `.none`, recorded as a decision** — a stricter floor breaks M3's
  read-only-runs-directly contract (`ActionWiring.swift:203`); the §8 never-silenceable floor is
  a different axis (what *future* trust cannot silence), not today's floor.
- **Raw arguments never persist** — the sentence a human was shown is the only thing that reaches
  disk (4 KB invocation bound, 1 KB summary bound).
- **D2** — the default configuration cannot create a child; `discovery.unwired` answers
  discovery; stdio is the only permitted transport; `spawnsSubprocess` is a declared value.
- **Converse never injects** — no `TextInjector` name in a converse-path file
  (`ConverseWiringSeamBoundaryTests.swift:214-254`).
- **Module law** — `VoccaCore` imports nothing; `VoccaActions` depends on exactly `VoccaCore`;
  `VoccaUI` on exactly `VoccaCore`; one `Process`-naming file; only `VoccaNetworkProbe` imports
  `VoccaBootstrap`.
- **G5** — `AppBootstrap.swift` digest re-anchored deliberately in the same commit as wiring;
  dictation digests (`SessionMachine.swift`, `DictationPipeline.swift`) unchanged.
- **Async, never `async throws`** — failure stays a returned value; a dropped `catch` cannot
  drop an audit record.
- **Floor ratchet** — the floor rises in the same commit as the tests
  (`Scripts/test-with-floor.sh:1915`, currently 2710).

## Open questions the PRD must decide (not addressed in files)

1. **Seam placement and vocabulary.** New `VoccaCore/Intent/` (pure text matching, Foundation-free,
   resolution as Core vocabulary) with the wiring holding the catalog — or a `VoccaActions` home?
   What is the exact resolution vocabulary: `.toolCall(ActionInvocation)` / `.ask(String)` /
   `.none`, and does the resolver build the arguments text (validated later by
   `MCPProvider.parsedArguments`, the `ActionInvocation` "admits it cannot validate its own
   contents" precedent, `ActionInvocation.swift:44-61`)?
2. **The deterministic classifier's shape.** Keyword/rule matching over what — tool names, the
   provider's own `describe` sentences, a seeded synonym table? Two implementations for guardrail
   7: the matcher + what second (a `NullIntentResolver` shipped default is the honest analogue of
   `NullActionProvider`)? Where does the "not confident" threshold live and how is it seeded?
3. **The ask path's surface.** A spoken question only (reply text via the generator; reply-text
   *rendering* stays deferred — `PRODUCT_SPEC.md:421`) — or does the ask path also present the
   widget card? What happens on the clarifying turn when it *still* doesn't resolve (bounded
   re-ask, then `.none` → echo)? Can a voice-issued action's card appear mid-converse-session
   (the in-flight refusal is the dictation-session guard; converse is the session the card comes
   from — does `sessionActive()` still apply)?
4. **Which provider does the voice path compose over.** The shipped `ActionExecutor` is generic
   per-provider and the composed one is `AuditActionProvider` (the Actions tab's). Voice over the
   same executor (audit.count/audit.clear are the first voice-drivable real tools) with the
   probe/stub MCP (`InMemoryMCPTransport`, probe-proven) as the test bed — or does this slice
   wire an MCP discovery path for voice (D2: discovery spawns, unwired by default)?
5. **The §8 decision's exact scope.** Never-silenceable floor ships as: (a) the decision
   recorded, (b) a gate-level invariant test ("an outward-facing invocation always confirms —
   no approval/policy/mode shape auto-runs it", the `BlastRadius.requiresConfirmation` single
   branch point pinned by name), and (c) the deferred shapes (time-boxed trust, decaying per-tool
   trust) recorded with their blockers (persisted trust state, changed approval semantics, M4a)?
   Is (b) strong enough to satisfy card acceptance 4, or does the slice need a minimal
   `ActionRadiusPolicy.Floor` composition for voice (e.g. outward-facing floors, escalate-only)?
6. **The driver change's size.** The intent closure on `ConverseLoopDriver` (widening a pinned
   signature) vs a separate coordinator the wiring composes (the driver untouched)? The reply
   path when an action executes: acknowledgment text ("Done", the outcome sentence) — who renders
   it, and does `ConverseTurnFailure` gain the intent leg's failure case?
7. **SMOKE rows 148+.** First voice-issued action on the real surface: "clear the audit log" →
   card → confirm → audit row reconstructs; plus the ask-path row. Recorded never gated; what
   does each row's precondition (rule 1: verify the state was entered) require?

## Risk the slice mitigates (not retires)

**R8's voice leg** (`ROADMAP.md:307`): the first path by which a spoken sentence can cause an
action. The mitigation is the existing round trip made reachable from voice — the gate's
structural refusal, the sentence binding, the recorded decision — plus the new "a guess never
executes" property (the ask path precedes any provider call). The P4 gate's "zero unintended
actions" (`ROADMAP.md:250`) gains a voice-shaped enforcement point; it is still not retired —
the card's N2 limit (an approval asserts a human said yes, it cannot verify it) is stated in
the unit record.

## Layer / phase placement

Actions (P4), continuing C13 — slice 6. Local-only; zero network and zero spawn in the default
configuration (the probe asserts it); no cloud anywhere. Touches `VoccaCore` (intent seam),
`VoccaActions` (nothing new required — executor/config/audit reused), `VoccaBootstrap`
(`IntentWiring` + driver integration), `VoccaUI` (card reuse only), the probe, and
`Tests/HarnessTests`. The dictation path is byte-for-byte untouched (pinned).