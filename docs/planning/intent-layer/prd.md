# PRD: intent-layer — C13 slice 6

> **Phase:** P4 (Actions/MCP) · **Slug:** `intent-layer` · **Branch:**
> `feat/intent-layer/aliz`
>
> Source: `docs/planning/_card/issue.md` (inline brief, 2026-09-22) + the deep-dig
> understanding note at `docs/planning/_card/understanding.md`. Inherited decisions cited
> from the five prior C13 slice records; decisions made in this unit are marked **[decided
> here]**.

## Problem Statement

Five C13 slices shipped the action layer's machinery and its human-in-the-loop surface: the
safety spine, the audit store and first real provider, the MCP protocol layer, the stdio
transport, and — last — the Actions surface (enablement store, confirmation card, Actions
tab, composed wiring). The converse loop ships with an honest stand-in reply generator
(`EchoReplyGenerator` — "the real agent is C13's", `CAPABILITY_ROADMAP.md:338`). What does
not exist anywhere is the piece that joins them: **nothing maps a spoken utterance to a tool
call, and nothing connects the converse pipeline to the action machinery.** The only gate
callers in a shipped configuration are the Actions tab (mouse) and the probe; the utterance
pipeline ends at `replyGenerator → scheduleReply` (`ConverseLoopDriver.swift:326-331`). The
P4 gate's "≥3 distinct MCP tool integrations working end-to-end **from voice**"
(`docs/ROADMAP.md:251`) is structurally unreachable, and the wedge ("voice that *does
things*") has no voice.

This slice is also the one the §8 escape-valve conversation was reserved for — "the *next*
slice's conversation" named in three places (`action-safety-spine/prd.md:343-344`,
`action-surface-wiring/prd.md:223-224`, `CAPABILITY_ROADMAP.md:453-455`): *when the user
says yes once, what exactly did they say yes to?*

## Goals & Success Metrics

| Goal | Metric |
|------|--------|
| A spoken utterance can resolve to a tool call with correctly built arguments | Card acceptance 1: a matched utterance yields an `ActionInvocation` with correct arguments on the stub server |
| An ambiguous utterance asks rather than guesses | Card acceptance 2: the ask path renders with **zero provider side effects** — `invoke` called zero times, asserted on the provider's call log |
| A guess never executes; every voice-issued action is recorded | Card acceptance 3: the executor round trip (gate → audit) is the only voice path; every decision lands in the audit store |
| The §8 decision is made, not deferred | Card acceptance 4: the never-silenceable blast-radius floor is pinned by a test — an outward-facing tool always confirms, no approval/policy/mode shape auto-runs it |
| The composed default still resolves nothing and spawns nothing | Card acceptance 5: PROBE-INTENT drives the composed intent wiring inside the zero-network interposer; the default-configuration run reports `intentResolved=0` and `spawnsSubprocess=false` |
| Test floor | Every new acceptance is a test written before its code; floor rises from 2710 in the same commit as the tests |

Success is **not** gated: no gate passes; this is the tenth unit built ahead of the
uncleared gates under the recorded posture.

## User Personas & Scenarios

- **The founder (today's only user).** Wants to say "clear the audit log" into the
  CONVERSING surface, see the confirmation card, click Confirm, and reconstruct the row
  from the audit log — the same round trip the Actions tab offers, driven by voice. Also
  wants the honest behavior when an utterance is ambiguous: Vocca asks ("Did you mean X or
  Y?"), and no tool is touched.
- **A future MCP-server user.** Already configured a server and enabled its tools
  individually in the Actions tab; wants to drive those **enabled** tools by voice, with the
  same confirmation policy as the tab — never a blanket grant, never a tool the user hasn't
  enabled (M7).
- **The reviewer/contributor adding the next provider.** The intent seam must not
  special-case `MCPProvider` or `AuditActionProvider`; it resolves against the enablement
  catalog and drives `ActionExecutor` + `ActionGate` and nothing else.

## Requirements

### Must-have

**R1 — The intent seam, in `VoccaCore`.** [decided here: `VoccaCore/Intent/`, Core
vocabulary] A `IntentResolver` protocol (the `ReplyGenerator` precedent,
`ReplyGenerator.swift:40-43`) whose input is the cleaned transcript `String` and whose
output is a Core-vocabulary resolution:

- `.toolCall(ActionInvocation)` — a matched utterance with arguments text (the 4 KB bound;
  Core "admits it cannot validate its own contents", `ActionInvocation.swift:44-61` —
  `MCPProvider.parsedArguments` validates later);
- `.ask(question: String)` — below the not-confident threshold, the ask path: a spoken
  question, nothing executed;
- `.none` — no tool resolved; the pipeline falls through to the existing reply generator.

**R2 — The deterministic classifier, first implementation.** [decided here: keyword
matching, seeded] `KeywordIntentResolver`: token-scored matching over the tool catalog
(provider/tool ids plus a seeded synonym table — "clear the audit log" → `audit.clear`),
stop-word handling, and a **not-confident threshold** below which resolution is `.ask`.
Foundation-free (the empty import allow-list, `CoreBoundaryTests.swift:116`). The threshold
is seeded and documented; its real behavior is env-gated, never CI-measurable (the ASR-WER
precedent, `CAPABILITY_ROADMAP.md:104-106`).

**R3 — The catalog is the enablement, never-read at the intent level.** [decided here] The
wiring supplies the resolver only **enabled** tools (`ActionConfigStore.loadEnablement()`,
absent is off). A disabled tool is never resolved to, never described, never called — M7
extends to the intent step (`ActionGate` check order ①, `ActionGate.swift:378-414`).

**R4 — The converse pipeline gains the intent step.** [decided here: async closure on the
driver, the `asrProvider`/`cleanupProvider` shape] `ReplyGenerator` is synchronous by frozen
doctrine and its async leg is explicitly "a C13 signature reconsideration, recorded here
rather than added now" (`ReplyGenerator.swift:29-31`) — so the async leg lands as a new lazy
closure on `ConverseLoopDriver` (`intentProvider`, and for `.toolCall` a handler closure),
wired between `clean` and the reply (`ConverseLoopDriver.swift:326`). The frozen-signature
compile pin (`ConverseLoopDriverTests.swift:362-374`) makes the widening a reviewed edit by
design. Pipeline: `.ask(question)` → the question is the spoken reply (the CONVERSING
surface's next turn re-resolves — the ask loop is the utterance pipeline itself, bounded:
still `.ask` after the re-resolution → fall through to `.none`/echo). `.none`/nil → the
existing reply generator untouched.

**The ask's candidates are the resolver's own ranking.** [decided here] The question names
the top-N candidates from the matcher's scored candidates, bounded to 2-3, in deterministic
(score, then lexical) order — the ask never invents a tool the matcher did not rank.

**R5 — Voice-issued actions through the existing round trip.** [decided here: the shared
executor, card reuse] The wiring's action leg submits through the **same** composed
`ActionExecutor` instance (`root.actionExecutor`, `AppBootstrap.swift:676`) with
`approval: .withheld` → on `.confirmationRequired`, re-render after the record (the
count-bearing sentence precedent, `ActionWiring.swift:291`) and present the card via
`widgetStore.presentActionConfirmation` with a fresh generation token — then the existing
`root.actionConfirm` / `root.actionDecline` closures (`ActionWiring.swift:315-368`) complete
the human leg: generation guard, `.granted` with `approvedSentence` verbatim, mismatch
re-prompt, every decision recorded. Two failure holes are closed by contract: while a card is
up (the store's confirmation is non-nil — one card at a time,
`WidgetStateStore.swift:94-107`), a second voice action **refuses to present** (the
replacement-card hazard is the same class as the in-flight dictation guard); and a terminal
decision with `auditRecorded == false` (store write failure, `ActionExecutor.swift:30-39`)
yields a bounded failure reply ("Something went wrong — the action was not recorded."),
never a success ack. The spoken reply after a terminal decision: a bounded acknowledgment
derived from the decision (confirmed → "Done." / the outcome sentence; declined →
"Cancelled."; refused/notInvoked → silent or a bounded notice — exact copy in the record
aspect).

**R6 — The §8 decision, made and pinned.** [decided here: floor pinned, others deferred] The
three shapes (`action-safety-spine/prd.md:341-342`) are decided in this unit:

- **Never-silenceable blast-radius floor — ships as a pinned invariant.** An outward-facing
  tool always confirms: no approval value, policy floor, mode, or future trust mechanism can
  auto-run it. Pinned by a gate-level test (the `BlastRadius.requiresConfirmation` single
  branch point, `BlastRadius.swift:56-63`, named as the §8 floor) plus the wiring's
  recorded decision in `ARCHITECTURE.md`'s policy row. Distinct from today's `.none` floor
  (`ActionWiring.swift:203`, which stays — a stricter *current* floor would break M3): the §8
  floor is about what *future* trust cannot silence.
- **Time-boxed scoping ("this tool, next 10 minutes") — decided and deferred.** Blocker:
  a persisted trust state plus changed approval semantics, which M4a binds ("don't ask again
  has no representation in the type", `action-safety-spine/prd.md:281`). The deferral is
  recorded with its blocker in the unit record and `CAPABILITY_ROADMAP.md`.
- **Per-tool trust that decays — decided and deferred.** Same blocker; recorded.

**R7 — Composition-root wiring, additive.** [decided here] The C11/C12/C13 recipe: an
`IntentWiring.swift` in `VoccaBootstrap` composing the resolver over the enablement catalog
and the shared executor; nullable root slots on `DictationLoopRoot`; composition in
`AppBootstrap.configure`. **The composed default resolves nothing** [decided here]: the
default configuration wires `NullIntentResolver` (the D2-analogue posture — a shipped
configuration cannot voice-act until a future slice wires it deliberately), the echo reply
is unchanged, and the composed default's facts report `intentResolved=0`. The full round
trip is exercised by the probe over probe doubles (the `PROBE-ACTION-SURFACE` shape).
**G5 re-anchor of `AppBootstrap.swift` only**; the dictation digests
(`SessionMachine.swift`, `DictationPipeline.swift`) unchanged
(`TurnTakingComposedAcceptanceTests.swift:311-347`).

**R8 — The second intent implementation.** [decided here: `NullIntentResolver` is the
shipped default; the seeds are code-level this slice] Guardrail 7 requires two
implementations for the seam. `NullIntentResolver` resolves `.none` for every utterance (the
`NullActionProvider` precedent) and is the composed default. **The D3-shaped caveat is
recorded, not papered over**: a shipped default was slice 1's D3 lesson ("a shipped default,
not a second implementation", `CAPABILITY_ROADMAP.md:414-415`) — the seam's record states
whether the two implementations are two *real* ones (keyword + phrase, see S1) or a real one
plus the null default, and the honest claim is whichever is true. **The seeded synonym table
is code-level this slice** (a Core constant table, test-pinned, Foundation-free); the
user-editable tuning path is S1's phrase table (the C5 user-dictionary precedent,
`CAPABILITY_ROADMAP.md:141`) — day-one retuning of a wrong seed is a reviewed code edit
until S1 lands, and the record says so.

**R9 — Probe + guard-the-guard.** A `PROBE-INTENT` leg inside the zero-network interposer
(the `PROBE-ACTIONS` quartet: expected-lifecycle constant, verbatim assertion, payload
accessor, guard-the-guard — `ZeroNetworkTests.swift:474-499, 1830-1899`). The drive composes
the intent wiring over probe doubles: a stub MCP provider over `InMemoryMCPTransport`
(probe-proven) or the audit provider over real temp-directory stores — utterance → resolve →
gate → confirmationRequired → card → confirm → audit row reconstructs. The default-
configuration run asserts `intentResolved=0` and `spawnsSubprocess=false`. Expected-
lifecycle constants are effect-not-reference (a constant that could be weakened without the
guard noticing is called out per-field).

**R10 — Family lints.** The `ActionWiringSeamBoundaryTests` shape: the intent families
confined to their permitted files (Core seam files, `IntentWiring.swift`, `AppBootstrap.swift`,
the probe drive), planted-violation and comment-strip controls, non-vacuous guards, and the
converse-path `TextInjector` prohibition leg (`ConverseWiringSeamBoundaryTests.swift:214-254`).

**R11 — First voice-action SMOKE rows.** Steps 148+ in `docs/SMOKE_CHECKLIST.md`, recorded
never gated: (148) enable `audit.clear` in the Actions tab, converse "clear the audit log",
the card shows the gate's sentence verbatim; (149) confirm → the audit row reconstructs
through the real surface; (150) an ambiguous utterance is answered with a spoken question
and no tool is touched.

### Should-have

**S1 — `PhraseIntentResolver`.** Exact-phrase table → invocation (the C5 user-dictionary
precedent, `CAPABILITY_ROADMAP.md:141`): custom phrases the user can seed, stored as
user-editable JSON (the C5 dictionary shape). This is the second *real* implementation that
would retire the R8 caveat outright and the day-one tuning path for wrong seeds.

**S2 — The ask path's copy.** A bounded, deterministic question template ("Did you mean
'tool A' or 'tool B'?") with a fallback ("I didn't catch that — try again?") — exact copy
reviewed in the record aspect.

### Nice-to-have

**N1 — Voice-triggered `audit.clear` in the shipped default composition** (the composed
default resolves the audit provider's own tools once a founder real run asks for it; the
R7 decision says unwired-by-default, recorded so the flip is a reviewed edit).

## Technical Considerations

- **Layer:** Actions (P4), continuing C13. Touches `VoccaCore` (`Intent/`), `VoccaBootstrap`
  (`IntentWiring.swift`, `ConverseLoopDriver` widening, `AppBootstrap.configure`),
  `VoccaUI` (card reuse only — no new UI), the probe, and `Tests/HarnessTests`. Does **not**
  touch capture/ASR/cleanup/injection/TTS; the dictation path stays byte-for-byte pinned.
- **Phase/sequencing:** P4. Prerequisites (C10/C11/C12 and C13 slices 1-5) shipped. No gate
  passes; the recorded posture is building ahead of the uncleared gates.
- **Module boundaries (the load-bearing constraints):**
  - `VoccaCore` imports nothing — the seam, the vocabulary, and both resolvers are
    stdlib-only (empty import allow-list, `CoreBoundaryTests.swift:116`). `ActionInvocation`
    is already Core vocabulary, which is why the seam lives here rather than in a new
    module (no manifest edit, no module-coverage change).
  - `VoccaBootstrap` composes: `IntentWiring` imports what it composes (`VoccaActions` is
    already in its dependency list, `Package.swift:189`); the `TextInjector` prohibition
    leg applies.
  - `VoccaUI` depends on exactly `["VoccaCore"]` — the card is reused as-is; no new UI
    state.
  - `Process` may be named in exactly one file (unchanged); the intent path spawns nothing
    and the default configuration cannot create a child (D2).
- **Latency:** not on the dictation latency path. The intent step adds deterministic
  matching cost (<ms, off the per-frame path — the same guarantee the reply seam carries,
  `ReplyGenerator.swift:26-28`); the executor leg is post-utterance and never blocks capture
  (the driver's child-task discipline, `ConverseLoopDriver.swift:254-278`).
- **Privacy/local-first:** raw arguments never persist; the approved sentence is what
  reaches disk. Resolution happens on-device; the classifier is deterministic and local; no
  LLM in the OSS core (the BYOK seam would be a *later* intent implementation, and only ever
  added to the seam). Zero network and zero spawn in the default configuration (R7/R9).
- **The G5 pin:** `AppBootstrap.swift` changes exactly as often as wiring commits touch it;
  recompute `shasum -a 256` in the same commit, never edit-to-match
  (`TurnTakingComposedAcceptanceTests.swift:340-345`).
- **Test floor:** every acceptance is a failing test first; the floor ratchet rises in the
  same commit as the tests (`Scripts/test-with-floor.sh:1915`, currently 2710).

## Risks & Open Questions

| Risk / question | Notes |
|-----------------|-------|
| **The first real run's threshold/synonyms will be wrong** | The seeds are the founder's invention until SMOKE 148-150 runs. The tuning path is recorded: code-level this slice (R8), user-editable via S1's phrase table. The PRD does not claim a resolution rate; SMOKE 150 records utterance counts (resolved / asked / missed), never a percentage. |
| **R8 — destructive actions the user didn't intend** (mitigated, not retired) | This slice adds the voice leg to the mitigation: the card, the sentence binding, the recorded decision, and — new — the ask path ("a guess never executes"). The N2 limit (an approval asserts a human said yes, it cannot verify it) is stated in the unit record. The classifier's *wrong-but-confident* failure is bounded by the gate, not by the classifier. |
| **The classifier's accuracy is unmeasurable in CI** | The not-confident threshold is seeded; real resolution accuracy is env-gated (the ASR-WER precedent). No accuracy percentage exists until a founder real run (SMOKE 150 records the ask path's existence, never a rate). The PRD sets the threshold; it does not claim a number. |
| **Guardrail 7 shape for the new seam** | The seam ships with keyword + null default (R2/R8); whether that is two *real* implementations is the recorded D3-shaped caveat. S1 (`PhraseIntentResolver`) is the should-have that retires it. The unit record states the honest claim. |
| **The driver's widening is a reviewed edit** | The frozen-signature compile pin (`ConverseLoopDriverTests.swift:362-374`) fails on the change — that is the intended mechanism; the widening commit updates the pin deliberately with the new closure parameters, and `ConverseTurnFailure` stays untouched unless the action leg needs a new failure case (decided in the converse-step aspect: failures are returned values, the driver's silent-return discipline, `ConverseLoopDriver.swift:294-306`). |
| **The card from within a converse session** | The in-flight arm refusal guards the dictation session (`sessionActive()`, `ActionWiring.swift:269-273`); the mode machine allows one active capture, so a converse-session card cannot collide with a dictation session. The wiring applies the same read-lazily guard for the voice leg; the PRD decides the card may appear mid-converse (the user is already in the conversation) but never mid-dictation. |
| **The ask loop's bound** | A re-resolution that still can't decide must terminate: `.ask` twice in a row → `.none` → echo (bounded re-ask, then the honest fallback). Exact bound (2) pinned in the converse-step aspect's tests. |
| **`summary` overload / reply copy** | The spoken ack after a terminal decision is new surface text ("Done.", "Cancelled."); it is derived from the decision, bounded, and reviewed in the record aspect — not a new audit field. |
| **Time-boxed trust deferred** | The §8 deferral (R6) is a decision, not a drift: M4a binds the type today, and the recorded blockers (persisted trust state, changed approval semantics) are what the future slice will lift. `CAPABILITY_ROADMAP.md` gets the decision in the C13 amendment. |

## Out of Scope

- **`ShellProvider`** — highest-blast-radius component, deferred (`action-surface-wiring/prd.md:219`).
- **Coding-agent handoff** and reply-text *rendering* (the converse transcript surface stays
  an open P3 question, `PRODUCT_SPEC.md:421`).
- **Argument-building UI** for MCP tools (R5's arguments come from the resolver's text,
  validated by the provider).
- **Real MCP discovery wiring for voice** — D2 stands: discovery spawns and answers
  `discovery.unwired`; the voice path composes over the enablement catalog only
  (`action-surface-wiring/prd.md:98-105`).
- **Time-boxed trust and decaying per-tool trust** — decided and deferred (R6).
- **Voice-triggered actions in the shipped default** — unwired by design (R7, N1 records
  the flip as a reviewed edit).
- **BYOK/LLM intent** — the OSS core is local and deterministic; a hosted or BYOK intent
  implementation is a later *addition* to the seam, never this slice, never a replacement.
- Any change to the dictation path, capture, ASR, cleanup, injection, or TTS surfaces.
- Cloud anything: no hosted provider, no telemetry, no egress.

## Decisions made in this unit (for the record)

1. Intent seam = **`VoccaCore/Intent/`** — Core vocabulary, Foundation-free, the
   `ReplyGenerator` precedent; no new module.
2. First implementation = **`KeywordIntentResolver`** (token-scored, seeded synonyms,
   not-confident threshold); composed default = **`NullIntentResolver`** (unwired posture);
   the D3-shaped guardrail-7 caveat recorded honestly (S1 is the retirement path).
3. The catalog = **the enablement, never-read** — only enabled tools are ever resolved to.
4. Driver integration = **async lazy closure on `ConverseLoopDriver`** (the
   `asrProvider`/`cleanupProvider` shape), the reply seam untouched; the frozen-signature
   pin is the reviewed-edit mechanism.
5. Voice actions = **the shared executor + card reuse** — `root.actionExecutor`,
   `presentActionConfirmation` with a fresh generation token, existing
   confirm/decline closures; every decision recorded.
6. §8 = **never-silenceable floor pinned, time-boxed trust and decaying trust decided and
   deferred** with blockers recorded.
7. Composed default = **resolves nothing** (`intentResolved=0`, `spawnsSubprocess=false`,
   echo unchanged); the flip (N1) is a reviewed edit.
8. The ask path = **spoken only** (no card); bounded re-ask then echo; the next turn
   re-resolves.

## Aspect decomposition (proposal)

| Aspect | Boundary |
|--------|----------|
| `intent-seam` | `VoccaCore/Intent/`: the protocol, the resolution vocabulary, `KeywordIntentResolver` + `NullIntentResolver`, the seeded synonyms + threshold, the family lint |
| `converse-step` | The `ConverseLoopDriver` widening (compile pin as reviewed edit), the pipeline branch (.ask / .toolCall / .none), the bounded re-ask, `ConverseTurnFailure` decision |
| `action-round-trip` | `IntentWiring`: catalog-from-enablement, the executor leg (submit → re-render → present card), the spoken acks per terminal decision, the §8 floor invariant test |
| `probe` | `PROBE-INTENT` drive + expected lifecycle + guard-the-guard, the default-config facts (`intentResolved=0`), G5 re-anchor, the wiring-family lint |
| `record` | Unit record, STATUS/CLAUDE.md/CAPABILITY_ROADMAP updates (incl. the §8 decision and the R8 caveat), ARCHITECTURE.md rows, SMOKE 148-150, floor ratchet |