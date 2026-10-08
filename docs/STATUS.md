# Vocca: Status Log

The full, append-only engineering status log for this repository —
what landed, when, and what each change did and did not do.
Previously the preamble of `CLAUDE.md`; moved here 2026-08-31 so the
always-loaded project context stays small. Newest entries first.

Read this when you need the history behind a decision. `CLAUDE.md`
carries the current state and the rules that still bind.

---

**The `converse-intent-wiring` unit shipped 2026-10-08 — the shipped voice leg is wired: in
the real app a spoken phrase on an enabled tool reaches the shared executor (a read-only tool
runs and is acknowledged by voice, an outward-facing tool shows the card and the reply says
"Confirm on screen."), and with no phrase file or no enabled tool every utterance still
echoes, byte-identical; no gate passes.**
`feat/converse-intent-wiring/aliz`. One aspect (`intent-leg-wiring`), four tasks (the record
is this entry). Floor **3117 → 3137** (executed 3137). Q1 (the fixed "Confirm on screen."
line) and Q3 (accept a card that appears mid-conversation) taken as the PRD's
recommendations, confirmed by the founder's approval (2026-10-07). This resolves the
`composite-intent-resolver` entry's "read this first" block below.

**What shipped.**
*The closures* — `AppBootstrap.composeConverseIntentClosures(root:)` (`ConverseWiring.swift`
— a ruling moved it out of `AppBootstrap.swift` so the hashed root's vocabulary stays
unchanged and no lint row was needed): two lazy `@Sendable` closures over a caller-supplied
root accessor, reading `root.intentWiring` **at call time** — a closure built before the
wiring is assigned resolves through it after (B2), a released root or an empty slot answers
`nil` (the driver's existing echo, B1). The provider maps the wiring's resolution through
as-is. The handler is `performAction` behind one wrapper: a non-nil answer is returned
verbatim — the ack, the failure copy (`auditRecorded == false`, B7) — and a `nil` answer
becomes the fixed line **`AppBootstrap.confirmOnScreenReply` = "Confirm on screen."** only
while a confirmation card is showing (`widgetStore.state.confirmation != nil`, B4/B5); with
no card it stays `nil` and the driver echoes (B6). `IntentWiring.swift` and its honest-drop
test are untouched. `ConverseIntentClosuresTests` +9.
*Through the real driver* — `ConverseIntentWiringTests` drives the real `ConverseLoopDriver`
with the static's closures over an `IntentRoundTripHarness` root (B8): a read-only phrase hit
speaks "Done."; a destructive hit speaks "Confirm on screen." (never the echo) with the card
up and nothing invoked; an empty table, a phrase with no enabled tool, a root without intent
wiring, a released root, a miss and a hit answered `nil` with no card each speak the echo
**byte-identical to the shipped `EchoReplyGenerator`'s output**; a second destructive request
while the card is up speaks the line again and adds no card; the turns after a confirmed card
behave normally. `ConverseIntentWiringTests` +10.
*The call site* — `configure` builds the closures over `{ rootBox.value }` (the weak box —
the driver retains the closures, a strong root would cycle) and passes them as
`intentProvider:`/`intentActionHandler:` to `composeConverseWiring` (the unit's only
composition-root edit, nine lines). `AppBootstrapWiringTests.testTheConverseCallSitePassesTheIntentClosures`
pins the source (the `converseReplySink:` precedent): both labels present, their values
`intentClosures.provider`/`.handler`, the static reached through `rootBox.value` — a
`{ _ in nil }` mutation fails it. +1. The floor was raised once, in `converse-floor`: 3117 + 9 + 10 + 1 = 3137, the floor script's own parse.
*The probe* — `PROBE-CONVERSE` **unchanged**: the drive passes nil closures on purpose (its
comment now says so), so `intentResolved=0` and the line stays byte-identical. The composed
default still reads `agents=0 spawnsSubprocess=false`; the zero-network suite green.

**G5 re-anchored once, deliberately** (`converse-pins`): `AppBootstrap.swift` was recomputed
with `shasum -a 256` on 2026-10-08 after the unit's only composition-root edit, never
edited-to-match — `a0dae00bf6…` → **`bfeed81f8c…`**, full literal
`bfeed81f8cd53cb3190425a48e072e3f316eba5884e7290563fc0b9e16676eba`, across all seven pin sites
(`WiringBaselineTests`, `AuthBaselineInvariantTests`, `AgentPresetsInvariantTests`,
`ActiveProjectInvariantTests`, `SpokenTaskInvariantTests`, `TurnTakingComposedAcceptanceTests`,
`ReplyRenderingInvariantTests`) plus the floor script's comment; the dictation digests
unchanged — `1baeb2de…`/`ce70ca10…`, recomputed and compared.

**Known limitations, recorded — not fixed.**
- **A phrase naming a coding agent is NOT voice-reachable in the shipped app.** `configure`
  composes the intent wiring over `AuditActionProvider` (`AppBootstrap.swift` ~749-755),
  which does not serve `vocca.agent`: an agent phrase describes as "Vocca's audit provider
  does not serve the tool … Nothing will happen", claims read-only, auto-runs and **fails** —
  the reply is "Something went wrong." and the audit gains an `autoRanReadOnly` entry carrying
  that sentence. No card appears and nothing spawns. The tests that compose the intent wiring
  over `CodingAgentProvider` (`AgentWiringCwdTests`, `UtteranceThreadingTests`) describe a
  composition `configure` does not have. **The follow-up — the next unit — routes the intent
  executor by provider id, as the card closures already do (`AppBootstrap.swift` ~852-876).**
  Until it lands, the slice-11 (`active-project-detection`) "the voice leg ships (S2)" claim
  for agents stays untrue in the shipped build (a pointer now sits beside it), and SMOKE
  158/162 record the known failure rather than a pass.
- **`AuditActionProvider` selects its tool by `toolID` alone and ignores `providerID` (`AuditActionProvider.swift:121-139`, `:165-179`): an enabled agent or MCP row whose tool id is `audit.clear`/`audit.count` gets the audit tool's behavior — a foreign `audit.count` row can speak "Done."; every step still needs a click and the card shows the true sentence, so it is not a bypass. Named acceptance test of the provider-routing follow-up unit: every intent dispatch checks `providerID` against the provider that serves it.
- **`AuditActionProvider` claims read-only for tools it does not serve**, so a stray enabled
  row for an unserved provider auto-runs (and fails) instead of confirming — harmless only
  because the provider is the audit provider; it goes away with the routing follow-up.
- **"Confirm on screen." can be spoken for a card that belongs to another action** — the
  card-up refusal (a second action while a card waits) and a card armed from the Actions tab
  mid-turn both produce a `nil` with a card showing. The card's own sentence is honest and
  confirmation is click-only, so nothing runs that the card does not name; the spoken line is
  just less specific than it sounds.
- **The line is true only if the card is visible.** The panel is created lazily and the card
  beside the reply bubble is an unverified layout — SMOKE 166 only.
- **No spoken confirm or decline** (N2 — a new trust surface, deferred), **and no session
  guard**: a card can appear during conversation and outlives the session until clicked
  (generation-tokened and click-only, so a stale card cannot be replayed; a walked-away user
  leaves an armed card). Clear-on-session-end is deferred.
- **Reachable by the founder only.** Phrases are hand-edited JSON (`intent-phrases.json`) and
  the audit tools have no Actions-tab row (F-A) — the enablement is a hand-edit too.
- **The zero-network dev-machine caveat still stands** (PROBE-INTENT-DEFAULT reads the real
  phrase file; switching `keywordFallback` on on a dev machine turns that line red; the
  directory-seam fix re-anchors G5 again).

**The honesty block:**
- **No gate passes.** The twentieth unit built ahead of the uncleared gates under the
  recorded posture. Demand: roadmap push, not demand pull — no user asked for voice actions.
- **No success, resolution or accuracy rate exists.** Every claim here is a test or a probe;
  "voice acts in the real app" is unmeasured until SMOKE 166 runs on a real machine.
- **The default did not move.** With no phrase file or no enabled tool the reply is the echo,
  asserted through the real wiring and the real driver; the composed default still reads
  `agents=0 spawnsSubprocess=false`; zero network; the dictation path digest-untouched.
- **R8 is in a real voice path for the first time** — mitigated in structure (the card,
  approval `.withheld`, every decision audited, the card-up refusal), not retired. N2 stands:
  an approval asserts a human said yes, cannot verify it.
- **Builds during the tasks were incremental**; the final verification is a clean build with
  the floor script (CI's exact command).

**SMOKE**: rows 154-156 and 165 lose their "VOID while the leg is unwired" conditions (148-150
were already conditioned on the phrase flip, which now reaches the app); 158 and 162 (agent
phrases) are marked known-failing per the first limit above; the new row **166** — the
real-app voice round trip — is **written and runnable**, recorded, never gated, no rates.

---

**The `composite-intent-resolver` unit shipped 2026-10-04 — C13 slice 13: the
phrase-then-keyword composite resolver ships, opt-in. With `keywordFallback` on in
`intent-phrases.json`, a phrase miss falls through to the keyword resolver (once the leg is
wired into the converse path — it is not today, below) with the shell and coding-agent
providers closed in both halves; with it off — the default — the composed resolver is the
phrase resolver exactly as before; no gate passes.**
`feat/composite-intent-resolver/aliz`. One aspect (`resolver-chain`), seven tasks (the
record is this entry). Floor **3083 → 3117** (executed 3117; 3114 at the unit record, +3 in the final-review fix wave). Q1-Q3 decided by the founder
delegating to the recommendations (2026-10-03): **Q1** the keyword leg behind its own
switch, default off; **Q2** fix F-C here; **Q3** the shell filter inside the composite.

**The shipped voice leg is unwired — read this first.** `AppBootstrap.configure`
(`AppBootstrap.swift:583`) calls `composeConverseWiring` **without** `intentProvider` /
`intentActionHandler`, so the driver gets their defaults, which return `nil`
(`ConverseWiring.swift:89-91`); only the probe reads `root.intentWiring`. **In the real app
neither `PhraseIntentResolver` nor the composite is reached by voice today — every utterance
gets the echo reply;** the resolvers are exercised only by tests and probes. This predates
this unit (since `phrase-intent-resolver`) and **this unit does not wire it**: wiring it is
the first time voice can act, needs its own review of the card surface, and is a founder
call — **the recommended next unit**. Everything below that describes what a keyword hit
*does* holds through the composed wiring the tests and probes drive, and will hold in the app
once the leg is wired into the converse path. **[resolved 2026-10-08 by `converse-intent-wiring`
(the entry above): `configure` now passes the intent closures; a phrase on an enabled audit
tool acts by voice in the real app, and a phrase naming a coding agent still does not — the
provider-routing follow-up.]**

**What shipped.**
*F-C fixed* — `KeywordIntentResolver.jsonEscaped` emitted `\u{XX}` (invalid JSON) for
control characters; it now emits `\u00XX`, two zero-padded hex digits. Pinned by
`KeywordIntentResolverTests.testEveryControlScalarExpandsToValidJSON` — every scalar
U+0000-U+001F round-trips through `JSONSerialization` as the same string. Floor 3083→3084.
*The switch* — `IntentPhraseFile.keywordFallback` (additive, default `false`) and the store's
decode: absent → off silently; present but not a `Bool` (`1`, `"true"`, `null`) → off with
one `onInvalid` log (the F1 no-coercion rule; `contains` first so an explicit `null` is not
read as absent); `true` → on; unknown keys still ignored; a shell row still refused at load
with the switch on; `version` stays 1; the encoder writes `nil` for off, so **an off file is
byte-identical to the shape before the switch** (pinned) and the encode→decode round trip
preserves it (the PRD's gap 2 — no production save caller exists today; the round trip is
pinned anyway). `IntentPhraseStoreTests` +7. Floor 3084→3091.
*The chain* — `CompositeIntentResolver` (`VoccaCore/Intent/`, Foundation-free, the empty
import allow-list holds): the primary first; any non-`.none` answer returned as-is and the
fallback **never consulted** (spy-proven, A1); on `.none` the fallback resolves against the
catalog with every excluded provider's rows removed, and a fallback `.toolCall` naming an
excluded provider is discarded to `.none` (A4 — each half tested alone with a stub, plus the
real keyword resolver over an enabled shell row); the sub-threshold `.ask` passes through
with at most three candidates (A3). The excluded set is caller-supplied — `VoccaCore` cannot
name the shell provider. `CompositeIntentResolverTests` +11. Lint rows: the
`IntentSeamBoundaryTests` and `ConverseWiringSeamBoundaryTests` permitted sets gained the
chain's own file, and `AppBootstrap.swift` for the keyword resolver's construction — reviewed
row edits (the checkpoint before Task 4). Floor 3091→3102.
*The composition* — `AppBootstrap.composeIntentResolver(file:)`: switch off, a bare
`PhraseIntentResolver` (the composite **not on the path**, type-pinned); switch on, phrase
first, `KeywordIntentResolver()` second, `[ShellProvider.providerID,
CodingAgentProvider.providerID]` excluded (the coding-agent exclusion added in the final
review's fix wave — a deliberate choice: a child-spawning, egress-unprovable provider is never
selected by a classifier guess; a phrase row naming `vocca.agent` still resolves, pinned); and
`composeIntentResolverProvider(store:)`, the per-turn provider `configure` now wires in place
of its inline closure — the file is loaded each turn, so flipping the switch needs no relaunch
(A6, re-read between two resolves with no recompose). `CompositeIntentWiringTests` +4. Floor
3102→3106. (Fix wave: +2 — an enabled agent row the bare keyword resolver reaches returns
`.none` through the composition, and a phrase row naming the agent still resolves.)
*The round trip* — `CompositeIntentRoundTripTests` through the shared executor: a keyword hit
on an outward-facing tool presents the card with approval `.withheld` and runs only on
confirm; a decline records the refusal and never invokes; a read-only keyword hit auto-runs
(`autoRanReadOnly`) and is audited **without a distinct marker** (D1, below); a sub-threshold
hit asks naming at most three and executes nothing (engine count 0); an enabled shell tool
never resolves and is never named in a `.toolCall` or an ask; switch off, the same utterance
resolves nothing. +7. Floor 3106→3113. (Fix wave: +1 — an enabled coding-agent row never
resolves by keyword through the composite: no card, no description, no invocation.)
*The probe* — PROBE-INTENT-DEFAULT **unchanged** (`resolver=PhraseIntentResolver resolves=1
intentResolved=0 spawnsSubprocess=false intentShellRows=0`); the new **PROBE-INTENT-COMPOSITE**
drives the switch-on composition over temp files inside the zero-network interposer
(`store.location=temporary store.isDefaultLocation=false resolver=CompositeIntentResolver
phraseResolved=1 resolved=1 card=yes invoked=1 shellResolved=0 intentShellRows=0
spawnsSubprocess=false`), with its counterfactual sibling **PROBE-INTENT-COMPOSITE-UNFILTERED**
(the same drive with the excluded set emptied — it must differ, or `shellResolved=0` would be
an absence rather than the filter's effect) and the guard-the-guard row. `IntentDrive`'s
resolver naming in the composite drive no longer degrades a composite to `other`. Floor 3113→3114 (executed 3114).

**The decisions.** **D1 — a read-only keyword hit carries no distinct audit marker:** it
auto-runs through the existing `autoRanReadOnly` path and is audited exactly as a phrase hit
is; the record does not say which leg resolved it. Pinned as the shipped behavior
(`testAReadOnlyKeywordHitAutoRunsAndIsAuditedWithoutADistinctMarker`), not as a guarantee —
a distinct marker is a later, reviewed audit-shape change. **The posture:** with the switch
off the opt-in stays two steps (a phrase **and** an enabled tool); with it on, one step (an
enabled tool) by the user's explicit choice — both once the leg is wired into the converse
path.

**G5 re-anchored twice in this one unit, deliberately** (`composite-pins`): `AppBootstrap.swift`
moved with the provider recipe and the comment that describes it, so the pin was recomputed
with `shasum -a 256` on 2026-10-04 **after the unit's last composition-root edit**, never
edited-to-match — `bc2ce1fdf2…` → `d46fd9284f…`; then the final review's fix wave widened the
keyword leg's exclusion to the coding-agent provider (`AppBootstrap.swift` moved again), and
the pin was recomputed the same way — `d46fd9284f…` → **`a0dae00bf6…`**, full literal
`a0dae00bf635ad9a6abd3ed45b5f019fc2c286a8636cf76beccb145d4420a9d7`, **across all seven pin
sites** (`WiringBaselineTests`, `AuthBaselineInvariantTests`, `AgentPresetsInvariantTests`,
`ActiveProjectInvariantTests`, `SpokenTaskInvariantTests`, `TurnTakingComposedAcceptanceTests`,
`ReplyRenderingInvariantTests`) plus the floor script's comment; the dictation digests
unchanged — `1baeb2de…`/`ce70ca10…`, recomputed and compared.

**Known limitations, recorded — not fixed.**
- **The switch is hand-edited JSON; there is no settings UI** (the named deferral — the F-A
  shape). Today the only person who can reach the keyword leg is someone who edits the file.
- **The spoken ask names raw identifiers.** The production catalog carries `displayName: ""`
  (`IntentWiring.swift:239`), so the ask falls back to `provider/tool` — TTS reads out
  `dev.vocca.audit/audit.count`. Safe, and poor; spoken display names are a follow-on.
- **The fallback's `.ask` is guarded by the catalog filter alone.** The composite discards a
  keyword `.toolCall` naming an excluded provider, but does not inspect an `.ask`; the ask
  cannot name a shell row because the keyword resolver never sees one (pinned through the
  real keyword resolver), not because the composite checks it. A primary `.toolCall` naming
  an excluded provider passes through — its guard is the phrase store's refusal at load.
- **PROBE-INTENT-DEFAULT reads the real phrase file.** The default drive composes over the
  real `~/Library/Application Support/Vocca/intent-phrases.json` (pre-existing since
  `phrase-intent-resolver`; a `HOME` override does not isolate it — Foundation ignores HOME
  for `applicationSupportDirectory`), so **turning `keywordFallback` on on a dev machine turns
  that line red** there (it reads `resolver=other` — the default drive names only a
`PhraseIntentResolver`; CI is unaffected). The failure
  message now names the cause. The test is deliberately **not** skipped conditionally; the
  fix is a directory seam in `AppBootstrap.configure`, a follow-up that **re-anchors G5
  again**.
- **Shell is closed in both halves** of the composite and refused at load by the phrase store
  — the intent-seam shell leg stays a founder call. **Coding agents are closed to the keyword
  leg too** (both halves), deliberately; a phrase row may still name `vocca.agent` — that is
  explicit user authoring.
- **Provider-ID matching is case-sensitive.** A hand-edited `DEV.VOCCA.SHELL` row passes both
  the phrase store's load refusal and the composite's filter, then fails as an unknown tool at
  the audit executor — no child can result.
- R8 mitigated, not retired: a keyword hit is a classifier guess; confident-but-wrong at ≥0.75
  is possible and unmeasured; the card and `.withheld` approval are the backstop for an
  outward-facing tool, and a read-only tool auto-runs. N2 stands (an approval asserts a human
  said yes, cannot verify it).

**The C13 remaining-machinery list loses the composite resolver** (`CAPABILITY_ROADMAP.md`'s
new amendment carries the current list: the audit-tools arm section, the intent-seam shell
leg, the §8 trust deferrals, `$N` parameter slots, and this unit's follow-ons — the settings
row, spoken display names, the directory seam). `ARCHITECTURE.md`'s Intent row and a new
annotation describe the chain; `README.md` untouched — it never quoted the intent default.

**No gate passes** (nineteenth unit ahead of the uncleared gates); **no resolution rate
exists**; the shipped default did not move — the switch is absent, so the composed resolver is
the phrase resolver alone, and the composed default still reads `agents=0
spawnsSubprocess=false`; zero network; the dictation path digest-untouched. SMOKE 165 is
**written and runnable** — recorded, never gated; it records utterance counts and the spoken
ask verbatim, never a rate — and it is **VOID** while the converse path does not pass the
intent leg (the app echoes; nothing resolves).

---

**The `reply-text-rendering` unit shipped 2026-10-03 — the CONVERSING surface stops being
audio-only: the spoken reply is rendered verbatim in a bubble beneath the pill, bounded at
2000 characters, cleared by the next utterance and by barge-in, and kept when the render
fails; no gate passes.**
`feat/reply-text-rendering/aliz`. Five aspects (the record aspect is this entry; the
carrier's deferred wiring is its second half). Floor **3052 → 3083** (executed 3083).

**What shipped, per aspect.**
*reply-carrier* — `ConverseLoopDriver` gains the **additive `converseReplySink:
@Sendable (String?) -> Void`** (default `{ _ in }` — byte-identical when unwired;
`ConverseLoopDriver.swift:148`, `:243`), with the emissions at the `.speakReply` effect's
application (the text before the render starts — `:345`; the loop's own accepted-schedule
event, so a refused `scheduleReply` emits no effect and a superseded turn never shows a
phantom bubble; **the ask path's question and the action handler's reply both flow through
this one point** — the PRD's gap-1 coverage, verified not special-cased), `nil` at the
`.bargeIn` application (the cancel path — `:352`), and `nil` on the loop's transition to
`.listening`/`.idle` through the wrapped `onStateChange` (`:277-279`); **no clear on a
render failure** — the failure's `reportPlaybackEnded()` (`.playing → .listening`) is
suppressed by the armed/disarmed `ReplyClearSuppressionBox` (`:561`), so the text stays
(the recorded replyFailed rule). Pinned by `ReplyCarrierTests` (acceptances 1-6: the reply
once at schedule time — the sink already holding it when the render resolves, the
before-audio proof; the ask's question; the barge-in clear; the listening and idle clears;
replyFailed keeps with the suppression not sticking; the unwired default byte-identical).
Floor 3052→3059.
*reply-state* — the `WidgetAction` closed set gains **`.replyPresented(String?)`** (the
**eighth** case — the deliberate amendment; the compile pins in `WidgetContextReducerTests`
and `WidgetConfirmationStateTests` grew to eight cases and the `EgressBadgeReducerTests`
enumeration carries it); `WidgetReducerState.replyText` (converse-only — a text lands only
while CONVERSING, every dictation/IDLE adoption clears it, the notice path starts a fresh
IDLE; `WidgetStateReducer.swift:115`); **`WidgetTiming.maxReplyCharacters = 2000`**
(`:242`), truncation in the reduce row's one place (`:349-362`); the carrier's `nil` clear
applies from any state; the listening ↔ speaking phase change keeps the text (the turn is
continuous); the `adopting` `.conversing` invariant amended deliberately — "the phase is
the state's only content" → "**the phase plus the bounded reply text**" (the probe
amended, `WidgetStateReducerTests.swift:700`); the store's thin `presentReply(_:)`
(`WidgetStateStore.swift:142`, the `presentPartial` shape). Floor 3059→3064.
*reply-wiring* (the carrier's deferred second half) — `AppBootstrap` passes
`converseReplySink:` to `composeConverseWiring` (`AppBootstrap.swift:586-595`): the closure
folds `root.widgetStore.presentReply(text)` through the **weak rootBox** on the main actor
(`MainActor.assumeIsolated` — the `converseStateSink` block's exact shape; the driver
retains the closure, so a strong root capture would cycle). Pinned by
`AppBootstrapWiringTests.testTheConverseReplySinkIsWiredIntoTheWidgetStore` — a source scan
of the call site (`configure` needs an `NSApplication`), the shipped-composition pin shape.
**The ordering recorded:** the wiring's fold needed `presentReply(_:)`, so the carrier's
RED/GREEN landed with `AppBootstrap` untouched (the floor raised, the G5 re-anchor
deferred — `ac74a80`), and both closed in this commit. Floor 3064→3065.
*reply-view* — `WidgetCopy.shouldShowReplyBubble` (non-nil **and** non-empty — an empty
reply is silence, the generator's own contract; `WidgetCopy.swift:118`) + `replyBubbleLabel`
(the reply text verbatim — the label and the visible `Text` cannot drift, `:127`; the panel
is non-key, so VoiceOver announcement is **best-effort**, recorded at `:123-129`); the
`WidgetView` CONVERSING branch renders the pill plus the conditional bubble
(`WidgetView.swift:94-101`): the confirmation card's chrome (material, hairline, shadow,
rounded corners), the failsafe's bounded text surface (`ScrollView` 48-160 pt,
`textSelection(.enabled)`, the `.fixedSize` wrap), `accessibilityLabel`; the width band
**260-420 pt** — the 420 maximum is a **measured addition** (without it the wrap never
engages: a long reply sized the whole panel to one unbounded line, measured with
`NSHostingView`; `:167-170`); the pill's five cues and the never-a-target render untouched.
Pinned by `ReplyBubbleTests` (the show decision and its `WidgetView` source pin, the
verbatim carry, the exact copy pins, the never-a-target scan extended to the bubble
renderers, the five-cue cross-check) plus two `WidgetCopyTests` rows. Floor 3065→3073.
*agent-pins* — `ReplyRenderingInvariantTests` (acceptances 1-5), run inside the
zero-network interposer: **PROBE-CODING-AGENT verbatim-unchanged** with the carrier, the
bounded state and the bubble in the tree (the composed default still reads `agents=0
spawnsSubprocess=false`); the **lint immobilities** (the transport permitted set still
exactly two files, the FileManager seam table still eight seams, Family A's seven families
and Family B's single minting file, the `policy:` parameter still default-less with all 96
`ActionGate.submit` call sites supplying it, the `ConversePhase` family still confined to
`WidgetProjection.swift`, the M4a no-remember scans green over the unit's own reply rows);
the **digests** — the dictation pair unchanged, `AppBootstrap` equals the re-anchored
literal, and the across-the-sites leg reads it back out of all six sibling pin sites; the
module-coverage cross-check (twelve library modules — fields, a case and copy, no module
files); the zero-network default-configuration drive green. Floor 3073→3083 (executed
3083).

**The decisions.** **Q1 — the lifecycle is the conversation's:** the text is sunk at
`.speakReply` (before the audio starts — the bubble appears with the speech), cleared on
the next utterance's listening and on idle. **Q2 — the pill plus a bubble:** the bubble
sits beneath the pill, addition-only; the five cues stay exactly as shipped and the
never-a-target render stays. **Q3 — barge-in clears:** the interrupted reply's text is
discarded with its audio at the driver's cancel point. **The ask-path coverage:** one
emission point covers every reply — the bounded re-ask's question and the action handler's
reply both speak through `.speakReply`, verified, not special-cased. **The replyFailed
keep:** no clear on a render failure — the failure's `.playing → .listening` close is
suppressed for exactly that transition (armed and disarmed around the one call), so a
later listening/idle transition clears as usual; the text stays (the reply happened as
text; nothing was heard — the text is more valuable). **The VoiceOver honesty:** the
bubble's label is the reply text verbatim; the panel is non-key, so announcement is
best-effort — recorded; SMOKE 164 observes what a real VoiceOver session hears. **The cap
and the measured width:** 2000 characters in the reducer (the `maxPartialCharacters`
shape; the view scrolls beyond it — the bound is the state's, never the bubble's); the
bubble's 420 pt maximum is a measured addition (`NSHostingView`), not a taste call. The
closed-set amendment is deliberate: `.replyPresented` is the eighth `WidgetAction`, and the
invariant is amended to "the phase plus the bounded reply text".

**G5 re-anchored once, deliberately** (the carrier's wiring REFACTOR `fb65157`):
`AppBootstrap` moved with the reply sink, so the pin is re-computed with `shasum -a 256`
on 2026-10-03, never edited-to-match — `4e50ab8dde…` → **`bc2ce1fdf2…`**, full literal
`bc2ce1fdf261819b8477b7951a6d506c7980c072a674ffc77311014c59b76bd6`, **across all six pin
sites** (`TurnTakingComposedAcceptanceTests`, `AgentPresetsInvariantTests`,
`SpokenTaskInvariantTests`, `ActiveProjectInvariantTests`, `WiringBaselineTests`,
`AuthBaselineInvariantTests`) plus the new `ReplyRenderingInvariantTests` suite's own
acceptance (its across-the-sites leg reads the other six back) and the floor script's
comment; the dictation digests unchanged — `1baeb2de…`/`ce70ca10…`, asserted by the
re-anchored pins.

**The deferrals, with their blockers.** **N1 — the copy affordance** (⌘C to copy the
reply, the failsafe's ⌘C precedent): deferred — the widget panel is **non-key**
(`WidgetPanel.canBecomeKey == false`), so it never receives key events and a ⌘C handler
cannot fire on it; a copy affordance needs a mechanism the panel does not have (a button,
or an owned key path) — a later surface conversation. **The turn-history deliverable**
(`ROADMAP.md:205` — "bounded, inspectable, local turn history — with a visible 'forget'
control"): stays a **separate, unclaimed P3 item** — this unit renders the current reply,
not history; the bubble is single-turn by construction (the carrier's `nil` clears it on
the next turn).

**The `reply-text-rendering` deferral is retired.** The C13 amendment's remaining-machinery
list no longer names it — the real spoken answer to an agent run ships (the reply seam's
last piece); the new amendment is the current list: the **phrase-then-keyword composite
resolver**, the **audit-tools arm section**, the **intent-seam shell leg**, the **§8 trust
deferrals** and **`$N` parameter slots** remain, and the **turn-history item stays named as
the separate unclaimed P3 deliverable**, never folded into the C13 list.
`docs/technical/ARCHITECTURE.md`'s converse annotation gained the reply-sink clause (the
seam fact changed); `README.md` untouched — verified, it never quoted the reply surface.

**The flake, recorded honestly.** The **pre-existing `AudioRingBufferTests` contention
flake** fired once during this unit's full-suite attempts (the `reply-view` REFACTOR; the
test's own comment: "the point is to exclude 0.05 %, not to pin a scheduler") and did not
recur on the green run — scheduler-dependent, unrelated to this unit (no audio code
touched); recorded, never chased.

**No gate passes** (eighteenth unit ahead of the uncleared gates); the composed default
still reads `agents=0 spawnsSubprocess=false`; zero network; the dictation path
digest-untouched (the pin proves it). SMOKE 164 is **written and runnable** — recorded,
never gated; no reply rate may be quoted. The record aspect closed the docs sync:
`CLAUDE.md`'s status paragraph and `CAPABILITY_ROADMAP.md`'s C13 amendment.

---

**The keep-in-tray default flips to on — a founder decision (2026-10-01), landed 2026-10-03 on
`feat/agent-auth-baseline/aliz`.** `PersistedSettings.decodeKeepInTray`'s absent answer is now
`true`: a fresh install has chosen nothing and keeps running in the menu bar, so quitting from
outside the tray (⌘Q / Dock quit) is refused until a choice is made — the **Keep in menu bar**
setting defaults ON, superseding the settings-unit record's "quit-normally as both the absent
and the unreadable answer". **The unreadable direction is unchanged** — a corrupted entry still
decodes to `false`, loudly, the hostage argument intact (degrading corruption to `true` would
refuse to quit on a choice nobody made). The decode row and the adapter's fresh-install row
flipped test-first; both doc comments state the new absent meaning; `SMOKE_CHECKLIST.md`'s
keep-in-tray row's "(the shipped default)" corrected from off to on; `SettingsCopy.keepInTrayDetail`
states no default and is untouched. **No gate passes**; test count unchanged, floor stays **3052**.

**The `agent-auth-baseline` unit shipped 2026-10-03 — C13 follow-on: both agent auth
modes work. The executor's environment scrub is refined deliberately — a declared
baseline (`HOME`) merged under the row's own entries, configured wins even empty — so
a logged-in CLI runs from an empty-environment row and finds its own credentials; no
gate passes.**
`feat/agent-auth-baseline/aliz`. Five aspects (the record aspect is this entry). Floor
**3023 → 3052** (executed 3052).

**What shipped, per aspect.**
*executor-baseline* — **`ShellExecutor.Configuration.baselineEnvironment:
[String: String]`** (default `[:]` — byte-identical when not wired: a real run with no
baseline still shows the caller's `PATH`/`HOME` absent, the existing scrub rows
unchanged); `run()` sets
`process.environment = configuration.baselineEnvironment.merging(configuration.environment)
{ _, new in new }` — **configured wins, even an explicitly empty value** (`"HOME": ""`
in the row beats a real baseline `HOME` — the intent rule, the merge edge pinned; the
env-printing rows extended); nothing beyond the declared baseline and the row's own
entries ever reaches the child; the baseline is declared per configuration, **never
inherited from the caller's environment**. **The N2 rewrite** (the record's other
half): the doc comment's "The environment is scrubbed. The child receives exactly the
configured variables — the empty dictionary by default — never the caller's
environment (N2)" is retired, replaced by "never beyond the declared baseline and the
row's own entries (N2)" (`ShellExecutor.swift:59-64`, `106-111`). Floor 3023→3027.
*provider-baseline* — both providers gain the **additive `baselineEnvironment:
[String: String] = [:]` init parameter** (`CodingAgentProvider.swift:181`,
`ShellProvider.swift:131` — the default-posture doctrine) and carry it into every
`ShellExecutor.Configuration` they build; **the shell consequence named**: shell rows
declare no environment of their own, so a wired baseline is the whole of what a shell
child receives — the shell rows' children receive HOME once the composition wires it
(`ShellProvider.swift:63-66`); the counting-engine acceptance asserts the merged
configuration (S1 — the merge rule pinned twice: the executor's env pin and the
provider's configuration). Floor 3027→3033.
*wiring-baseline* — **`AppBootstrap` wires `baselineEnvironment: ["HOME":
NSHomeDirectory()]` at exactly two sites** (`AppBootstrap.swift:774` the shell
provider, `:820` the agent provider — the composition root may name Foundation;
VoccaActions never computes home, the lint boundary holds; the `load` factories take
no baseline, so each provider is constructed through the init — the real engine, the
shipped clock and sleeper, exactly as the factory's default would); **`KnownAgentPresets.authHint`**
— the field + **eight pinned hints** (claude/codex/gemini/opencode/aider/cursor/q/crush,
each row's honest copy: the key spelling and/or the subscription login the CLI's own
docs name — `claude` subscription login, `codex login`, `gemini login`, `opencode
auth`, `cursor auth`, `q auth`; a preset without a subscription mode says the key
spelling only; the planted-wrong-hint control pins them); the **editor renders the
hint under the Environment field** (`ActionsTabPage.swift:376-386` — shown only when
the picked preset declares one); the **D2 line** `agentBaselineD2Copy` — *"the
baseline hands the agent your home directory; configure only agents you trust"* —
placed in the agents section, the moment of trust (`ActionsTabCopy.swift:173-174`,
rendered at `ActionsTabPage.swift:117`); **the probe keeps the default `[:]`
baseline**, recorded in the drive headers (`CodingAgentDrive.swift:81-91`,
`ShellDrive.swift:78-86`): the composed default's facts (`agents=0`/`commands=0`,
`spawnsSubprocess=false`) are about the configuration, not the environment, and the
seeded round trips run `/bin/echo`, a child that needs no HOME — the day a seeded
child reads HOME, the drive must wire a temp HOME explicitly (the
`baselineEnvironment:` init parameter), keeping the default facts unchanged either
way. **G5 re-anchored once, deliberately** (the wiring REFACTOR commit `d1b5082`):
`AppBootstrap` moved with the HOME wiring, so the pin is re-computed with
`shasum -a 256` on 2026-10-03, never edited-to-match — `641b6445…` →
**`4e50ab8dde…`**, full literal
`4e50ab8dde8dd20f3b3b02e8e6ebb4a4fe97705cd58e2120fdb2e2364d8775cf`, **across all five
pin sites** (`TurnTakingComposedAcceptanceTests`, `AgentPresetsInvariantTests`,
`SpokenTaskInvariantTests`, `ActiveProjectInvariantTests`, `WiringBaselineTests`
acceptance 5); the dictation digests unchanged — `1baeb2de…`/`ce70ca10…`, asserted by
the re-anchored pins. Floor 3033→3044.
*agent-pins* — **`AuthBaselineInvariantTests`** (acceptances 1–5), run inside the
zero-network interposer: **PROBE-CODING-AGENT verbatim-unchanged** with the baseline
wired and the hints on the surface — the composed default still reads `agents=0
spawnsSubprocess=false` (a wired baseline is a value in the environment of a child
the default never spawns, so the interposer sees no call from it); the **lint
immobilities** read off the lint suites' own literals (the transport permitted set
still exactly the two reviewed entries, the FileManager seam table still exactly
eight seams, Family A's seven families and Family B's single minting file unchanged,
the `policy:` parameter still default-less with all 96 `ActionGate.submit` call sites
supplying it — count pinned, zero offenders); the **digests** — the dictation pair
unchanged, `AppBootstrap` equals the re-anchored literal, and every one of the five
pin sites carries the same literal (the across-the-sites leg); the module-coverage
cross-check (the derived set is still the twelve library modules — the unit added a
field, init parameters and catalog copy, **no module files**); the zero-network
default-configuration test green. Floor 3044→3052 (executed 3052).

**The decisions.** **D1 — executor-level, every child:** the baseline applies at the
executor level, so agent rows AND shell rows carry it once the composition wires it —
one rule, no provider special-casing; the shell rows' scrub changes only when the
composition wires the baseline — the reviewed boundary is the composition, never the
executor's default. **D2 — HOME only:** the minimal thing any CLI needs to find its
own credential store; the row's entries win; nothing else from the session; the
honest baseline is HOME only — a future widening is a reviewed edit with the same
merge rule. **D3 — auth hints:** per-preset `authHint` copy in the catalog, rendered
under the editor's Environment field — the user knows which auth each CLI supports.
**The explicit-wins-even-empty merge edge:** a configured entry wins even when
explicitly empty — `"HOME": ""` in the row beats a real baseline `HOME` — the row's
intent, tested (the critique's gap-1 edge, pinned at both the executor and the
provider level).

**The N2 rewrite, named.** The old scrub wording — "The environment is scrubbed. The
child receives exactly the configured variables — the empty dictionary by default —
never the caller's environment (N2)" — is **retired** from the executor's record,
replaced by: the child receives exactly `baselineEnvironment` merged with
`environment`, "never beyond the declared baseline and the row's own entries (N2)"
(`ShellExecutor.swift:59-64`). The claim narrows honestly: the baseline is declared
per configuration, never inherited; what a child gets is exactly the declared
baseline + the row's own entries, nothing else from the session.

**The deferrals, with their blockers.** **N1 — the credential-store probe** (the
editor showing which auth the CLI detected, e.g. "subscription login found in
`~/.claude`"): deferred — it needs a credential-store probe the repo has not reviewed
(the PRD's N1); the honest surface is the pinned `authHint` copy, and "detected"
means the binary exists at a path, never that it is signed in (R-B — the subscription
login is the CLI's own state; Vocca cannot verify it; the failure is the CLI's own
loud error in the run's outcome). **The LANG/TMPDIR widening** (R-A — some CLIs want
more than HOME): deferred — the honest baseline is HOME only; a widening is a
reviewed edit with the same merge rule. **The probe's temp-HOME wiring**: not needed —
recorded as the drive posture (the day a seeded child reads HOME, the drive wires a
temp HOME explicitly, default facts unchanged).

**The flake, recorded honestly.** The **pre-existing `AudioRingBufferTests` contention
flake** was observed during the unit's full-suite runs — scheduler-dependent (the
test's own comment: "the point is to exclude 0.05 %, not to pin a scheduler"),
unrelated to this unit (the dictation path is digest-untouched; the unit touched no
audio code); recorded, never chased.

**No gate passes** (seventeenth unit ahead of the uncleared gates); the composed
default still reads `agents=0 spawnsSubprocess=false`; zero network; the dictation
path digest-untouched (the pin proves it). SMOKE 163 is **written and runnable** —
recorded, never gated; no agent-success rate may be quoted. The record aspect closed
the docs sync: `CLAUDE.md`'s status paragraph, `CAPABILITY_ROADMAP.md`'s C13
amendment; **`ARCHITECTURE.md` and `README.md` untouched — verified, neither quoted
the old N2 scrub wording** (the ShellExecutor row and the D2 copy carry the narrowed
claims, never the scrub line; the expected non-change, recorded).

---

**The `active-project-detection` unit shipped 2026-10-01 — the C12 metadata extension +
agent-provider integration: the focused app's working directory rides the arm-time
metadata lane into the agent sentence and the run; no gate passes.**
`feat/active-project-detection/aliz`. Five aspects (the record aspect is this entry). Floor
**2958 → 2991** (executed 2991).

**What shipped, per aspect.**
*working-directory-source* — **`WorkingDirectoryRead`** (`VoccaContext/Accessibility/
WorkingDirectoryRead.swift` — a new seam file, the `AgentCLIDetection` shape: a pure
resolver over an injected closure): `resolve(pid:libprocRead:)` (one closure call, nothing
else — headless-testable over a recording fake) + **`libprocCwd`** (one
`proc_pidinfo(PROC_PIDVNODEPATHINFO)` call; the C string lives in `pvi_cdir.vip_path` —
**the field-name note: the struct member is `vip_path`, never `vi_cwd`**, the vnode-info
half); every failure → `nil` (the never-throw doctrine); names no AX prefix, no
FileManager identifier, no `Process`-prefixed identifier. `ContextAXReading` gains the
`focusedProcessIdentifier` witness; **`AccessibilityContext.workingDirectory()`** ships
with the **additive defaulted `workingDirectoryRead` parameter** (default = the real
`libprocCwd` — the composed default is the honest read, never an unwired nil), Secure
Input refused first (the refusal stays the `resolveCurrent` ordering). The cwd read
**never joins `ContextSnapshot`** (resolution byte-identical — D1). Floor 2958→2967.
*invocation-carrier* — `ActionInvocation.resolvedDirectory: String?` (additive, default
nil — every existing construction site compiles unchanged; empty refused, so absence has
one spelling), `WidgetConfirmationSignal.resolvedDirectory` (additive, the card carries
it), the **nil-tolerant sentence** (`CodingAgentSentences` — no directory → no `in`
clause; the both-nil leg ships in the sentence and the configuration half pins the
executor's `currentDirectoryURL` nil default, the pre-fix fallback), and the provider's
rule in both halves: **`invocation.resolvedDirectory ?? agent.projectDirectory`** —
describe's `in <dir>` clause and invoke's `currentDirectoryURL` (the argv-that-runs
doctrine extended to the directory — the child starts where the sentence says it will);
`currentDirectoryURL` omitted when both are nil. The **gap-1 pin holds** with arguments
AND a resolved directory on the same invocation (the directory is a separate field, never
`arguments`). Floor 2967→2976.
*agent-wiring-cwd* — `composeCodingAgentWiring`/`composeIntentWiring` gained
**`activeProjectDirectory: @Sendable () async -> String?`** (nil-shaped default — additive
composition, probe-safe): at arm, a row whose project directory is blank (or that the
loaded registry lacks — the tolerant decode's skip, the honest "empty" spelling) is
resolved **exactly once** and carried on the invocation; an explicit row is never
re-resolved (**D2 — explicit wins, the recording-fake zero-calls proof**); the card
carries `resolvedDirectory`, and confirm/decline rebuild the invocation from
`signal.resolvedDirectory` — **one resolution, four identical renders** (the sentence
binding's four renders: the arm's card render, the post-record re-render, the confirm's
gate render, the mismatch re-prompt render — a focus change mid-card can never produce a
mismatch loop or a run in a directory the user was not shown, G3/R-B). **The voice leg
ships (S2)** [not in the shipped app — an agent phrase is not voice-reachable until the intent executor routes by provider id; see converse-intent-wiring]: a phrase resolving to the agent's invocation is enriched with the arm-time
resolution — the card carries it, the confirm runs in it; the unwired voice leg's
clause-less sentence is pinned. The R4 editor caption ("leave empty to detect the focused
app's project"). Floor 2976→2983. **G5 re-anchored once, deliberately** (the wiring
REFACTOR commit: `c7d6767c…` → `641b6445…`, full literal
`641b6445fd163dde55561a242da4e745f79dd7fd61aedcac7c9aff123dd4d237`, computed with shasum,
never edited-to-match; the dictation digests unchanged — `1baeb2de…`, `ce70ca10…`);
**three pin sites carry the AppBootstrap literal** (`TurnTakingComposedAcceptanceTests`,
`AgentPresetsInvariantTests`, `ActiveProjectInvariantTests`).
*agent-pins* — the invariant suite for the unit, run inside the zero-network interposer:
PROBE-CODING-AGENT's line asserted verbatim with the unit's files in the tree (the
composed default still `agents=0 spawnsSubprocess=false` — the cwd read composed, the two
zeroes), the module-coverage cross-check recomputed from the manifest (twelve library
modules, the equality re-asserted), the transport permitted set still exactly the two
entries, the FileManager seam table still exactly eight seams, the AX family still the two
one-file seams (the context seam's entry still `AXContextSource.swift` plus the new file's
own naming contract), the Family A/B tables and the policy no-default read off the pin
file, and the G5 digests recomputed at the re-anchored literal. Floor 2983→2991 (executed
2991).

**The two recorded GREEN findings.** (1) **`ActionEnablement.isEnabled` compares the
tool's identity — `providerID` + `toolID` — never the invocation's payload**
(`ActionGate.swift:52-87`): the carrier's payload-bearing invocation (with
`resolvedDirectory`) would have been declined as not-enabled against the persisted
payload-less enablement rows; the `arguments` payload has the same latent wall,
unexercised because no shipped path submits it through the set; no pin moved. (2)
**`CodingAgentProvider` completes the carrier's nil leg**: a blank row directory resolves
to nil → the clause-less sentence, never "in ." — the shipped row shape's directory is
required, so the nil leg is exercised through the blank spelling.

**The decisions (D1–D3).** **D1 — the metadata lane:** the cwd is a directory path, never
content — no per-app consent (the bundleID/windowTitle lane), never persisted, shown in
the sentence; the cwd **never rides the consent-gated `root.contextResolution` slot**,
never joins `ContextSnapshot`, never in the BYOK payload (the AND-gate never carries it).
**D2 — explicit wins:** a row with a configured directory uses it, deterministically;
detection is never consulted for that row (the zero-calls proof). **D3 — ship + measure:**
`proc_pidinfo(PROC_PIDVNODEPATHINFO)` was unmeasured in this repo; SMOKE 161 measures the
real read on the founder's real apps before any "works everywhere" claim, while the
headless suite pins the seam over injected fakes.

**The deferrals, with their blockers.** **Tab-awareness** — the critique's hard question
recorded: this slice resolves the **frontmost app only** (the AX focused-process fact),
never the active tab/window of a multi-window app — recorded, a later slice's
conversation. **`~` expansion** — the detected path is never tilde-shortened and a row's
directory cannot spell `~` (the registry's absolute-path rule): the file-system seam has
**no home accessor** (the `AgentCLIDetection` record). The **N1 live "detected" hint** in
the row editor stays deferred (the caption is the shipped copy).

**No gate passes** (fifteenth unit ahead of the uncleared gates); the composed default
still reads `agents=0 spawnsSubprocess=false`; zero network; the dictation path
digest-untouched (the pin proves it). SMOKE 161 is **written and runnable** — recorded,
never gated; no resolution rate may be quoted. The record aspect also closed the docs
sync, including the recorded prose fix: `CLAUDE.md`'s coding-agent-handoff paragraph still
named `dev.vocca.agent` after the rename (the dig) — corrected to `vocca.agent`, a
documented fix, never a rewrite of the historical record.

---

**The `spoken-task-seeding` unit shipped 2026-10-01 — the N1 retirement: phrases arm
rows AND the full spoken utterance fills the argv's `<task>` placeholder — one row, any
task, per conversation; no gate passes.** [Dated history. The voice leg that fills the
placeholder is wired into the shipped converse path by `converse-intent-wiring`, but a
phrase naming a coding agent fails closed there and nothing spawns — see that unit.]
`feat/spoken-task-seeding/aliz`. Four aspects (the record aspect is this entry). Floor
**3000 → 3023** (executed 3023).

**What shipped, per aspect.**
*task-carrier* — **`ActionInvocation.taskText: String?`** (additive, default nil — the
`resolvedDirectory` precedent; every existing construction site compiles unchanged;
Foundation-free; **never `arguments`** — the gap-1 pin intact, `arguments` beside
`taskText` on an agent invocation still refused at `agent.unexpectedArguments`);
**`CodingAgentSentences.substitutedArguments(arguments:taskText:)`** — the pure
one-render substitution: **every** literal `taskPlaceholder` occurrence in the row's argv
replaced with the task text, describe and invoke sharing the one render (the argv that
runs is the argv the sentence showed — G2); the deterministic rule pinned by the
**two-placeholder acceptance**, an adjacent pair (`<task><task>`) that a split dropping
empty subsequences would collapse into one substitution — `omittingEmptySubsequences:
false` is the load-bearing half (Foundation-free by construction — the standard library's
own split/join); **`argumentsContainPlaceholder`** (public — one rule judged in one
place: the intent leg enriches exactly a placeholder-row tool, the surface arm refuses
exactly one); the **three loud refusals**, described at `outwardFacing` (never
de-escalated) and invoked at `.failed(reasonKey:)` with the engine never reached (engine
count 0): **`agent.taskHasNowhereToGo`** (a `taskText` with no placeholder in the argv —
the loud refusal, never a silent ignore), **`agent.taskTextMissing`** (a placeholder with
no `taskText` — reachable only by a hand-built invocation; the surface refuses earlier),
**`agent.taskTextTooLarge`** (over the bound, **refused never truncated** — the bound is
`ActionInvocation.maximumArgumentsUTF8Bytes` (4096, the `arguments` precedent); exactly
at the bound the substitution still runs; a long utterance never reaches the engine — the
turn falls through to the echo, R-A); the sentence's audit-summary bound applies naturally
(S1 — verified, never changed). Floor 3000→3009.
*utterance-threading* — the **driver widening**: the intent-action handler gains the
utterance — `intentActionHandler: @escaping @Sendable (ActionInvocation, String) async ->
String?` (the deliberate-widening precedent); the default closure updates to
`{ _, _ in nil }` — the unwired driver stays byte-identical; the driver's compile pins
updated deliberately (`ConverseLoopDriverTests`, `ConverseIntentStepTests`,
`IntentDriverIntegrationTests`). **The recorded deviation:** the plan's labeled spelling
— `(ActionInvocation, utterance: String)` — is **not expressible in Swift function
types**; the label lives at the closure's parameter site (`{ submitted, utterance in …}`),
never in the type. The call site passes the **cleaned utterance** verbatim
(`ConverseLoopDriver.swift:390` — in scope at the intent step, the honest change, never a
re-plumbing). **The enrichment** (`IntentWiring.performAction`): when the resolved tool is
an agent row whose argv carries the placeholder, the invocation is rebuilt with
**`taskText: utterance` — the FULL utterance, trigger words and all** (the critique
resolution: the audit records exactly what was said — "ask claude to summarize the open
PRs" seeds "ask claude to summarize the open PRs", never a stripped remainder); any other
tool is rebuilt with `taskText` nil — byte-identical to today; the row is read per call
(the per-turn registry read — a changed argv next turn is a new render, R-B). **The
pre-card refusal:** a placeholder row reached **without** an utterance is refused before
the card — the wiring's own stop (declined, recorded, never a card, never a run; the
spoken answer is the declined ack) — never the provider's refusal sentence asked of a
human (critique gap 2). **`WidgetConfirmationSignal.taskText`** (additive — the card
carries it; confirm/decline rebuild the invocation from the signal). **The surface-arm
refusal** (PRD R4): arming a placeholder row from the Actions tab refuses loudly before
any submission — `CodingAgentWiringError.placeholderRow`, the copy: "Arm refused: the
arguments still contain <task>. A placeholder row cannot run from the tab — its task is
filled by your spoken words in conversation. Replace <task> with a concrete task in the
arguments, or remove it." — nothing recorded as a run, never a card; the editor's
`<task>`-Save refusal unchanged. Floor 3009→3015.
*agent-pins* — the invariant suite (`SpokenTaskInvariantTests`), run inside the
zero-network interposer: **PROBE-CODING-AGENT verbatim-unchanged** with the unit's files
in the tree — the composed default still reads `agents=0 spawnsSubprocess=false` (a field
and a signature change nothing the probe drives); the lint tables' current state
re-asserted from the lint suites' own literals (the transport permitted set still exactly
the two reviewed entries, the FileManager seam table still exactly eight seams, Family A's
seven families and Family B's single minting file unchanged, the `policy:` parameter still
has no default — a field is not a file, no lint-table edit); the driver's compile pins
re-asserted from each file's own source (a reverted or re-widened signature fails here
first); the zero-network default-configuration drive green (the substitution happens only
in the provider over an invocation field — no new call); the module-coverage cross-check
unchanged at the twelve library modules (the unit added a field and wiring, **no module
files**). Floor 3015→3023 (executed 3023).

**The decisions.** **D1 — the full utterance seeds the task:** the trigger words stay in
the task — the audit records exactly what was said, and the sentence the human approved
is the sentence the run used (the binding covers it). **D2 — every occurrence
substitutes:** the deterministic rule pinned by the adjacent-pair acceptance; describe
and invoke share the one render (the sentence and the run cannot drift). **D3 — the
pre-card refusal:** a placeholder row without an utterance is declined and recorded
before any card — the wiring's own stop, never the provider's refusal asked of a human
(critique gap 2). **D4 — the surface refuses:** a placeholder row cannot run from the tab
(no utterance exists there) — the loud refusal at arm, before any submission; the
editor's Save refusal stays; the two paths cannot disagree because only the voice leg can
reach a placeholder row (R-C). **D5 — the driver widened deliberately:** the handler's
new parameter is the honest change (the utterance is in scope at the call site), with the
recorded deviation that Swift function types cannot spell the label.

**The deferrals, with their blockers.** **The editor checkbox** (this unit's N1 — a
surface affordance to create placeholder rows knowingly, the caption "filled by your
spoken task"): deferred — the file may carry placeholder rows hand-edited meanwhile, and
the editor still refuses `<task>` at Save by design. **`$N` parameter slots** (and the
`{{utterance}}` spelling): still deferred — an agent row declares no parameters; the
arguments-refusal pin stands; the spoken task rides the additive `taskText` field, never
`arguments`. **Interactive sessions**: unchanged — one-shot runs ship;
persistent-child/PTY machinery is unbuilt and does not fit the one-shot tool-call shape.

**The N1 retirement, named.** The `coding-agent-handoff` and `agent-presets` units
deferred N1 — "phrases arm rows, never task text" (`coding-agent-handoff` prd.md N1: the
phrase resolver produces no arguments and the gap-1 pin refuses them; `agent-presets`
prd.md N1: the `taskPlaceholder` is "never substituted"). This unit retires it:
**phrases arm rows AND the full spoken utterance fills the argv's `<task>` slot.** [In the shipped app this applies to the audit tools only;
a phrase naming a coding agent fails closed — see `converse-intent-wiring`.] What
stays: the editor's `<task>`-Save refusal (a surface row that means nothing must not
save) and the "never substituted" claim narrowed to the surface half — the file may carry
placeholder rows hand-edited, and the voice leg is the only path that fills one [not in the shipped app — see converse-intent-wiring: an agent phrase fails closed, nothing spawns; needs the provider-routing follow-up].

**No gate passes** (sixteenth unit ahead of the uncleared gates); the composed default
still reads `agents=0 spawnsSubprocess=false`; zero network; the dictation path
digest-untouched (the pin proves it). **G5 not re-anchored — the honest actual:** the
threading REFACTOR verified `AppBootstrap.swift` never shifted, so the pins recompute and
assert the prior unit's literal — the `AppBootstrap` digest stays `641b6445…`, the
dictation digests `1baeb2de…`/`ce70ca10…` unchanged. SMOKE 162 is **written and
runnable** — recorded, never gated; no task-seeding rate may be quoted. The record aspect
closed the docs sync: `CLAUDE.md`'s status paragraph, `CAPABILITY_ROADMAP.md`'s C13
amendment; **`ARCHITECTURE.md` untouched — a field and a signature changed no seam fact**
(the expected non-change, recorded).

---

**The `vocca-agent-id` rename shipped 2026-10-01 — the coding-agent provider's identifier
is `vocca.agent`, never `dev.vocca.agent`; a persisted-vocabulary rename, recorded.**

`CodingAgentProvider.providerID` and the VoccaUI-side mirrored constant
(`ActionsTabModel.agentProviderID` — the module-boundary agreement pin) changed from
`dev.vocca.agent` to **`vocca.agent`**; every test literal, source doc comment, the SMOKE
158 phrase-row example and `ARCHITECTURE.md`'s current-state row were renamed with it.
What this changes and what it does not:
- **New rows carry the new id.** Enablement rows the app writes, phrase rows the user
  writes, and audit entries recorded from now on name `vocca.agent`.
- **Historical rows keep the old id** — append-only honesty: audit entries already on
  disk, and any enablement row persisted before the rename, still say
  `dev.vocca.agent`. The config store tolerates stale ids, never prunes (the MCP
  precedent), so a leftover old-id enablement row is inert, not deleted; a user who had
  enabled an agent row before the rename re-enables it once. The founder's machine held
  no such rows at the time of the rename.
- **The `dev.vocca.shell` refusal is untouched** — the intent store refuses only the
  shell id; `vocca.agent` remains voice-reachable once enabled [not in the shipped app — see converse-intent-wiring: an agent phrase fails closed, nothing spawns; needs the provider-routing follow-up].
- Docs: `docs/STATUS.md`'s historical unit entries and `docs/planning/*` keep the old id
  as the record of what shipped then; `docs/SMOKE_CHECKLIST.md` and
  `docs/technical/ARCHITECTURE.md` (current-state instructions and tables) were synced.
- Floor unchanged (2956). The rename is byte-visible in the audit vocabulary's future
  rows, never in its past.

---

**The `coding-agent-handoff` unit shipped 2026-10-01 — C13 slice 9 (the P4 table's last
row): voice → a one-shot coding-agent run [not in the shipped app — see converse-intent-wiring: an agent phrase fails closed, nothing spawns; needs the provider-routing follow-up] with the active project as context, composed onto
the proven spine; no gate passes.**
`feat/coding-agent-handoff/aliz`. Six aspects (the record aspect is this entry). Floor
**2859 → 2916** (executed 2916).

**What shipped, per aspect.**
*agent-registry* — **`CodingAgentRegistry`** (`VoccaActions/Config/`) persists
**`coding-agents.json`** — definitions only, no enablement (enablement is membership in the
shared `ActionConfigStore`, providerID `dev.vocca.agent` + agent id):
`{id, executablePath, arguments, projectDirectory, timeoutSeconds?, environment?, clause?}`.
Shape-only, tolerant load / throwing save, atomic tmp+rename, byte pins; caps refuse never
clamp (16 agents, 64 KB, 128-char ids, 64 argv elements, 16 environment entries, 256-char
keys/values); a row over a cap is skipped loudly, never truncated. **No `readOnly` field** —
an agent is never read-only, `outwardFacing` for every row by construction (founder decision
Q4); a hand-edited file that grows the key is refused rather than read (byte-pin).
`executablePath` and `projectDirectory` must be absolute — no PATH, no `~` (MCP precedent;
**the configured project root is the "active project"**, founder decision Q2).
**`timeoutSeconds` defaults to 30, hard cap 600** (founder decision Q5). **The `environment`
field** (the planning refinement): explicit key/value entries — key material such as
`ANTHROPIC_API_KEY` lives in the file (the file is the trust surface); what reaches the
child's environment is exactly what the file says, nothing else (the executor scrubs). The
failable initializer refuses over-cap values. Floor 2859→2882.
*agent-execution* — **no new engine ships**: the agent child is the reviewed
**`ShellExecutor`** (fixed argv, never `/bin/sh -c`; the row's timeout over the injected
clock with the counted wait; terminate→poll→SIGKILL→poll reaping, never `waitUntilExit`;
no-orphan asserted `ESRCH` on a real child; bounded capture; scrubbed environment; stdin
`/dev/null`) — the provider resolves the row into a `ShellExecutor.Configuration`, so the
transport-permit lint **stays at exactly two files** (`StdioMCPTransport.swift`,
`ShellExecutor.swift`). This corrects the PRD's R8 phrasing, which had planned a third
reviewed entry: the execution work found none was needed — the engine was already reviewed,
already bounded, already reaped — and the D2 answer is the shell slice's, unchanged (an
*enabled* agent's egress is never provable; the agent child is the same blind hop). Floor
2882→2888.
*agent-provider* — **`CodingAgentProvider`** (`VoccaActions/Providers/`, actor, the
`ShellProvider` shape) — **the fifth real `ActionProvider`** (providerID `dev.vocca.agent`,
toolIDs fixed at construction, registry read once), describe and invoke sharing one
**argv-derived sentence** (`CodingAgentSentences`, one render — `Run the coding agent
'<id>': <executable> <argv…> in <projectDirectory>.`, the sanitised clause appended last;
the shell precedent: a planted argv appears verbatim, a clause cannot hide it), unknown row
refused at `.readOnly` (`agent.unknownTool`), **the arguments-refusal pin** (the gap-1 pin:
an agent row declares no parameters — `{{utterance}}`/`$N` are deferred (N1/N2) — so *any*
supplied arguments are refused at `agent.unexpectedArguments`, described at `outwardFacing`
never de-escalated), the injected engine closure (tests record without spawning), never
constructs a confirmation. Family A grows exactly **five rows** for the provider file (the
reviewed widening — the conformance's signatures force them) and **three rows** for the
wiring file. Floor 2902→2903.
*wiring* — **`CodingAgentWiring`** (`composeCodingAgentWiring`, the `ShellWiring` shape):
the Actions tab's **Coding agents** section (own-built rows from the registry — the "arm
surface is not generic" precedent — enablement folded from the shared store, default off,
absent is off, the **D2 copy** on the surface at the moment of arm: "Configuring a coding
agent runs it on your machine with your configured project; Vocca cannot see inside a
program it starts on your behalf — an enabled agent's egress is never provable"), the
policy floor **`.none`, recorded as a decision** (an agent is never read-only, so the
gate's own branch point already confirms every row), the in-flight arm refusal, the
re-render-after-record card, the `approvedSentence` binding with the mismatch re-prompt,
every decision recorded, **`spawnsSubprocess=false` declared for the configuration** (an
absent registry is zero rows — the default configuration cannot create an agent child), the
root slots `agentWiring`/`agentExecutor`/`agentRegistry` and the card-routing branch by
providerID in `AppBootstrap` — **G5 re-anchored once, deliberately** (`eba72eaf…` →
`092d8ba6…`, full literal
`092d8ba6671767932d0ba41d55f4eb29653196e8aa146631ceac38d06dc0af5b`, computed with shasum,
never edited-to-match; the dictation digests unchanged — `1baeb2de…`, `ce70ca10…`).
**The gap-3 stale-row reconcile** (the planning refinement): the per-call registry read
shows an edit on the tab while the provider's fixed tool list answers the read-only refusal
for the stale id — never pruned, never a trap. **The voice leg (voice-reachable [not in the shipped app — see converse-intent-wiring: an agent phrase fails closed, nothing spawns; needs the provider-routing follow-up], founder
decision Q4):** `IntentPhraseStore` is untouched — a phrase row naming `dev.vocca.agent`
resolves `.toolCall` once the tool is enabled (the store refuses only `dev.vocca.shell`);
phrases arm rows, they never carry task text (fixed argv, founder decision Q3). Floor
2903→2915.
*probe* — **PROBE-CODING-AGENT** inside the zero-network interposer:
`store=real store.location=temporary store.isDefaultLocation=false agents=0
spawnsSubprocess=false seeded=1 card=yes invoked=1 decisions=refused,confirmed,dryRun
ordinals=1-3 binding=matched` — every field an effect of the run: the composed default's
facts read off a wiring over an **absent** registry (the true first-launch default — nothing
is configured out of the box, D2), then a seeded round trip (`/bin/echo`, outwardFacing by
construction) through the real store, the real provider, the card and the surface's own
confirm, with the engine the real `ShellExecutor` behind a counting closure — the slice's
second route to a real child under the interposer, and the same D2 note: the line proves
the default cannot spawn, never that an enabled agent cannot egress. The guard-the-guard was
verified by planting a field and watching the pin fail, then reverting. Floor 2915→2916.

**Measured (recorded, never gated):** nothing was measured. The only figures are test
counts: **2916** executed through the floor script (`N == E`). No agent-success rate exists
and none may be quoted.

**The honesty block:**
- **No gate passes.** The thirteenth unit built ahead of the uncleared gates under the
  recorded posture. Demand: roadmap push, not demand pull. The P4 table's last row
  (`ROADMAP.md:239`) has shipped machinery, not a finished capability.
- **The "session" word, retired.** The roadmap says session; this slice ships **one-shot
  runs**. Interactive sessions are deferred with the blocker named: persistent-child/PTY
  machinery is unbuilt and does not fit the one-shot tool-call shape (R-C). An agent run's
  spoken answer comes back through the reply seam, whose real rendering is the separate
  remaining C13 item.
- **The D2 answer is unchanged, narrowed in writing.** The default configuration cannot
  create an agent child (absent registry = zero rows = `spawnsSubprocess=false`); an
  *enabled* agent's egress is never provable from inside Vocca, and the surface copy says
  where the claim stops. **The mayEgress question resolved as "copy is enough"**: no
  declared egress field — the provider carries no such fact, and the D2 copy carries the
  limit (an egress claim would be a promise no mechanism could keep).
- **The transport lint stays at exactly two files** — no third entry was needed because
  the agent engine is the reviewed `ShellExecutor`. This corrects the PRD's R8 phrasing,
  which had planned three.
- **R8 mitigated, not retired.** Every decision — confirmed, refused, dry-run — is
  recorded and reconstructs the action; the gate is the bound, never the classifier. **N2
  restated:** an approval asserts a human said yes and cannot verify it.
- **`{{utterance}}` seeding and `$N` parameter slots are deferred** (N1/N2) with their
  blocker: the phrase resolver carries no arguments, and an agent row declares no
  parameters — the arguments-refusal pin is the shipped record.
- **Time-boxed and decaying per-tool trust** (§8) remain decided-and-deferred with their
  blockers (persisted trust state, changed approval semantics, M4a).
- **SMOKE 157-159 are written and runnable** — recorded, never gated, executed by nothing
  in CI. They record whether the sentence, the run, the timeout and the reconstruction
  held, never a rate; **no agent-success rate may be quoted until a real run exists** (the
  rows' precondition: a real agent row configured in `coding-agents.json` with an absolute
  executable path + env).

**The `agent-presets` unit shipped 2026-10-01 — C13 slice 10: the authoring surface —
rows are authored in-app (a catalog, detection, and the editor), the first slice that
makes the agent arm reachable without touching a file; no gate passes.**
`feat/agent-presets/aliz`. Five aspects (the record aspect is this entry). Floor
**2916 → 2956** (executed 2956).

**What shipped, per aspect.**
*agent-catalog* — **`KnownAgentPresets`** (`VoccaActions/Config/`): the code-level seed,
**exactly eight** presets pinned verbatim by `KnownAgentPresetsTests` (the
`EngineCandidate`/intent-synonym precedent — a reviewed edit, never a runtime discovery),
each `{id, displayName, candidateNames, arguments}`: claude `["-p", "<task>"]`, codex
`["exec", "<task>"]`, gemini `["-p", "<task>"]`, opencode `["run", "<task>"]`, aider
`["--message", "<task>"]`, cursor `["run", "<task>"]`, q (Amazon Q) `["-p", "<task>"]`,
and **crush — the eighth, reviewed in during planning** (Q1: the wider catalog). The
**`taskPlaceholder`** constant = `<task>` — a *string the editor pre-fills and the user
may edit*; **never substituted this slice** (N1 stays deferred), so a template can never
be executed as a substitution, and the pin asserts one placeholder occurrence per
template. Pure data: no file system, no transport, no runtime behaviour — the composed
default's `spawnsSubprocess=false` is untouched by the catalog's existence. Floor
2916→2923.
*agent-detection* — **`AgentCLIDetection`** (`VoccaActions/Config/`): the pure resolver
over the **injected `ActionConfigFileSystem.fileExists` seam** — no new
FileManager-naming file, no lint-table edit; `AgentDetection = .detected(path:) |
.notDetected`, first existence wins in the pinned order. Per preset, per candidate name:
(1) the **candidate path list — the MVP cap**: `/opt/homebrew/bin`, `/usr/local/bin`,
`/usr/local/sbin` — the spec's `~/.local/bin`, `~/.cargo/bin`, `~/.nix-profile/bin`
**kept out**: expanding `~` needs a home directory the seam exposes none of, and naming
the file system to find one would be a lint-table widening (a home-injecting widening is
a reviewed edit when the seam grows a home accessor); (2) **the PATH leg shipped** — the
injected PATH string split on `:`, **absolute components only** (empty, relative and
`~`-prefixed components are skipped, never checked); a `~`-prefixed entry can never join
the list. Detection spawns nothing, versions nothing — the honest fact is **exists-at-
path only**, and the surface copy says exactly that ("Detected — <path>"; R-A: a stale,
wrong-arch or signed-out binary still says Detected, and the run's failure is a loud
returned value, never a detection lie). Runs on section open (Q3). Floor 2923→2931.
*agent-authoring* — the row editor and the save path: **`SettingsBindings`** gains
`loadAgentPresets`/`detectAgents`/`loadAgentDefinitions`/`saveAgents` (no-op defaults,
the bindings doctrine); `AppBootstrap.showSettings` fills them from the catalog, the
detection resolver and `agentRegistry`. **The module-boundary deviation, deliberate and
recorded:** `VoccaUI` cannot import `VoccaActions` types, so the tab speaks the plain
`ActionsAgentFile` and **`AppBootstrap.agentFile(from:)`** translates at the root — the
`ActionsConfigDraft` precedent; the shipped `saveAgents` binding and the authoring
round-trip suite drive the same mapping, and a row that still fails the registry's
contract is a refused save (`CodingAgentAuthoringError.invalidRow`), never a silently
dropped row. The reducer gains the Servers-editor pattern: the drafts
(id/executablePath/arguments/projectDirectory/timeoutSeconds/environment pairs/clause),
`editingAgentID`, `.agentEditorOpened(presetID:)` — **a preset pick pre-fills the full
row editor** (Q2), blank option included — `.agentDraftFieldEdited`,
`.agentSaveRequested`, `.agentEditStarted`/`.agentEditCancelled`, `.agentRemoved(id:)`
(the enablement row goes with it, on both halves), the stable UUID minted once (an edit
never looks like delete-plus-add), `saveSucceeded`/`saveFailed` (failure loud, draft
kept). **Validation before save**, the definition's own init rules: the **duplicate-id
refusal** (the registry's first-wins would silently skip — the editor refuses loudly,
naming the id), and **the `<task>`-placeholder Save refusal** (the critique-gap
resolution: a save whose argv still carries the placeholder is refused with the loud
copy — "a row that means something cannot save a placeholder" — at Save, never at
confirm; the honest-sentence principle). **Edit/remove SHIPPED** (S1 — rides the same
editor, `agentRow`'s edit button and the remove with the enablement cascade); the
**remembered project directory ships in-memory** (S2; persistence deferred). **G5
re-anchored once, deliberately in this aspect's REFACTOR** (`092d8ba6…` →
`c7d6767c…`, full literal
`c7d6767c8b3fbfbfbcbc9dd2fb1e7c5d2d6cc277c55febaf82dd1447adef1aa69b`, computed with
shasum, never edited-to-match; the dictation digests unchanged — `1baeb2de…`,
`ce70ca10…`). Floor 2931→2949.
*agent-pins* — the invariant suite (`AgentPresetsInvariantTests`): **the
PROBE-CODING-AGENT post-condition is unchanged** — `agents=0 spawnsSubprocess=false`,
the drive and its expected lifecycle constant verbatim, the guard-the-guard verified;
the saved-row round trip through the **composed** wiring (a row written through the
editor's save path renders through `listAgents`, enablement default off); **lint
immobility** — the transport permitted set still exactly the two files, the FileManager
seam table still exactly the eight seams, Family A/B and the `policy:` no-default call
sites unchanged; the catalog and detection **do nothing by themselves** (over a recording
seam: exactly the 24 existence checks and nothing else — no file written, no spawn, no
network); the G5 digests recomputed with the authoring REFACTOR's re-anchored literal.
Floor 2949→2956.

**Measured (recorded, never gated):** nothing was measured. The only figures are test
counts: **2956** executed through the floor script (`N == E`). No agent-success rate
exists and none may be quoted.

**The honesty block:**
- **No gate passes.** The fourteenth unit built ahead of the uncleared gates under the
  recorded posture. This slice makes the C13 surface authorable; it does not make any
  agent run.
- **The detection facts are existence facts only** — never a version, never "ready to
  run". A detected binary may be stale, wrong-arch, or require sign-in (R-A); the copy
  says where the claim stops and the run's failure is the loud returned value the parent
  unit shipped.
- **The preset argv templates are seeds, pinned verbatim** — never a claim about the
  CLI's real behaviour (R-B); a retune is a reviewed edit to `KnownAgentPresets.swift`,
  and the form lets a user fix argv per row without a code change.
- **The editor and the hand-edited file stay one file** (R-C): the editor writes the
  same `coding-agents.json` the tolerant loader reads, through the same registry; no
  second store; load is per-call, so a hand-edit shows up on next open and the byte pin
  is unchanged.
- **Deferrals, with their blockers.** N1 `{{task}}` substitution (the placeholder is a
  string the editor pre-fills; a template can never be executed as a substitution — the
  parent's `{{utterance}}`/`$N` deferral unchanged); **persisted last-project** (the
  in-memory remember ships; persistence is a later call); the **re-detect affordance**
  (N2 — detection runs on section open; a refresh after installing a CLI is a later
  call); **tilde paths** pending a home accessor on the file-system seam.
- **R8 mitigated, not retired** — unchanged from the parent: every decision is recorded
  and reconstructs the action; the gate is the bound, never the classifier.
- **SMOKE 160 is written and runnable** — recorded, never gated, executed by nothing in
  CI. It records whether the detection facts, the pre-fill, the save refusals, the
  rendered row, the run and the reconstruction held on the founder's machine, never a
  rate.
- **ARCHITECTURE.md was not touched**: no new seam ships, no lint widens — the
  `VoccaActions`→`VoccaUI` mapping (`AppBootstrap.agentFile(from:)`) is a binding fact,
  not a seam, and the seam tables already record the agent surface this slice rides.

**The `phrase-intent-resolver` unit shipped 2026-09-25 — C13 slice 8 (the intent layer's S1):
the second real `IntentResolver`, the user's own phrase table, and the N1 flip of the composed
default; no gate passes.**
`feat/phrase-intent-resolver/aliz`. Five aspects (the record aspect is this entry). Floor
**2859** (executed 2859).

**What shipped, per aspect.**
*phrase-resolver* — **`PhraseIntentResolver`** + **`PhraseIntentRow`** (`VoccaCore/Intent/`,
Foundation-free): exact matching under one public `normalized(_:)` (lowercased, every run of
non-letter/digit characters collapsed to one space, trimmed). The first row in table order
whose normalized phrase equals the utterance **and** whose tool is in the caller's catalog
resolves to `.toolCall` with **no arguments**; everything else is `.none`. It **never asks**:
an equality has no confidence gradient, so brittleness ("clear audit log" ≠ "clear the audit
log") fails to *nothing*, never to a wrong tool. The contract suite's shared rows run over it.
Three seam lints (intent, action, converse) were widened in GREEN rather than REFACTOR, because
the suite must be green at GREEN. Floor 2825→2836.
*phrase-table-store* — **`IntentPhraseStore`** (`VoccaActions/Config/`, an actor) persists
**`intent-phrases.json`** as `{"version":1,"phrases":[{phrase, providerID, toolID}]}`.
Shape-only: no enablement, no arguments, no timestamp. It has a byte-level pin.
- **Loading:** an absent file is quietly empty. An unreadable file, a wrong-shape file, a wrong
  version or an oversize file is loudly empty, with exactly one log each. Loading never writes.
- **Rows:** judged one by one with `JSONDecoder` and a lossy per-row wrapper. `"toolID": 1` and
  `"version": true` are refused, never coerced (the F1 lesson). Empty or over-cap fields,
  phrases with no words and duplicate normalized phrases (first wins) are each skipped with one
  log. The duplicate check uses the resolver's own `normalized`.
- **The shell refusal at load:** a row naming `ShellProvider.providerID` is refused loudly, so
  the voice leg can never reach a shell command however the file is edited, and Core never
  learns a provider id.
- **Caps refuse, never clamp:** 256 phrases, 64 KB, 256-char phrases, 128-char ids.
- **Saving:** atomic tmp+rename with sorted keys.
- Logs name the file and the row index, never a phrase's text.

Floor 2836→2852. One RED fixture was corrected in GREEN: the byte-cap save row's table was
under the cap it meant to exceed.
*wiring* — `composeIntentWiring(…, resolverProvider:, …)`: the resolver is obtained **once
per resolution, never at composition**. The catalog is still built first from the enablement,
and the fixed-`resolver:` form forwards, so every existing call site is unchanged. **The N1
flip, made deliberately:**
- `AppBootstrap` composes a provider that loads the real `IntentPhraseStore` and builds a
  `PhraseIntentResolver` each turn.
- The root's fact carrier became `intentResolverProvider`, the same closure. The probe calls it
  and reflects the type.
- The intent-default guard and the `NullIntentResolver` lint row refused the flip until edited
  in GREEN, as designed.

The safety rows: composition consults the provider zero times; a file edit takes effect on the
next turn with no recompose; a phrase-resolved **destructive** call is refused **by attempting
the call** (card presented, `invokeCount == 0`, `refused` recorded); a phrase naming a tool with
no enablement row touches nothing; a shell phrase resolves `.none` **even with the command
enabled**. The §8 floor is extended: `EscapeValveTests` runs the full approval × policy × mode
enumeration over a `PhraseIntentResolver`-built outward-facing invocation. **G5 re-anchored
once, deliberately in REFACTOR** (`e9aa45bb…` → `eba72eaf…`, computed with shasum, never
edited-to-match). The dictation digests are unchanged (`1baeb2de…`, `ce70ca10…`).
`NullIntentResolver` stays shipped: it is the resolver a composition wires to switch the voice
leg off. Floor 2852→2858.
*probe* — **PROBE-INTENT-DEFAULT** now reads `resolver=PhraseIntentResolver resolves=1
intentResolved=0 spawnsSubprocess=false intentShellRows=0`. `intentShellRows` now also counts
the table the composed default was built over; it stays 0 on any machine, because shell rows
are refused at load. **PROBE-INTENT-PHRASE** is new: `store.location=temporary
store.isDefaultLocation=false phrases=1 resolved=1 card=yes invoked=1 shellRefused=1`. It runs
a real temp `intent-phrases.json` whose shell row is written as raw bytes (a hand-edit, the
threat) through the real store, the real resolver, the composed recipe, the card and the
surface's own confirm, inside the zero-network interposer. Every field is an effect of the run.
The guard-the-guard was verified by planting `shellRefused=0` (fails), then reverting. The
planning correction is recorded: `phrases=` moved off the default line because the composed
root reads the **real** Application Support directory, so a count there would depend on whose
machine ran the probe. G5 did not move. Floor 2858→2859.

**Measured (recorded, never gated):** nothing was measured. The only figures are test
counts: **2859** executed through the floor script (`N == E`). No resolution rate exists and
none may be quoted.

**The honesty block:**
- **No gate passes.** The twelfth unit built ahead of the uncleared gates under the
  recorded posture. Demand: roadmap push, not demand pull. No user asked for this slice.
- **The unwired posture narrowed, in writing.** Since this unit, **the shipped configuration
  can voice-act** [corrected 2026-10-04: the leg is not wired into the shipped converse path — see composite-intent-resolver] [resolved 2026-10-08 by converse-intent-wiring: the leg is wired; phrase rows over the audit tools act by voice, a phrase naming a coding agent does not yet], after a two-step opt-in: the user writes a phrase **and** enables its tool.
  With neither, it resolves nothing (`intentResolved=0`), exactly as the null default did.
- **Guardrail 7 for the intent seam: two real classifiers, not composed together.** The D3-shaped
  caveat is retired: `KeywordIntentResolver` and `PhraseIntentResolver` are both real. Only the
  phrase resolver is in the shipped default; nothing composes the keyword resolver, and a
  phrase-then-keyword composite is a later slice.
- **R8 mitigated, not retired.** A phrase is the user's own declaration, so a
  wrong-but-confident resolution is less likely than with keywords, but it is still bounded by
  the gate, not the classifier. **N2 restated:** an approval asserts a human said yes and cannot
  verify it.
- **Shell stays arm-surface-only.** Refused at load, asserted in unit tests, in the composed
  wiring (enabled command, still `.none`) and in the probe (`shellRefused=1`,
  `intentShellRows=0`).
- **F-A: the audit tools are not enable-able from the surface.** The Actions tab renders tool
  rows only from MCP discovery (unwired) and the shell section. In the shipped app, the only
  tools the voice leg can reach are `dev.vocca.audit/*`, and enabling them means hand-editing
  `action-config.json`. An audit arm section is a follow-on slice.
- **F-B: SMOKE 148's gesture was not performable as written** ("enable `audit.clear` in the
  Actions tab" named a row that does not exist). Corrected in place, with the original wording
  kept and the correction dated.
- **F-C: `KeywordIntentResolver.jsonEscaped` emits `\u{XX}` for control characters, which is
  not valid JSON** (JSON wants `\u00XX`). Recorded, not fixed: the keyword resolver is pinned
  code, and the fix is its own reviewed edit. It is unreachable in the shipped default, since
  the keyword resolver is not composed.
- **Exact match is brittle against ASR/cleanup drift**, by design. How often a real utterance
  survives cleanup to equal a written phrase is unmeasured until SMOKE 154-156 run. Those rows
  are written and runnable, recorded and never gated, and executed by nothing in CI. They record
  attempt counts, never a rate.
- **Diacritics are not folded** ("café" ≠ "cafe"). Recorded.
- **CI findings on PR #48:**
  - **Master had been red since PR #46** (intent-layer, 2026-09-22) on the strict-concurrency job:
    six `no 'async' operations occur within 'await'` warnings in `ConverseIntentStepTests.swift`
    (`await handler.calls` / `await provider.calls` on plain classes). The job fails on any
    warning. Local runs never showed it, because the local toolchain and incremental builds did
    not emit the warning. Fixed test-only in this PR (`ci:` commit), since it blocked the merge.
    It isn't this unit's own work.
  - **A flake, not fixed:** in one of the two CI runs of the same commit, Bundle contract (Debug)
    failed `DictationPipelineTests.testEveryRowOfTheDecisionTableFinalizesExactlyOneRecord`. The
    "cancelled before transcribe" row recorded an `asr` span and engine attribution. The same
    job passed in the other run, Release passed, and it passed locally, so it is
    timing-dependent. It is on the dictation path, which this unit doesn't touch (digests
    unchanged). Recorded for a later deterministic fix, in the manner of the re-warm flake fix.
- **Process note:** the session that planned and built this unit had no subagent tool, so the
  "agents team" fan-out the pipeline prescribes ran serially in the main thread, strictly
  test-first (RED → GREEN → REFACTOR per aspect). The phrase-table-store aspect has no REFACTOR
  commit: its planned content (the lint widening) had to land in GREEN.

---

**The `shell-provider` unit shipped 2026-09-22 — C13 slice 7: the shell command provider —
the roadmap's highest blast radius, the first provider whose radius is unboundedly
destructive, composed onto the proven spine with the argv-derived sentence and the
arm-surface-only shell leg; no gate passes.**
`feat/shell-provider/aliz`. Six aspects (the record aspect is this entry). Floor **2825**
(executed 2825).

**What shipped, per aspect.**
*command-registry* — **`ShellCommandRegistry`** (`VoccaActions/Config/`:
`ShellCommandDefinition`, `ShellCommandParameters`), the persisted **`shell-commands.json`**
(definitions only, `<applicationSupport>/Vocca/`, byte-pinned): tolerant decode — absent,
corrupt or unknown-key files load as the empty registry with one loud log, never a throw —
atomic temp-write-rename, and the caps **refuse, never clamp** (64 commands / 64 KB — seeds,
a retune is a reviewed edit); invalid rows are skipped loudly (duplicate id, empty argv,
over-long id); **`readOnly` absent → `false`** — a command whose file does not declare
`readOnly: true` claims the destructive radius, the MCP "absent means unsafe" precedent; the
file is shape-only, never enablement and never argument values (enablement is membership in
`ActionConfigStore`, argument values travel only at call time). The F1-lesson test:
`testABooleanConfusionCannotClaimReadOnly` — Swift's `JSONDecoder` **refuses `1` for `Bool`**
(no NSNumber collapse), so a corrupt file is refused whole rather than read as claiming
read-only. Floor 2761→2780.
*provider-widening* — the transport prohibition lint's permitted set grows from **exactly
one** file (`VoccaActions/MCP/StdioMCPTransport.swift`) to **exactly two** (adds
`VoccaActions/Execution/ShellExecutor.swift`, pending at the time): the new exact-set pin,
a **pending-entry-recording test** (fails the day the file lands — the author's job to
retire it, retired by its author in the execution GREEN as designed), and a
planted-third-file control. **The D2-for-shell answer is recorded in the doc**: a shell
child is even *less* observable than an MCP child — the same blind hop with a shell in
front of it, and the restricted child purges `DYLD_INSERT_LIBRARIES` from the environment
it passes on — so the claim narrows in writing exactly as it did for the transport: **the
default configuration cannot create a shell child**. Floor 2780→2783.
*execution* — **`ShellExecutor`** (`VoccaActions/Execution/`, + `ShellExecutionResult`):
the **fixed argv** runs via `Process` — never `/bin/sh -c`, so the child is not hidden
behind a shell of our own making; the 30 s ceiling over an injected `MonotonicClock` with a
**counted** wait (`maximumPolls` budget — a frozen clock cannot hang the suite);
terminate→poll→SIGKILL→poll reaping, **never `waitUntilExit`** (the recorded deadlock);
bounded 4 KB output capture; exit-code mapping to the bounded `shell.*` reason keys; a
scrubbed environment; failure as **returned values, never throws**. The no-orphan
acceptance asserted `kill(pid, 0) == -1 && errno == ESRCH` on a real child — a **zombie
answers `kill(pid, 0)` successfully**, so ESRCH is the only honest answer. Deviations
recorded: `/bin/false` → `/usr/bin/false` (platform reality), the lint's pending-entry test
retired by its author as designed, and the `asActionOutcome()` fold deferred to the
provider (`ActionOutcome` is Core-only). Floor 2783→2792→2793.
*provider* — **`ShellProvider`** (`VoccaActions/Providers/`, + `ShellProviderSentences`),
`providerID = "dev.vocca.shell"`, nonisolated `toolIDs` fixed at construction; **describe
derives the concrete sentence from the argv** (founder decision): `Run the shell command
'<id>': <argv, values substituted in place, quoted-sanitised>; <key = value pairs, sorted>.
<clause>` — a planted argv appears verbatim and a clause cannot hide a different argv; the
shared rendering between describe and invoke means the sentence and the argv **cannot
drift**. Destructive by default (`readOnly` absent → `.destructive`); unreadable/missing
parameters describe as a refusal **keeping the radius**; unknown command → refusal value.
The C13 load-bearing acceptance asserted at the gate level: a destructive invocation
without approval is `.confirmationRequired` **by attempting the call** — the engine
provably never reached, its call log empty. The five Family-A rows. Floor 2793→2814.
*wiring* — **`ShellWiring`** (VoccaBootstrap) and the composition-root routing
(arm/preview/confirm/decline by the card's providerID). **The step-1 finding, recorded:
the arm surface is NOT generic** — tool rows exist only from `discoverySucceeded`
(`ActionsTabState.swift:28-30,226-236`), and the shipped discovery is the bounded
`discovery.unwired` refusal keyed by server id, so an enablement row alone renders nothing.
The shell leg therefore builds its own section: the registry's commands rendered as the
existing `ActionsToolRow`s (radius from the file's claim, enablement folded from the shared
store, default off) with the D2 copy — *"Configuring a shell command runs that command on
your machine; Vocca cannot see inside a program it starts on your behalf."* Unwired default:
with no registry and no enablement, **nothing spawns**. `AppBootstrap` grew → **G5
re-anchored deliberately in REFACTOR** (`ecfcdb4b…` → `e9aa45bb…`, computed with shasum,
never edited-to-match; the dictation digests unchanged). S3 per-command overrides deferred.
Floor 2814→2822→2824.
*probe* — **PROBE-SHELL**, the composed shell drive inside the zero-network interposer
(`ShellDrive`, `exerciseShell`, module coverage):
`store=real store.location=temporary store.isDefaultLocation=false commands=0
spawnsSubprocess=false seeded=1 card=yes invoked=1 decisions=refused,confirmed,dryRun
ordinals=1-3 binding=matched` — every field an effect of the run: the real store in a temp
directory, the composed default's `commands=0`/`spawnsSubprocess=false` read off the run,
the seeded registry's own answer, the gate's card, the engine's own call log (the confirm
runs the child exactly once, the dry-run row reaches it zero times), the ordinals rebuilt
from the directory, and the binding to the card's shown sentence. **PROBE-INTENT-DEFAULT
gained `intentShellRows=0`** — the resolver-catalog fact: no `dev.vocca.shell` row in the
shipped synonym table, the arm-surface-only decision asserted (the voice leg has no learned
phrase that could ever resolve to a shell command). The guard-the-guard pair refuses
weakened constants (planted `commands=1` / `spawnsSubprocess=true` fail loudly). G5 did not
move again (digests verified). Floor 2824→2825.

**Measured (recorded, never gated):** nothing was measured. The only figures are test
counts: **2825** executed through the floor script (`N == E`). No percentage exists — in
particular no shell-execution or refusal rate — and none may be quoted.

**The honesty block:**
- **No gate passes.** The eleventh unit built ahead of the uncleared gates under the
  recorded posture.
- **R8 is amplified — the first provider whose blast radius is unboundedly destructive.** A
  shell command can delete, modify or egress anything the user can; the mitigation is the
  proven spine, not a new mechanism — the structural refusal by attempting the call, the
  argv-derived sentence, dry-run, and every decision recorded. **N2 is stated:** an approval
  asserts a human said yes and **cannot verify it**; the binding narrows what an approval
  can be replayed against and the seeing is asserted by the UI layer.
- **D2 stands, now with a shell in front of the child.** A shell child is not observable by
  the zero-network interposer — the same blind hop as the stdio child, with a shell in front
  of it, and the restricted child purges `DYLD_INSERT_LIBRARIES`. The transport widening's
  answer is recorded: the claim narrows in writing — **the default configuration cannot
  create a shell child**; the probe proves the default cannot spawn, **never that an
  enabled command cannot egress**. The D2 copy says where the claim stops, on the surface.
- **The sentence is argv-derived, by founder decision.** The shared describe/invoke render
  means the sentence and the argv cannot drift; the sentence is what a human was shown and
  what the binding is against — a clause cannot hide a different argv.
- **Arm-surface-only.** Shell is composed onto the action surface only; the intent seam has
  no `dev.vocca.shell` row (`intentShellRows=0`, asserted by the probe). The voice leg
  cannot resolve to a shell command this slice.
- **The classifier's accuracy is unmeasured** (unchanged from the intent-layer record) — no
  resolution rate exists and none may be quoted.
- **No SMOKE rows executed.** Steps 151-153 are **written and runnable** — recorded, never
  gated, executed by nothing in CI; no rate is ever recorded.
- Floor **2825** (executed 2825).

**The `intent-layer` unit shipped 2026-09-22 — C13 slice 6: the intent layer — the voice leg
of the action surface: the utterance pipeline gains an intent step, a guess never executes,
and the §8 escape-valve decision is made and pinned; no gate passes.**
`feat/intent-layer/aliz`. Five aspects (the record aspect is this entry). Floor **2761**
(executed 2761).

**What shipped, per aspect.**
*intent-seam* — the seam in **`VoccaCore/Intent/`** (Core vocabulary, Foundation-free — the
empty import allow-list holds, no new module): `IntentResolution`
(`.toolCall(ActionInvocation)` / `.ask(question:)` / `.none`), the `IntentResolver` protocol —
synchronous, deterministic, `Sendable`, resolving a cleaned utterance against a
caller-supplied catalog (R3: the resolver never reads enablement; the wiring supplies only
enabled tools) — and `ToolReference` (providerID/toolID/displayName). **`KeywordIntentResolver`**,
the first real classifier: token-scored matching (matched ÷ candidate tokens over displayName +
toolID + seeded phrases, camelCase-aware Foundation-free tokenization, stop words), the seeded
**not-confident threshold 0.75** below which resolution is `.ask` — the spoken question names
the resolver's own top ≤3 candidates in score-then-lexical order, never a tool the matcher did
not rank — and the seeded synonym table: the two audit rows ("clear the audit log" →
`dev.vocca.audit/audit.clear`, "count the audit log" → `audit.count`) plus the args-carrying
agent-A row ("post a message" → `dev.vocca.mcp.chat/post_message` with
`{"text": "{{utterance}}"}`), the arguments built over the whole cleaned utterance and refused,
never truncated, at the 4 KB construction bound. **`NullIntentResolver`**, the composed default
— `.none` for every utterance. The `IntentSeamBoundaryTests` family lint (the six intent
families confined to the seam files, non-vacuous guards, planted-violation and comment-strip
controls) and the **seed pin**: the shipped rows verbatim, the row count (3), the threshold and
the `{{utterance}}` placeholder — a retune of a wrong seed is a reviewed edit, exactly as R8
records.
*converse-step* — `ConverseLoopDriver` widened to **fourteen parameters**, the frozen-signature
compile pin widened deliberately (the reviewed-edit mechanism): the two lazy closures in the
`asrProvider`/`cleanupProvider` shape — `intentProvider: (String) async -> IntentResolution?`
and `intentActionHandler: (ActionInvocation) async -> String?` — both defaulting to nil, the
unwired answer, today's echo behavior byte-identical. The pipeline branch between clean and
reply: `.ask` speaks its question and **nothing executes** (a guess never runs — the ask path
precedes any provider call); `.toolCall` speaks the handler's reply (a silent nil handler falls
through — the honest-drop channel); `.none`/nil reproduce the reply generator byte-for-byte.
The bounded re-ask: a per-session counter, a question spoken while the count is below the bound
— **exactly the first `.ask` of a run is spoken, a second consecutive one falls through to the
echo**, reset on any non-`.ask` outcome. `ConverseTurnFailure` untouched (failures are returned
values); `composeConverseWiring` passes the closures through at their nil defaults.
*action-round-trip* — **`IntentWiring<Provider>`** (VoccaBootstrap) and the additive recipe
`composeIntentWiring(configStore:provider:executor:resolver:root:)`: the catalog is the
**enablement, never-read** (the same `loadEnablement()` rows the Actions tab edits — a disabled
tool is never resolved to, never described, never called, M7 extended to the intent step); the
action leg submits through the **shared** `root.actionExecutor` with
`approval: .withheld, approvedSentence: nil, mode: .live` — the voice path never pre-grants; on
`.confirmationRequired` the card is presented with the sentence **re-rendered after the record**
(the count-bearing precedent) and a **fresh generation token**; the **card-up guard** (a second
voice action while a card is up refuses to present — read lazily from the store, records
nothing); the spoken acks derived from the terminal decision — confirmed → "Done.", an outcome
failure → "Something went wrong.", declined → "Cancelled.", refused/not-invoked → silent — and
a decision with `auditRecorded == false` answers with the bounded failure copy ("Something went
wrong — the action was not recorded."), **never a success ack**. The policy floor `.none` is
inherited and recorded (the `ActionWiring.swift:203` decision). **The §8 floor is pinned**:
`EscapeValveTests` names `BlastRadius.requiresConfirmation` by name (`BlastRadius.swift:56-63`)
and enumerates every approval × policy × mode shape — an outward-facing invocation never
auto-runs — plus the raising-floor leg, the escalation that can only ever raise.
`AppBootstrap.configure` composes the voice path over the **same** `AuditActionProvider`
instance the surface's executor was built over (the re-render's describe source) and the
composed default's `NullIntentResolver`, with new nullable root slots (`intentWiring`,
`intentResolver` — the probe's fact carrier).
*probe* — **PROBE-INTENT**, the voice round trip inside the zero-network interposer over probe
doubles (real temp-directory stores, a call-logged probe provider, the **real**
`KeywordIntentResolver` over a probe-seeded synonym table, the existing confirm/decline
closures as the human leg): `store=real store.location=temporary store.isDefaultLocation=false
resolved=1 card=yes invoked=1 decisions=refused,confirmed ordinals=1-2 binding=matched`; and
**PROBE-INTENT-DEFAULT**, the composed default's facts read off the root `configure` built —
the fact carrier's own dynamic type: `resolver=NullIntentResolver resolves=1 intentResolved=0
spawnsSubprocess=false`. The guard-the-guard pair reads the constants back field by field and
refuses a version that no longer describes the composed round trip or the composed default; the
wiring-family lint gained the intent families' rows and the pinned-dictation-files
never-name-intent leg. **G5 re-anchored exactly once, deliberately**: `AppBootstrap.swift`
`aa12c723…` → `ecfcdb4b…` — computed, never edited-to-match; `SessionMachine.swift` and
`DictationPipeline.swift` digests unchanged, asserted by the pin.

**Measured (recorded, never gated):** nothing was measured. The only figures are test counts:
**2761** executed through the floor script (`N == E`). No percentage exists — in particular no
resolution rate — and none may be quoted.

**The honesty block:**
- **No gate passes.** The tenth unit built ahead of the uncleared gates under the recorded
  posture.
- **R8 is mitigated, not retired — and the voice leg is the first path by which a spoken
  sentence can cause an action.** The mitigation is the existing round trip made reachable from
  voice — the gate's structural refusal, the sentence binding, every decision recorded — plus
  the new "a guess never executes" property: the ask path precedes any provider call. **N2's
  limit is stated:** an approval asserts a human said yes and **cannot verify it**; the binding
  narrows what an approval can be replayed against, the seeing is asserted by the UI layer, and
  the classifier's wrong-but-confident failures are bounded by the gate, not by the classifier.
- **The classifier's accuracy is unmeasurable in CI.** The not-confident threshold and the
  synonym table are seeds — the founder's invention until SMOKE 148-150 run (env-gated, the
  ASR-WER precedent). The tuning path is code-level: a retune of a wrong seed is a reviewed edit
  to `shippedSynonyms` (pinned verbatim) until S1's `PhraseIntentResolver` lands the
  user-editable table. SMOKE 150 records utterance counts (resolved/asked/missed), never a rate.
- **The D3-shaped guardrail-7 claim, stated honestly.** The seam ships with
  `KeywordIntentResolver` + `NullIntentResolver` — one *real* classifier plus a shipped default,
  the slice-1 D3 shape (a shipped default is not a second implementation). S1
  (`PhraseIntentResolver`) is the retirement path, still should-have.
- **The two-mint observation.** The intent recipe and the action surface's recipe each own a
  **private generation mint** (`IntentGeneration` / `ActionWiring`'s). Harmless: the store's
  stale-card guard compares within a mint — pairwise — and the sentence binding is the backstop
  across the surface boundary; a token minted by one recipe is never compared against the
  other's.
- **D2 stands; the sequencing is recorded.** The G5 re-anchor landed in the probe REFACTOR
  commit as the plan scheduled it (probe plan Phase D3), so the GREEN phase's validation run
  carried the **one anticipated pin failure** — the digest moved before the re-anchor commit,
  exactly as planned; the re-anchor was computed, never edited-to-match, and the dictation
  digests are unchanged.
- **The spoken-ack copy is provisional.** "Done." / "Cancelled." / "Something went wrong — the
  action was not recorded." are provisional text pending the founder's real run (SMOKE 148-149);
  what is pinned is the derived-from-decision shape, not the words.
- **No SMOKE rows executed.** Steps 148-150 are **written and runnable** — recorded, never
  gated, executed by nothing in CI.
- Floor **2761** (executed 2761).

---

**The `action-surface-wiring` unit shipped 2026-09-21 — C13 slice 5: the Actions surface —
the first human-in-the-loop safety surface, composed and probe-driven; the "nothing is
wired" sentence retires; no gate passes.** `feat/action-surface-wiring/aliz`.
Six aspects. Floor **2710** (executed 2710).

**What shipped, per aspect.**
*sentence-binding* — N2's tightening, reserved since slice 1 for "when a surface exists":
`ActionGate.submit` gained the additive `approvedSentence: String? = nil`. A granted
approval binds to the exact sentence the human was shown; a drift between show and confirm
is refused **by attempting the call** — `.declined(.approvedSentenceMismatch)`, the
provider's `invoke` called zero times, the new bounded key spelled
`gate.approvedSentenceMismatch`. `nil` keeps every existing call site byte-identical (the
F2 precedent: `nil` grants nothing), and withheld beats mismatch (existing behaviour
pinned, unchanged).
*enablement-store* — the N1 deferral's redemption: **`ActionConfigStore`** (actor,
`VoccaActions/Config/`) persists **`action-config.json`** under
`<applicationSupport>/Vocca/` — `servers` (`[{id, name, executablePath, arguments}]`,
absolute paths, the `StdioMCPTransport.Configuration` contract — no PATH lookup; cap 8)
and `enablement` rows (providerID/toolID only — membership by whole `ActionInvocation`,
**no arguments ever**; cap 512). Tolerant decode: a corrupt file loads as **empty** with a
loud log, never a throw; unknown keys refused (the byte-pin); atomic tmp+rename writes;
`MCPServerConfiguration` value type; stale tool rows survive; **absent is off**; two store
instances over one directory see the same config.
*executor* — **`ActionExecutor`** (actor, `VoccaActions/`): the **one caller of
`ActionGate.submit` in the shipped configuration**, and the only complete gate→audit round
trip the probe and the surface share. Every decision is recorded —
`autoRanReadOnly` / `confirmed` / `refused` (incl. `toolNotEnabled` and
`approvedSentenceMismatch`) / `dryRun` — the full `ActionAuditDecision` vocabulary,
reconstructable from the entry fields by a second store instance. A recording failure
never throws through: the decision stands, `auditRecorded == false`, logged loudly. The
executor always supplies the sentence the caller showed — the binding's caller-side
obligation, live in its own path.
*confirmation-card* — **`WidgetConfirmationState`** in `VoccaUI`: the sentence, the
provider/tool identity, and a generation token so a stale card cannot confirm after the
state moved on. The reducer row (`WidgetAction.confirmation`): the card survives every
adoption and every timer — cleared only by explicit confirm/decline/dismiss, one card at a
time; `WidgetStateStore` entry points (`presentActionConfirmation` /
`dismissActionConfirmation`); the panel card with Confirm/Decline buttons, sentence
verbatim, copy pinned. **M4a: no "don't ask again" state exists anywhere in the reducer or
the type.**
*actions-tab* — `SettingsTab.actions` (the enumeration-driven sidebar): `ActionsTabState`
reducer (server rows, discovery states `idle/discovering/succeeded/failed`, per-tool
enablement rows **default off**, arm `idle/awaitingConfirmation`, preview), `ActionsTabPage`
+ `ActionsTabCopy` with the **D2 copy exact-in-spirit** — *"Configuring a server is trust
extended to its author, not a guarantee we can make."* — and `SettingsBindings` gaining
claim-nothing defaults. VoccaUI stays `["VoccaCore"]`-only.
*wiring* — **`ActionWiring.swift`** in `VoccaBootstrap` (`composeActionWiring`, the
C11/C12 additive recipe): the executor over the real `FileSystemActionAuditStore` and the
injected provider, the config store as composition parameter, and the policy floor
**`.none`, recorded as a decision** — named in code and doc (the F2 lesson: the F1/F2
fail-safes already confirm anything without a genuine `readOnlyHint`, so a stricter floor
would break M3's read-only-runs-directly). The arm path **re-renders the sentence after
the record** — measured on the real `AuditActionProvider`, whose sentence names the count:
a card rendered from the executor's record would be one entry behind the truth the moment
the record lands, and the first confirm would mismatch forever; the re-render is a read,
never a decision. The confirm binds to exactly the card's sentence; a mismatch is refused
by attempting the call and re-presented as a **fresh card** — a render, not a decision
(the mismatch cascade, measured). Decline records the refused decision — the audit log is
the honest history of an action stopped for want of a yes. Arm while a session is in
flight is refused (`ActionWiringError.sessionInFlight`, the C11 in-flight refusal). The
composed default reports **`servers=0`, `spawnsSubprocess=false`** into the probe line
(the `requiresNetwork` analogue). Root slots on `DictationLoopRoot` (nullable, defaulted —
the converse/context precedent); `AppBootstrap.configure` composes additively;
`PROBE-ACTION-SURFACE` drives the composed default inside the zero-network interposer with
its guard-the-guard; the wiring-family lint (the `ContextWiringSeamBoundaryTests` shape).
**G5 re-anchored exactly once, deliberately**: `AppBootstrap.swift`
`464b0d5a…` → `aa12c723…` — computed, never edited-to-match; `SessionMachine.swift` and
`DictationPipeline.swift` digests unchanged, asserted by the pin.

**Measured (recorded, never gated):** **nothing was measured.** The only figures are test
counts: **2710** executed through the floor script (`N == E`). No percentage exists, and
none may be quoted.

**The honesty block:**
- **No gate passes.** The ninth unit built ahead of the uncleared gates.
- **N2's limit, stated on the surface's own record:** an approval asserts a human said yes
  and **cannot verify it**. What the sentence binding narrows is what an approval can be
  *replayed against* — the confirm binds to the exact sentence the card showed, and a
  drift between show and confirm is refused by attempting the call. The *seeing* is
  asserted by the UI layer: the card renders what the reducer carries, and CI asserts the
  reducer row — never the pixels.
- **R8 is mitigated, not retired.** Every decision is recorded — the confirm, the decline,
  the dry-run, the refusals. But "zero unintended actions" stays unmeasurable: nothing
  executes for a founder to observe yet (SMOKE 145 is the first real observation —
  recorded, never gated).
- **D2, carried onto the surface.** Discovery is explicit user action by design (R4 — the
  spawn is the trust the user extends, refused-by-absence in the default configuration);
  in this slice the composed wiring cannot even do that: discovery answers a bounded
  `.failed("discovery.unwired")` refusal because no transport is wired — so the default
  configuration cannot create a child **and no surface action can either**. The Actions
  tab's copy says where the claim stops: *"Configuring a server is trust extended to its
  author, not a guarantee we can make."*
- **The `.none` policy floor is a decision, not an unexamined default** — recorded in the
  wiring's documentation: the F1/F2 fail-safes already confirm anything without a genuine
  `readOnlyHint`; a stricter floor would break M3.
- **The rendered card is executed by nothing in CI** — SwiftUI, the tap-adapter precedent.
  CI asserts the reducer row, the store folds, the copy pins and the wiring closures;
  SMOKE 145/147 observe the rendered surface.
- **"Nothing is wired" retires.** The surface is composed and probe-driven; the probe runs
  the composed default inside the interposer. What remains unwired is the *transport* —
  by decision, and the copy says so.
- **No SMOKE rows executed.** Steps 144-147 are **written and runnable** — recorded, never
  gated, executed by nothing in CI.
- Floor **2710** (executed 2710).

**Post-merge addendum (2026-09-21, CI findings).** The branch's first CI run failed the
strict-concurrency build on three warnings: two unused bindings this unit introduced
(`LiveWidget.confirmationActions`, `ActionAuditDrive.invocation`), and one **pre-existing
since 2026-09-19** — `PersistentConsentStoreTests.swift:333`'s unused `set(_:consented:)`
result, emitted by a newer Xcode 26.x compiler, which had been reddening every master CI
run since PR #40. All three fixed in one commit (the consent-test fix heals master CI; the
next master run is the first green since 2026-09-19). The two remaining bundle failures
were **machine-load flakes in audio tests this unit never touched** — the overrun-under-
contention assertion in `AudioRingBufferTests` (Debug, one run) and the frame-quantized
ramp in `PlaybackOfflineRenderTests` (Release, the other run); each passed in the sibling
config and on re-run, and all eight checks are green. Both tests are recorded here as
candidates for a deterministic fix in a later session (the audio path is digest-pinned
territory, out of this unit's scope).

---

**The `stdio-transport` unit shipped 2026-09-21 — C13 slice 4: `StdioMCPTransport`, the second
`MCPTransport` implementation (guardrail 7 met for that seam), and **the answer to D2**; no gate
passes.** `feat/stdio-transport/aliz`. Floor **2629** (executed 2629).

**D2 is answered, not solved — and the answer is a narrowed claim, not a better mechanism.**
The transport prohibition lint's doc comment had said since slice 1 that whoever adds a permitted
entry *"owes the review an answer to D2"*. The honest answer: **the child is not observable, and
no mitigation makes an arbitrary child observable.** A restricted child ignores
`DYLD_INSERT_LIBRARIES` **and purges `DYLD_*` from the environment it passes on**, so one hop
launders the insertion for the whole descendant tree.

So the claim changed shape, following the **BYOK precedent** — BYOK is not an exception to the
zero-network test, it is *unreachable* by it. No MCP server is configured out of the box, so the
**default configuration cannot create a child**: the probe never reaches a spawn, and there is no
blind child to be blind about. `spawnsSubprocess` is a declared **value** (the analogue of
`requiresNetwork`), so a composition root folds a fact rather than remembering a comment.

**The deliverable that matters most is a sentence.** The project's central promise now reads
*"the default configuration makes zero network calls **and spawns no child process**"* in
`CLAUDE.md` and `README.md` — and `README.md` now states the limit plainly for users: Vocca's
network check watches its own process and **cannot see inside a program Vocca starts on your
behalf**, so configuring an MCP server is trust extended to that server's author, not a guarantee
we can make. The docs stop letting the interposer's reputation imply coverage it does not have.

**The lint's permitted set went from empty to exactly one** —
`VoccaActions/MCP/StdioMCPTransport.swift` — with the D2 answer in its comment. `Process(`
appears in exactly one file in the module. **Leg (b) — every permitted file *does* name the
family — stopped being vacuous for the first time since the lint shipped.**

**Four of the seven acceptances concern a hostile child on purpose**, because a spawned peer is
*less* trustworthy than an in-memory one: exit mid-exchange yields a typed failure; an
unresponsive child hits a bounded **injected-clock** timeout, asserted with a wait-count so a
spin loop cannot pass it; a flooding child is bounded; and **no orphan survives teardown**,
asserted on the real pid with `kill(pid, 0) == -1 && errno == ESRCH` — **ESRCH specifically,
because a zombie answers `kill(pid, 0)` successfully.**

**Two defects found by the acceptances rather than by review.** `Process.waitUntilExit()`
**deadlocks** here — it spins the calling thread's runloop — and hung the suite; teardown now
polls `kill(pid, 0)` bounded, then SIGKILLs. And the frame cap **missed a complete oversize
frame** whose delimiter arrived in the same read.

**A scope deviation, recorded:** the card put "any change to the seam" out of scope, but
`spawnsSubprocess` had to become an `MCPTransport` requirement (defaulting to `false`). It is
additive and a default keeps every call site compiling, but it *is* a seam change and is named
rather than slipped in.

**Measured (recorded, never gated):** **nothing was measured.** Test counts only: **2629**
executed (`N == E`).

**The honesty block:**
- **No gate passes.** The eighth unit built ahead of the uncleared gates.
- **Guardrail 7 is now MET for `MCPTransport`** — two real implementations, one of which spawns
  a real process.
- **D2 is answered, not eliminated.** The blindness is permanent. What changed is that the
  default configuration cannot create a blind child, and the documentation now says where the
  claim stops.
- **Nothing is wired.** No composition root, no surface, no server configuration — so nothing
  spawns in a shipped configuration today. The G5 pin was **not** re-anchored; all three digests
  unchanged.
- **The test suite is itself an instance of D2**: it drives `/bin/cat` and `/bin/sleep`, Apple
  platform binaries, which are blind to the interposer.
- **No SMOKE rows.** Steps still stop at 143.
- Floor **2629** (executed 2629).

---

**The `mcp-protocol` unit shipped 2026-09-20 — C13 slice 3: the MCP protocol layer and
`MCPProvider`, built with **no transport that touches the OS**; no gate passes.**
`feat/mcp-protocol/aliz`. Three aspects. Floor **2617** (executed 2617).

**Q3 was decided as "no transport in this slice"** — and the reasoning changed once slice 2
shipped. The substance of MCP is not the pipe: it is JSON-RPC framing, `initialize` negotiation,
`tools/list` discovery, schema mapping, and whether a server's self-declared annotations may be
trusted. All of it is buildable behind an `MCPTransport` seam with an **in-memory**
implementation that makes zero syscalls and therefore runs honestly inside the interposer. That
leaves stdio as its own slice where **D2 is the entire conversation** rather than a footnote
beneath a half-built protocol layer.

**What shipped, per aspect.** *protocol-core* (2561 → 2595): `MCPTransport` (send/receive, never
a pipe — no file descriptors, no PIDs, no endpoints), `InMemoryMCPTransport`, JSON-RPC framing
with id correlation by bounded forward scan, `MCPSession`, `MCPToolDescriptor`, and a new
`PROBE-MCP` drive. Two fail-safe defaults pinned: **a tool with no `readOnlyHint` is NOT
read-only** (absent means unsafe — the common case in real servers), and **a session that failed
`initialize` is unusable**, with the refusal asserted to happen *before the request leaves* and a
perfectly good reply scripted behind it so the failure cannot be an absence of anything to read.
*mcp-provider* (2595 → 2617): `ActionInvocation.arguments`, `MCPProvider`, the lying-server test,
and the fail-open default it exposed. *record* (this entry).

**F1 — a safety-gate bypass by parser detail, found and closed.** `JSONSerialization` collapses
JSON booleans and numbers into `NSNumber`, and `as? Bool` succeeds for `1`. A server sending
`"readOnlyHint": 1` would have been read as **claiming read-only** — the fail-safe defeated not
by a missing check but by a **type confusion underneath a check that looked correct**.
`CFBooleanGetTypeID()` undoes the collapse in exactly one place; `1`, `"true"` and `null` are all
asserted to be non-claims. This is the first point in the tree where **untrusted input reaches a
safety decision**, and the damage came from a parsing library's convenience rather than from an
omission.

**F2 — the fail-open policy default, found by the lying-server test's own counterfactual.**
`ActionGate.submit`'s parameters were inconsistent: `enablement` had no default (the caller must
say), `approval` defaulted to `.withheld` (restrictive), and `policy` defaulted to **`.none`** —
the only default that *granted* rather than withheld. With no floor, a lying server's
`readOnlyHint: true` stands and auto-runs a destructive tool, making slice 1's escalate-only rule
**inert unless someone remembered to pass a floor**. The default is removed; all 42 call sites
now state `.none` explicitly where that is what they mean, so behaviour is byte-identical and
only the ergonomics of forgetting changed. As the implementing agent put it: *`.none` was a
security posture wearing the costume of a neutral default.*

**`mode: .live` was examined and deliberately left alone.** The distinguishing question is not
"does it have a default" but **"does the default grant anything the caller did not ask for"**.
`policy: .none` removed a floor; `mode: .live` removes nothing — a live submission still faces
enablement, the policy and the confirmation, in that order. The reasoning is recorded in the
gate's doc comment, not only in this entry.

**A claim sharpened rather than repeated.** "Raw arguments are never persisted" was imprecise.
The **rendered sentence** is persisted and now quotes argument values, because C13 requires the
confirmation to be concrete. The honest property is therefore: **the raw blob is never persisted;
the approved sentence is** — what lands on disk is what a human was shown, not whatever a server
supplied. Pinned by a distinctive argument string asserted absent from the encoded bytes and from
the decoded entries, vacuity-guarded.

**Two limits recorded, not fixed.**
- **F3 — the module-coverage cross-check cannot see the MCP drive's removal.** `VoccaActions` is
  already covered via the audit drive, so deleting `PROBE-MCP` leaves the cross-check green. The
  structural check that catches an *undriven module* cannot catch an *undriven layer within a
  driven module*; the guard-the-guard making a weakened assertion a visible edit is the available
  mitigation.
- **Swift cannot express "this parameter has no default" in a type** — a default is not part of a
  function's type, so an unapplied-reference pin is blind to it. The `policy` pin is therefore a
  scan over `Sources/` and `Tests/` (the Family B precedent, where a forging call *compiles* and
  a scan catches it), with its marker assembled so the file is not exempt from its own scan.

**Measured (recorded, never gated):** **nothing was measured.** The only figures are test counts:
**2617** executed (`N == E`). No percentage exists.

**The honesty block:**
- **No gate passes.** The seventh unit built ahead of the uncleared gates.
- **No transport exists.** Nothing spawns, connects or dials. `PROBE-MCP` proves the *protocol
  layer* reaches no network name and proves **nothing** about a future stdio transport — that is
  **D2**, and it is unchanged by this unit.
- **`MCPTransport` has ONE implementation.** Guardrail 7 is **unmet for that seam**; the in-memory
  transport is real but is the only one. The stdio slice is what would prove it.
- **R8 remains mitigated in structure, never measured.** Nothing is wired; nothing executes in a
  shipped configuration.
- **No surface, no composition-root wiring.** The G5 pin was **not** re-anchored; all three
  digests unchanged.
- **The local policy is load-bearing and is supplied by a caller that does not yet exist.** With
  `.none`, a server's claim stands. The wiring slice must choose a real floor.
- **No SMOKE rows.** Steps still stop at 143.
- Floor **2617** (executed 2617).

---

**The `local-data-provider` unit shipped 2026-09-19 — C13 slice 2: the second real
`ActionProvider`, closing guardrail 7 — and the seam went `async` because that provider could
not be written otherwise; no gate passes.** `feat/local-data-provider/aliz`.
Three aspects. Floor **2561** (executed 2561).

**The finding is worth more than the provider.** Attempting the second implementation revealed
the shipped seam could not accommodate it. `describe`/`invoke` were **synchronous**; the audit
store is an **actor** with `async throws` methods; **a `nonisolated` synchronous witness cannot
await an actor.** C12's `AccessibilityContext` satisfies a synchronous witness only because AX
is a synchronous C API. Slice 1 predicted the *shape* of the problem — `ActionProvider.swift`
records that MCP adapters "will need the C12 D1 route" — but the D1 route works only where the
underlying work is synchronous, and for MCP it will not be. **Guardrail 7 found this on its first
real exercise, which is exactly what it exists for**, and found it at the cheapest possible
moment: two call sites, no wiring, no surface. The compiler stated it directly — *"type
`SuspendingActionProvider` does not conform to protocol `ActionProvider`."*

**What shipped, per aspect.** *async-seam* (64b5a99, e1c86d0, 24a7e04, c751494; 2551 → 2553):
both seam operations became `async` — **never `async throws`**, so failure stays a returned value
and an omitted `catch` still cannot drop an audit record; that property is now pinned by unapplied
references, so adding `throws` breaks the file. `ActionGate.submit` became `async`. Only **two**
tests were added, deliberately — a signature change adds none by itself, and the aspect refused
to be a pure refactor: an actor-backed provider (unwritable before) driven through the gate with
its suspension hops counted and a *failure* outcome configured so success cannot rest on a
plausible default, and eight concurrent no-token destructive submissions all refused with
`invokeCount == 0`, so the refusal did not become a race. **Every slice-1 acceptance survives
unchanged** — including the never-read ordering, whose guard is still the first statement in
`submit`, before the first `await`. *audit-provider* (2a91899, cbb2bb8, b6776eb; 2553 → 2561):
**`AuditActionProvider`** — an actor over the real store, `audit.count` (read-only) and
`audit.clear` (destructive). Genuinely real: a real `FileSystemActionAuditStore` over real temp
directories, counts read from disk, `clear()` removing real files, dry-run asserted by comparing
raw file **bytes** before and after. Two acceptances became expressible for the first time
because a real provider finally existed: the without-a-token refusal run against something that
would actually delete a file, and the byte-identical dry-run. *record* (this entry).

**The module boundary chose the provider, not preference.** `VoccaActions` declares exactly
`["VoccaCore"]`, asserted by equality, and `ModuleBoundaryTests` rule 3 forbids an adapter
importing any other Vocca module — so a provider here cannot read `VoccaUsage`. The audit store
was the one real capability reachable without a boundary violation. `ShellProvider` was rejected
(the highest blast radius in the roadmap, in the slice whose premise is safety-before-capability)
and a clipboard provider was rejected (it would race `VoccaInject`'s clipboard hygiene).

**Clearing the audit log is itself an auditable action.** The record is written **after** the
clear, so the log is never empty afterwards — it holds exactly the record of its own clearing.
A log an action can silently empty is not an audit log. The wrong ordering is pinned by a
**counterfactual** test asserting that record-then-clear leaves the log empty, so the property
cannot be "simplified" away unnoticed.

**Two honest limits recorded about the lints themselves.**
- **Family A grows by five rows per real provider**, and the seam's signatures force it: the
  conformance names `ActionProvider`, `describe` names `ActionInvocation` and `ActionSummary`,
  `invoke` names `ActionConfirmation` and `ActionOutcome`, and no Swift spelling omits a parameter
  or return type. Five rows naming **one** file is one reviewed widening. The known next move, if
  a third provider makes the sets unwieldy, is permitting a blessed `Providers/` directory by
  rule — **not taken**, because a directory rule would pass any file dropped into it.
- **The lint under-reports, and this is the first place it is load-bearing.**
  `AuditActionProvider` classifies both tools by blast radius yet has **no `BlastRadius` row**,
  because it writes radii as leading-dot literals (`.destructive`) and a text scan sees only
  spelled identifiers. The general form, now recorded in the lint: *a permitted set is a list of
  files that **name** a family, never a list of the files that **use** one* — so "no row,
  therefore no use" is unsound for every text-scan lint in this repository.

**Measured (recorded, never gated):** **nothing was measured in this unit.** The only figures are
test counts: **2561** executed through the floor script (`N == E`). No percentage exists.

**The honesty block:**
- **No gate passes.** The sixth unit built ahead of the uncleared gates.
- **Guardrail 7 is now MET for `ActionProvider`** — two real implementations, one of which does
  real file I/O. **D3 is amended, not deleted:** `MCPProvider` and `ShellProvider` remain PENDING,
  and the seam's *hosted-tier* claim is untouched (it remains "No — by design").
- **R8 is still mitigated in structure, never measured.** A provider now executes in *tests*;
  nothing executes in a shipped configuration, because nothing is wired.
- **Still no user-visible surface and no composition-root wiring.** The G5 pin was **not**
  re-anchored; all three digests are unchanged.
- **D2 stands untouched.** The zero-network blind spot through spawned children is unaffected by
  this unit — no transport was added, and the prohibition lint is green and unmodified.
- **No SMOKE rows.** Steps still stop at 143. Nothing executes for a founder to observe.
- Floor **2561** (executed 2561).

---

**The `action-safety-spine` unit shipped 2026-09-19 — C13 slice 1: the safety spine of
Actions/MCP, machinery-only, over a stub provider; nothing executes; no gate passes.**
`feat/action-safety-spine/aliz`.
Five aspects: the `ActionProvider` seam and its Foundation-free vocabulary, the `ActionGate`
with the structural refusal and the escalate-only policy, the `VoccaActions` module with the
append-only audit store and its byte-level pin, the transport prohibition lint, and this record.
**No MCP wire, no transport, no intent layer, no real tool execution, no user-visible surface,
and nothing wired into the composition root.** SMOKE steps stop at 143 and this unit adds
**none** — nothing executes, so there is no real-machine observation for the founder to make.
Floor **2551** (executed 2551).

**What shipped, per aspect.** *action-seam* (7b104de, f5ad683, d1db69d, b0b168f, c7f6497,
a23b9ca; 2475 → 2500): `VoccaCore/Actions/` — `ActionProvider` with the **`describe`/`invoke`
split** (a pure, side-effect-free `describe` renders the concrete sentence; only `invoke` acts —
without the split, "dry-run never touches the provider" and "the confirmation states concretely
what will happen" are contradictory requirements), `ActionInvocation`, `ActionSummary`,
`ActionOutcome` (failure is a *returned* value with a reason key, so an omitted `catch` cannot
drop an audit record), `BlastRadius`, `ActionConfirmation` (`public struct`, **`internal`
init**), and `NullActionProvider`. All Foundation-free — Core's import allow-list is empty. The
action-family seam lint plus the **forgery guard** spanning `Sources/` and `Tests/`, with planted
and comment-strip controls. `RecordingActionProvider` and its self-checks — the non-empty domain
the later dry-run and reconstruction acceptances need. *confirmation-gate* (efa3344, 0513693,
b0856b8, 20021d3, b6b54cc; 2500 → 2517): `ActionGate`, a pure value — the without-a-token refusal
asserted **by attempting the call**, the read-only direct path, dry-run invoking nothing, per-tool
enablement declining **before `describe` and before `invoke`**, per-invocation-only confirmation,
refusal distinguishable from failure, and the escalate-only policy written so it returns one of
its two arguments and never a third, making de-escalation unreachable rather than merely
forbidden. The reviewed lint widening that admitted `ActionGate.swift` as the tree's single
permitted minting site. *audit-log* (e26f1dc, 8b8c430, 370f00f, f5fc431, 978436f, 64934d9;
2517 → 2541): the **`VoccaActions`** target (deps exactly `["VoccaCore"]`, asserted by equality),
`ActionAuditEntry` and the append-only store — **one file per event**, zero-padded ordinal,
`.tmp` mid-commit, `replaceItemAt` rename-over, tolerant decode that never throws, eviction on
write; the instant as **monotonic `Duration` components, never a wall clock**; the byte-level pin
with its one deliberate divergence from its ancestors (**`summary` may carry text** — a summary
with no content would defeat the log's purpose); and `PROBE-ACTIONS`, which was **obliged rather
than chosen** (the manifest-equality assertion refuses to let a shipped product target exist
undriven). *transport-prohibition* (ad431f6, 78267e2; 2541 → 2551): the empty-permitted-set lint
over `Sources/VoccaActions/` for all seven transport and subprocess families, carrying the **D2**
rationale it exists to preserve. *record* (this entry).

**The G5 pin was NOT re-anchored — stated as a positive claim.** This unit wires nothing into
the composition root, so `AppBootstrap.swift` was never edited and all three digests are
unchanged, verified by computation:
`SessionMachine.swift 1baeb2de2c45149746468bfef49862a08279008d3d2f305be892122d5727537e`,
`DictationPipeline.swift ce70ca10c15914d6960f07e53da8571a5fa9ec1fb58b8f0051ef051f16c07a84`,
`AppBootstrap.swift 464b0d5a0e63b69dda8e72ca9ee793ff189e0d70094491c5bfde2c53e0328aff`.
C11 and C12 each re-anchored twice; keeping this slice unwired avoided the ritual entirely.

**Deviations and follow-ons recorded.**
- **D2 — the zero-network invariant is blind through a spawned child.** Measured empirically in
  the dig, not read: the interposer counts **loopback as NETWORK on purpose**
  (`interposer.c:69-73`), so an MCP server on `127.0.0.1` over HTTP/SSE is a violation and stdio
  is the only permitted transport. But a *restricted* child ignores `DYLD_INSERT_LIBRARIES` **and
  purges `DYLD_*` from the environment it passes on**, laundering the insertion for the whole
  descendant tree. Measured: direct absolute-path spawn of a locally built binary → SEEN; `node`
  carrying the dyld-env entitlement → SEEN; `/usr/bin/python3`, `/usr/bin/curl`, `/usr/bin/tar`,
  any `/bin/sh -c` wrapper, and `#!/usr/bin/env node` → **BLIND**. **The failure mode is a green
  test while a child egresses** — a false green in the permanent release blocker. This unit
  cannot fix it; the prohibition lint makes reaching for a transport a reviewed edit.
- **D3 — guardrail 7 is unmet.** `MCPProvider` and `ShellProvider` are both PENDING;
  `NullActionProvider` is a shipped default, **not** a second implementation. The
  `ParakeetEOU` Branch B precedent. No test enforces the doctrine, so this is an honesty
  obligation.
- **N1 — persisted per-tool enablement**, in-memory in this slice: no tools exist to enable yet,
  so persisting an empty set would be premature.
- **N2 — an approval asserts a human said yes; it cannot verify it.** `ActionApproval` is
  payload-free and defaults to `.withheld`, so *"don't ask me again" has no representation in the
  type* — but `.granted` is publicly constructible. The tightening, once a surface exists, is to
  bind an approval to the exact invocation and sentence shown.
- **A decomposition rule, learned the hard way:** the aspect that creates a module owns that
  module's probe drive. The plan missed it and the implementing agent stopped on it.

**Measured (recorded, never gated):** **nothing was measured in this unit, and no number below is
a claim about behaviour on a real machine.** The only figures are test counts: the suite executed
**2551** through the floor script (`N == E`). No percentage exists, and none may be quoted.

**The honesty block:**
- **No P2/P3/P4 gate passes.** This is the **fifth unit built ahead of the uncleared gates** under
  the recorded posture; every record says "No gate passes", and this one does.
- **R8 is mitigated in structure, not measured.** No "zero unintended actions" number exists and
  none may be quoted — **nothing executes**, so there is nothing to count.
- **The seam is not proven.** Guardrail 7 is unmet (D3). The pluggable claim for `ActionProvider`
  is an assertion until a second real implementation ships.
- **The P3 gate's conversational leg remains open.** This slice ships no agent; `EchoReplyGenerator`
  is still the shipped stand-in.
- **`PROBE-ACTIONS` proves less than it may appear to.** It proves the audit store reaches no
  network name. It says nothing about a transport a later slice may spawn — see D2.
- **No SMOKE rows.** Steps stop at 143. Deliberate, not an omission.
- Floor **2551** (executed 2551).

---

**The `context-provider` unit shipped 2026-09-18 — C12's context half of the wedge: the seam
with two local implementations, the per-app consent gate, the visible indicator and the
one-action kill switch, the BYOK exclusion grant; the privacy claim is auditable rather than
promised; no gate passes.** `feat/context-provider/aliz`.
Seven aspects plus the integrator's wiring close: the `ContextProvider` seam with
`NullContext` + `AccessibilityContext`, the new `VoccaContext` module, the per-app
`ConsentStore` (bundle IDs only, the never-read gate), the widget badge + the menu-bar kill
switch, the off-by-default BYOK context grant with its AND-gate, the additive
`AppBootstrap` composition driven by `PROBE-CONTEXT` inside the zero-network interposer (with
two G5 pin re-anchors), and the wiring close that made the shipped composition real and the
hand-offs good. SMOKE 139-143 are **written and runnable** — the first real resolution run,
the consent/never-read audit, the indicator, the one-action kill switch, and the BYOK
never-in-payload audit; **no real resolution percentage exists yet** (SMOKE 139 waits for the
founder's machine with an Accessibility grant); the executed rows land when the founder runs
them. Floor **2475** (executed 2475).

**What shipped, per aspect.** *context-seam* (49766c1, 66282ec, 6b4f1e1; 2350 → 2364): the
`ContextProvider` protocol in `VoccaCore/Context/` — `ContextSnapshot` (bundle ID, window
title, selected text; nil-vs-empty pinned distinct), `NullContext` (the shipped default,
reads nothing), and the context-family seam lint with planted and comment-strip controls.
*accessibility-context* (3d31e82, 5433f0c, 05364d5, a2b4d1e, 3533b3d, dea6696; 2364 → 2383):
the new **`VoccaContext`** target (Package.swift + `ModuleBoundaryTests`), `AccessibilityContext`
(the AX adapter — Secure Input refused first, failures resolve to the empty snapshot, never a
throw) behind its own per-seam AX and Secure Input permit files (the `KeystrokeSource`
precedent), `ContextResolutionScorer` with the 22-row scripted corpora (the passing corpus
clears the ≥95% bar; the planted 2-miss corpus at 0.909 **fails loudly** — the gate that
cannot fail proves nothing), the env-gated real suite + SMOKE 139, and the recorded deviation
**D1**: the seam is synchronous/non-throwing by contract, so the adapter is an actor with a
`nonisolated` witness — pinned, not drifted. *consent-store* (370062c, 766a9a7, f251391,
6cb2c85, 962b334; 2383 → 2408): the `ConsentStore` seam + `ConsentBundleID` validation in
`VoccaCore`, `PersistentConsentStore` in `VoccaContext/Consent/` (`context-consent.json`,
atomic temp-write + replace, tolerant decode, capped at 512 apps, the byte-level pin that no
content, transcript or timestamp reaches the file), the FileManager seam row widened five →
six, and `ContextConsentGate` — the never-read decision: an unconsented app is **declined
before any AX call** (not read-then-discard, never read). *widget-indicator* (23b567b,
a010706, 2eae375, d5b9028; 2408 → 2449 — the combined ratchet; byok Phase 4's tests are
counted by the widget Phase 4 commit): `WidgetContextState` (`.off` / `.reading(appName:)`)
with the `contextChanged` fold in the store, the `eye`-glyph badge in `WidgetView` (never
lights on Secure Input — a reducer row, not a wiring decision), the menu-bar kill row
(`MenuBarState.isContextReading` + the defaulted `onKillContext` + the copy pins), and the
General-tab Context section. *byok-context-grant* (20db61b, c2c3ae4, ee86082, 97c9c3a): the
persisted global grant (`SettingsStore.contextGrantEnabled`, off by default, unreadable →
false loudly), `GrantedContextSource` + the grant-gated payload leg in `BYOKCleanupProvider`
(`ContextPayload` declared last — the absent-grant body is byte-identical to today's; the
key read first), `ContextGrantGate` — the AND-gate (per-app consent **and** the global grant,
never either alone) owning the ≤ 4 KB UTF-8 bound in exactly one place — and the Cleanup-tab
toggle with the Ollama-never-carries-context pin. *bootstrap-wiring* (d86d62c, 5b71246,
0c43be1, cef7978, a771aed; 2449 → 2463): the `ContextWiring` recipe with the three root slots
(consent-gated per-turn resolution, the indicator fold, the kill-switch routing), the
context-wiring family lint (no `ContextProvider` name in the pinned dictation path),
`PROBE-CONTEXT` driving the composed default (`NullContext`) inside the zero-network
interposer, and the **G5 pin re-anchor #4**. Recorded hand-offs (now closed): the consent
store absent at configure and the kill-row/bindings closures unwired — both were real at
`bootstrap-wiring`'s close and closed by the wiring close. *wiring-close* (e5a6201, 0b2700a,
251025a, c9651a7, 8416ad4, a51ba4f, 8433226; 2463 → 2475): an integrator-directed slice **not
in the aspect plans** (the C11 mode-routing precedent) — `Package.swift`: `VoccaBootstrap`
now depends on `VoccaContext` (+ the import lint), the real composition
(`AccessibilityContext` over the real `PersistentConsentStore`, path-injected beside the
usage ledger), the kill-switch close (`attachMenuBarItem` wires `onKillContext`; `showSettings`
constructs the four bindings closures), the Apps-tab per-app consent UI (grant/revoke per
bundle ID, default off, never a blanket allow), `PROBE-CONTEXT` re-pointed at the shipped
composition, the **G5 pin re-anchor #5**, and the floor ratchet 2463 → 2475 (executed 2475).
*record* (this entry): SMOKE 139-143 (139 landed with `accessibility-context`; the section 21
header + rows 140-143 here), the PRODUCT_SPEC §8a context section, the STATUS/CLAUDE/
ARCHITECTURE sync, and the floor verified.

**The G5 pin re-anchor record.** `AppBootstrap.swift` is the one pinned file C12
legitimately changes (its wiring is additive context composition), so the pin was
deliberately re-anchored **twice** in dedicated, reviewed commits — per the pin's own
contract ("a deliberate edit recomputes the digest and edits the pin in review; it must never
be edited to match a moved tree"): `6d98acf4…0448` → `9895f45ac20147c3a9cfa34ce9507a07f0b8637fff1b707fded21e7c6a9875d3`
(`bootstrap-wiring` cef7978, re-anchor #4 — the M8/M9/M11 additive context wiring), →
`464b0d5a0e63b69dda8e72ca9ee793ff189e0d70094491c5bfde2c53e0328aff`
(`wiring-close` a51ba4f, re-anchor #5 — the real composition, the kill-switch wiring and the
consent-UI wiring). The dictation files' digests are unchanged throughout:
`SessionMachine.swift 1baeb2de2c45149746468bfef49862a08279008d3d2f305be892122d5727537e`,
`DictationPipeline.swift ce70ca10c15914d6960f07e53da8571a5fa9ec1fb58b8f0051ef051f16c07a84`.

**The history repair recorded.** The two Phase-4 aspects (`widget-indicator` and
`byok-context-grant`) ran concurrently on one worktree; `git add -A`-style commits swept each
other's WIP across commit boundaries (e2f5eee, 3008298 in the original history). The
integrator replayed the branch from `byok-context-grant`'s 20db61b: a soft reset and
per-phase re-commits in the intended order with the plans' messages. The tree is
byte-identical to the pre-repair HEAD (the `git diff` of the replay verified empty); the
floor ratchets were recomputed from actual runs (2408 → 2449 lands in the final
`widget-indicator` commit, d5b9028). Recorded so future readers are not surprised by the
commit timestamps or order.

**Measured (recorded, never gated):**
- The full suite at the unit's close: **2475 tests executed** through the floor script — the
  record's Phase 2 run printed `swift test executed 2475 tests (floor: 2475)`; `N == E`, no
  ratchet needed.
- The scripted corpus in CI: the passing 22-row corpus clears the ≥95% bar; the planted
  2-miss corpus resolves **0.909 and fails loudly** (21/22 ≈ 0.9545 passes by design — 1 miss
  in 22 sits at the bar; 2 misses ≈ 0.909 fails).
- `PROBE-CONTEXT` drives the composed default inside the zero-network interposer — first
  `NullContext`, then the shipped composition (`AccessibilityContext` over the real store in
  a temp dir); the zero-network invariant stays green over the probe leg.
- SMOKE 139-143 are **written and runnable, not yet executed**: **no context-accuracy
  percentage exists** — the ≥95% acceptance's real half (`CAPABILITY_ROADMAP.md:355`) is
  SMOKE 139's, and it waits for the founder's machine with an Accessibility grant; nothing
  below may be read as a gate pass, and no percentage may be quoted until a real run exists.
  This aspect's merge does not depend on their execution (the C11 precedent).

**The honesty block:**
- **No P2/P3 gate passes.** This is the **fourth unit built ahead of the uncleared gates**
  under the recorded posture; every record says "No gate passes", and this one does.
- **No context-accuracy percentage is quoted** — the ≥95% matrix-resolution acceptance is
  real-app work (R3), executed by nothing in CI, now or ever; the CI-measurable contract is
  the scripted corpus, and the real number is SMOKE 139's, recorded never gated.
- **Numbers recorded never gated.** Every measured row above is recorded verbatim; an
  over-budget observation is recorded verbatim too, never a pass.
- **The dictation path is byte-for-byte untouched** — the G5 pin's first two digests
  unchanged across both re-anchors; `AppBootstrap`'s re-anchors are deliberate and recorded,
  never an edit-to-match.
- **Never-read and never-in-payload are structural, not discipline** — asserted in CI (the
  consent gate's ordering contract with the planted-violation control; the one
  payload-building site, `BYOKCleanupProvider.clean`), and observed on the real surface by
  SMOKE 140 and 143.
- **Context is never persisted beyond the turn and never egresses.** The consent store holds
  bundle IDs only (the byte-level pin; capped at 512; `context-consent.json` is the auditable
  artifact); the BYOK exclusion is the point — context reaches a payload only through the
  AND-gate, and the seam has **no hosted counterpart by design**.
- **Zero network.** `PROBE-CONTEXT` drives the context wiring inside the zero-network
  interposer; no URL reaches any new port in the context path.
- **Interim states recorded, not papered over:** D1 (the seam synchronous/non-throwing, the
  adapter an actor with a `nonisolated` witness — the sync contract won, pinned not drifted);
  the history repair above; the `bootstrap-wiring` hand-offs were real when recorded and are
  now closed (store absent → real store; closures unwired → wired); C13's consumption of
  context is out of scope — nothing user-visible consumes context beyond the BYOK grant field
  and the tests.
- Floor **2475** (executed 2475).

---

**The `dual-mode` unit shipped 2026-09-16 — C11's CONVERSING surface is real: the mode
machine, the wired loop, the honest reply stand-in; no gate passes.** `feat/dual-mode/aliz`.
Seven aspects plus the integrator's routing close: the explicit `SessionMode` state machine
with the closed 7-row transition table, the `ReplyGenerator` seam with two deterministic
implementations (the shipped default is honest about being a stand-in), the additive converse
composition in `VoccaBootstrap` driven by `PROBE-CONVERSE` inside the zero-network
interposer, the CONVERSING widget state with its five cues, the per-mode cleanup selection
consumed at last, the persisted converse chord with the two-chord rebind surface, and the
routing close that made the machine the chords' owner. SMOKE 134-138 are **written and
runnable** — the full spoken exchange, mode clarity, the chord rebind, the menu-bar toggle,
and the never-injects check; the executed rows land when the founder runs them. Floor
**2350** (executed 2350).

**What shipped, per aspect.** *mode-machine* (299765f, 359523f, 4544e38; floor 2160 held):
the `SessionModeMachine` in `VoccaCore/Mode/` (`SessionModeIntent`, `SessionModeEffect`,
`ModeSession`) — the epoch-minted `ModeSession` handoff (buffer/transcript/target — the reset
carrier), the closed 7-row transition table (idle ↔ active, the other-mode rows refused), the
seam-family lint and the `TextInjector`-prohibition scan (no `TextInjector` call is ever made
from the converse path), `ModeResetTests` (full state reset with no carryover). *reply-seam*
(0798a8d, 59b4cb0, 931e334; 2160 → 2208): the `ReplyGenerator` seam in `VoccaCore/Reply/`
with the two deterministic local implementations — `EchoReplyGenerator` (the shipped default,
your words back byte-for-byte) and `AcknowledgmentReplyGenerator` ("Vocca is listening.") —
and the seam-family lint. *converse-wiring* (22e6a9e, 32f6e4d, 05f1f5c, 1422eb8, ed468fe,
1cf22e9; 2208 → 2233): the `ConverseLoopDriver` + `ConverseTurnFailure` behind the pinned
contracts, the additive `AppBootstrap` composition (`ConverseWiring.swift` — the third
`AudioCaptureGraph`, `StreamingCapture`/`RefusingContinuousCapture`, the fallback
VAD/detector, `EchoGate`, `SystemPlayback`, `resolve(mode: .conversing)`), `PROBE-CONVERSE`
inside the zero-network interposer, the converse-family lint, and the first G5 pin re-anchor.
*widget-converse* (b862d27, a098969, c1333cd, 37048b9, 200860e; 2233 → 2301 → 2302):
`WidgetState.conversing(phase: ConversePhase)` — the turn-state projection, the five cues
(notched pill, distinct hue, `◈` labels, lower tick, no target name), the never-a-target
rule's full spine, the lower-tick sound seam, the menu-bar mode toggle, the family lint, and
the second pin re-anchor. *per-mode-cleanup* (2dd7cb9, 5a4933b, ef12cea, 95df602):
`cleanup-config.json`'s `converseProvider` key (default `.rules`, no migration),
`resolve(mode:)` with the no-arg ≡ `.dictation` equivalence, the Cleanup tab's converse
picker — `CleanupContext.mode` consumed at last. *converse-hotkey* (a93ad5d, 785e6d0,
7550e13, f8068ac, 7fc2fc5; 2302 → 2334): the converse chord `⌥⇧Space` persisted (four frozen
keys), `rebind(to:for:)` with the two-chord rebind surface, the collision refusal (equality —
neither chord can end the other's session), the in-flight refusal
(`RebindOutcome.refused(.sessionInFlight)`), and the third pin re-anchor. *mode-routing*
(79d3901, c6a0b6e; no ratchet — the suite's growth is the record's deliberate ratchet below):
the machine's owner at last — the chord press → `machine.observe` → `driver.start()`/`stop()`,
the stop chord leg, system-trigger stops, the menu toggle (`root.selectMode(_:)`), the
projection feed from `onStateChange`, the fourth pin re-anchor, and the recorded test-harness
limitation (the routing's fire-and-forget driver stop under async XCTest trips the Swift
task-allocator LIFO check — swiftlang#75501/#81771/#87481; the suite pins the stop's
synchronous contract instead). *record* (this entry): SMOKE 134-138, the five-cue prose
correction, the STATUS/CLAUDE/ARCHITECTURE sync, and the floor verified then deliberately
ratcheted.

**The G5 pin re-anchor record.** `AppBootstrap.swift` is the one pinned file C11
legitimately changes (its wiring is additive converse composition), so the pin was
deliberately re-anchored four times in reviewed commits — per the pin's own contract ("a
deliberate edit recomputes the digest and edits the pin in review; it must never be edited to
match a moved tree"): `03b624df…` → `a323750e…` (`converse-wiring` ed468fe), → `a4302a24…`
(`widget-converse` a098969), → `292c1d8f…` (`converse-hotkey` f8068ac), →
`6d98acf4…0448` (`mode-routing` c6a0b6e — the unit's **final** digest). The dictation files'
digests are unchanged throughout: `SessionMachine.swift
1baeb2de2c45149746468bfef49862a08279008d3d2f305be892122d5727537e`, `DictationPipeline.swift
ce70ca10c15914d6960f07e53da8571a5fa9ec1fb58b8f0051ef051f16c07a84`.

**The five-cue correction recorded.** `PRODUCT_SPEC.md:188`'s "four simultaneous differences"
corrected to "five simultaneous cues" (O7, the card's Contradictions surfaced 1); `:203`'s
"color is the *third* cue" recorded as a table position (color is the third row of the
five-cue table), not a count. The seam-doctrine citation drift is recorded here too: the PRD
cites `CAPABILITY_ROADMAP.md:413` for the two-implementations guardrail; the guardrail's line
is **`:414`** (the landed `AcknowledgmentReplyGenerator` doc cites the corrected line).

**Measured (recorded, never gated):**
- The full suite at the unit's close: **2350 tests executed** through the floor script (the
  record's run printed `executed 2350 (floor: 2334)` — the routing close grew
  `ModeRoutingCompositionTests` without a ratchet; the mismatch was surfaced and the
  deliberate, reviewed ratchet landed as its own commit, eeacd87, 2334 → 2350).
- `PROBE-CONVERSE` drives the converse default work (fallback VAD/detector +
  `EchoReplyGenerator`) inside the zero-network interposer — the zero-network invariant stays
  green over the probe leg.
- SMOKE 134-138 are **written and runnable, not yet executed**: the ≥5-turn spoken exchange
  with ≥1 barge-in and the keyboard untouched (134), the zero-mis-injections week (135), the
  chord rebind (136), the menu-bar toggle (137), and the never-injects check (138) —
  recorded, never gated, land when the founder runs them; this aspect's merge does not depend
  on their execution.

**The honesty block:**
- **No P2/P3 gate passes.** The P3 gate's spoken-exchange leg (`ROADMAP.md:215-217`) is SMOKE
  134 — recorded, never gated — and **the conversational leg stays formally unmet until C13's
  real agent**: the shipped reply is `EchoReplyGenerator`, an honest stand-in that does not
  understand, remember, or act; it echoes so the loop is exercisable end to end.
- **Numbers recorded never gated.** Every measured row above is recorded verbatim; an
  over-budget observation is recorded verbatim too, never a pass.
- **The dictation path is byte-for-byte untouched** — the G5 pin's first two digests unchanged
  across all four re-anchors; `AppBootstrap`'s re-anchor is deliberate and recorded, never an
  edit-to-match.
- **Converse never injects** — structural (the `.conversing` payload is phase-only; no
  `TextInjector` call from the converse path, enforced by type/assertion and asserted in CI),
  and SMOKE 138 observes it on the real surface.
- **Zero network.** The zero-network interposer stays green over `PROBE-CONVERSE`; the
  converse default work is fallback VAD/detector + the minimal reply generator — no model
  artifact, no SDK, no URL in the converse path.
- **Interim states recorded, not papered over:** `ParakeetEOU` stays PENDING —
  `SilenceThresholdDetector` is the shipped `TurnDetector`, consumed as-is (Branch B);
  per-mode ASR engine selection deferred (N1); the ledger stays dictation-only (converse
  sessions not folded — recorded out-of-scope); the routing's task-allocator limitation is
  recorded with its pinned synchronous-contract shape; hold-to-talk (dictate) stays whole.
- Floor **2350** (executed 2350).

---

**The `turn-taking-barge-in` unit's machinery shipped 2026-09-15 — C10's seams, loop and echo
gate are real; no gate passes, no user-visible surface.** `feat/turn-taking-barge-in/aliz`.
Seven aspects: the FluidAudio VAD/EOU vetting (six findings, the EOU-shape correction, the
version decision — 0.15.7, no bump), the two seams with their pure fallbacks and the family
lints, the real `SileroVAD` adapter behind the seam, `ContinuousAudioSource`/`StreamingCapture`,
`PlaybackEngine`/`SystemPlayback` (the output path's first real execution is SMOKE 132, never
CI), the `TurnTakingLoop` + `EchoGate` + 5×-weighted `TurnCommitmentScorer` with `PROBE-TURN`,
and this record. The composed realtime conversation is executed by nothing in CI — the
env-gated suite skips visibly; SMOKE 131-133 are **written and runnable** for the founder's
machine, and the executed rows land when the founder runs them. Floor **2160** (executed 2160).
**No gate passes; no user-visible surface ships in this unit** (the CONVERSING state is C11's).

**The vetting corrections and findings, recorded by name** (verified against the SDK's **code**
at the resolved 0.15.7, not its README — `docs/planning/_card/understanding.md`):
1. **The EOU is ASR-integrated, not a free-standing scored call.** `StreamingEouAsrManager`
   runs the whole Parakeet streaming pipeline; `eouDetected` is a decoding byproduct with a
   1280 ms debounce — the seam's synchronous scored decision has no SDK conformance. **Branch B
   recorded: `ParakeetEOU` ships PENDING; `SilenceThresholdDetector` is the shipped
   `TurnDetector` implementation**, the H8b family amendment confines the EOU SDK names
   (`StreamingEouAsrManager`, `StreamingChunkSize`) with **no permitted file**, and a future
   conformance must earn a reviewed permit.
2. **Version: no bump.** The pinned `from: "0.12.4"` range resolved **0.15.7** (revision
   `41540ea237350afe5117a082b5c28eda642d0612`) in this worktree and already carries the full
   VAD/EOU surface; `Package.swift` untouched. `0.x` semantics mean a future 0.16+ resolves
   silently — surfaced in the pin family and the adapter suite, never assumed.
3. **The license caveat, surfaced not absorbed:** the `FluidInference/silero-vad-coreml`
   artifact repo carries **no LICENSE file** — MIT is claimed by the HF card metadata + README,
   never verifiable from a repo LICENSE; the SDK itself re-verified Apache-2.0. Surfaced to the
   integrator, recorded, not silently absorbed.
4. **The VAD artifact is the bare `.mlmodelc` directory** (`silero-vad-unified-256ms-v6.2.1
   .mlmodelc`, five files) — the manifest follows the per-file pattern of
   `parakeet-tdt-0.6b-v3.json`, staged under `<root>/silero-vad/1/vad/`; the SDK's `VadManager`
   "Beta Status" doc comment is recorded as an adapter risk note, not a blocker.

**What shipped, per aspect.** *sdk-vetting* (93220c6, b43c0ea; 1978 → 2009): the findings above
as provenance pins (`SileroVadProvenanceTests`), the `silero-vad.json` manifest with digests
from the actual provisioned bytes, and `Scripts/provision-vad-fixtures.sh`. *voice-detection*
(cf26a6c, 3683ccc, a64e33b; 2009 → 2041): the `VoiceActivityDetector`/`TurnDetector` seams in
VoccaCore, the `EnergyVAD` + `SilenceThresholdDetector` pure fallbacks, and the seam-family
lint with planted-violation/comment-strip controls. *streaming-capture* (9985f9d, da8dd05,
530f504; 2041 → 2054): the `ContinuousAudioSource` seam + its first conformance
`StreamingCapture` (the ownership contract — one consumer, a second start refused), and the
capture-path no-touch pin (SHA-256 digests of `MicrophoneSource`, `SpeculativeFeed`,
`AudioRingBuffer`). *playback-ducking* (f3bb679, 245736a, 09a3fb6, e324ecc; 2054 → 2080): the
four-op `PlaybackEngine` seam + `PlaybackLevel` (duck gain 0.5, 20 ms ramp), `SystemPlayback` —
`VoccaAudio/Playback/`'s first file — with `SystemPlaybackOutput` behind the
`PlaybackOutputSeam`, the reviewed AVFoundation import-set amendment, the playback family lint,
and the **offline manual-rendering tests landed green** (sample-for-sample rendering, duck/halt
as ramps over exactly the ramp, ring-capacity drain — no environmental fallback was needed).
*sdk-adapters* (a342883, d97300c, 146a30b; 2080 → 2095): `SileroVAD` over `VadManager` — the
identity conversion at the 256 ms model chunk, the sync→actor bridge with its blocking cost
measured by the env-gated suite, the offline pin (`ModelHub.offlineMode`, pre-loaded init only,
lazy load, memoized error) — the H8b VAD/EOU family amendment, and the env-gated
`SileroVadRealSuiteTests` (two-variable gate; visible skips count as executed). *barge-in-loop*
(dd3fdc5 … 8e0e9e7; 2095 → 2160): the `TurnTakingLoop` coordinator (the `SessionMachine` shape —
synchronous, owner-isolated, never an actor; the review-gate pins: stream continuity, the
reply-end race in both orderings, one-consumer ownership), the `EchoGate` (correlation ≥0.90
discards, the reference-cancellation residue line with its two conditions, silence during
playback never gates), the `TurnCommitmentScorer` (5×/2×/1× weights, inclusive 0.95 bar, the
empty-corpus throw) with the scripted corpus + harness (the planted-false-cutoff corpus
genuinely fails), the composed headless acceptance, `PROBE-TURN` + the zero-network
post-condition, the dictation-path digest pin (SessionMachine/DictationPipeline/AppBootstrap),
the env-gated composed real suite (three rows, behavior not numbers), the seam-name lint
amendment (the loop admitted to both rows — RED captured first), and the floor ratchet.
*record* (this entry): SMOKE 131-133 written runnable; STATUS/CLAUDE.md/ARCHITECTURE.md synced;
the floor verified, never ratcheted.

**Measured (recorded, never gated):**
- The real VAD's per-chunk classify cost, measured 2026-09-15 on the founder's machine through
  the env-gated suite (warm — one full fixture pass consumed first): verbatim row
  `VAD-CLASSIFY-LATENCY 0.2ms chunks=… recorded-never-gated` — the sync→actor bridge included;
  the 200 ms budget decomposition's recorded input, never a gate.
- The composed **headless** halt over the injected clock at the contract thresholds: **70 ms**
  (stub cancel 50 ms + duck ramp 20 ms; the coordinator's own contribution asserted ≤50 ms,
  `tSilence − tSpeech ≤ 200 ms`) — labeled headless, never a real claim; the real number is
  SMOKE 132's.
- The conversational harness in CI: passing corpus **1.0000** (11 boundaries, zero false
  cutoffs), the planted-false-cutoff corpus **0.0000** (5/5 false cutoffs — a gate that cannot
  fail proves nothing), the late-commit corpus **0.2500** (L=3, C=1) — CI facts with margins,
  never gate passes.
- SMOKE 131-133 are **written and runnable, not yet executed**: the ≥95% founder-recorded-set
  commitment row, the ≤200 ms real-playback halt row (`TURN-HALT <ms>ms recorded-never-gated`),
  and the 0-instances-on-speakers echo row (`ECHO-LOOPBACK <device> recorded-never-gated`) land
  when the founder runs them — this aspect's merge does not depend on their execution.

**The honesty block:**
- **No P2/P3 gate passes.** The P3 gate (`ROADMAP.md:215-219`) needs a full spoken exchange
  with real barge-in — the CONVERSING surface is C11's; the ≤200 ms halt, ≥95% commitment and
  0-echo numbers are SMOKE rows, never gates. P2 unchanged.
- **Numbers recorded never gated.** Every measured row above is recorded verbatim — an
  over-budget number (a 340 ms halt, a 92% commitment, 1+ echo instance) would be recorded
  verbatim too, never a pass.
- **No user-visible surface ships.** No silent listening state can exist: continuous capture is
  composed only in the probe drive and the env-gated suites; the loop holds no mic seam, and
  nothing wires the loop into the app until C11.
- **The dictation path is byte-for-byte untouched** — digest-pinned twice over (the
  streaming-capture capture-file pin and the barge-in-loop
  SessionMachine/DictationPipeline/AppBootstrap pin), asserted in the floor's ledger.
- **Zero network.** The zero-network interposer stays green over `PROBE-TURN`; the VAD artifacts
  provision through the C2 store (`Scripts/provision-vad-fixtures.sh`, digest-verified, never
  inside `configure`); nothing in the loop names an SDK or constructs a URL.
- **Interim states recorded, not papered over:** `ParakeetEOU` PENDING with the ASR-integrated
  shape named (Branch B); `PlaybackEngine` has one implementation; `ContinuousAudioSource` has
  one conformance; `VoccaAudio/VAD/` stays a paper reservation while the real adapter lives in
  `VoccaASR/VAD/` (the H8b confinement); the license caveat above stands.
---

**The `kokoro-binding` unit's implementation shipped 2026-09-14 — C9 is complete: the runtime
decision is now IMPLEMENTED, not just resolved.** `feat/kokoro-binding/aliz`. The vetting gate
passed with three recorded corrections; `KokoroEngine` is the seam's second real
`SpeechSynthesizer` (Kokoro + SystemSynthesizer — the two-implementation doctrine is now
satisfied), provisioned through the C2 store and injected from the composition root; the first
Kokoro TTFA measured **232.5 ms** (SMOKE 130, recorded, never gated). Floor **1978** (executed
2006). **No gate passes; no user-visible surface ships in this unit.**

**The three vetting corrections, recorded by name** (verified against the port's code and the
provisioned artifact, not the PRD's prior claims — `docs/planning/_card/understanding.md`):
1. **Phonemization is NOT Misaki.** The port bundles its own English G2P (`EnglishG2P`,
   lexicon + morphological stemming + number expansion, `us_gold.json`/`us_silver.json` in
   package resources) with a **BART neural fallback** via `Jud/swift-bart-g2p` (Apache-2.0,
   models bundled in resources — no runtime download). The record's "Misaki (hexgrad's G2P)
   replaces espeak-ng" claim is corrected everywhere it was written.
2. **Toolchain: the dependencies declare `swift-tools-version: 6.2`** — Vocca CI was pinned to
   Xcode 16 (Swift 6.0/6.1), which cannot resolve them. CI moved `XCODE_MAJOR: "16" → "26"`
   (`.github/workflows/ci.yml:58`; the macos-15 runner's Xcode 26.0.1–26.3 verified at plan
   time; `XCODE_MAJOR: "26"` resolves to 26.3). Local toolchain Swift 6.3.3 / Xcode 26.6.
3. **The artifact is the single `models-2026-03-23` tarball, `vocab_index.json` absent.** The
   provisioned `kokoro-models.tar.gz` contains the frontend/backend `.mlmodelc` pair +
   `voices/` (incl. af_heart `.bin`) — and **no `vocab_index.json`** (unlike the PRD's assumed
   shape). The port's **bundled-tokenizer fallback** covers it; the manifest pins the tarball
   (sha256 `0d24bb…aec9`, 103,394,124 bytes from the actual provisioned bytes), extracted
   idempotently (`/usr/bin/tar xzf`, trio marker: frontend + backend + `voices/`).

**What shipped, per aspect.** *port-vetting* (the unit's first commit `34725cf`): the
`KokoroDependencyTests` provenance pin (kokoro-coreml package URL in `Package.swift`, the
`VoccaSpeech` → `KokoroCoreML` product edge, the `VoccaBootstrap` → `VoccaSpeech` edge), the
`KokoroCoreML` dependency landing (`from: "0.11.2"`, `.upToNextMinor`), the CI Xcode 16 → 26
bump, and the floor's first raise (1949 → 1952, executed 1980). *engine-binding* (`65f80b6`,
`f49e56e`, `082afb2`): `KokoroEngine: SpeechSynthesizer` in the one seam file
`VoccaSpeech/Kokoro/KokoroEngine.swift` — `identity.engineID == "kokoro-82m"`, plain-data init
(model directory, voice, rate; **init pure-local** — the port's init does file IO + spawns a
warmup thread, so the port engine is constructed lazily on first speak, no download, the
probe's contract), one port `synthesize(text:voice:speed:)` per `SentenceChunker` sentence
(the PRD R1b guaranteed cancel path; the port's streaming `speak()` and its AVFAudio surface
deliberately unused), Float32-little-endian sample→chunk conversion (24 kHz mono, duration =
count/24000), cancel via the generation-tagged flag **finishing the stream without waiting for
the in-flight synchronous call** (dropping the orphaned result by generation — the ≤50 ms
contract doesn't depend on the port's ~100 ms/chunk calls), empty-speak short-circuit before
any port touch, the absent-models error mapped to `KokoroEngineError.modelsUnavailable`. The
deliberate **family lint** (`KokoroSeamBoundaryTests`): the Kokoro-runtime family (Kokoro,
SpeakEvent, SynthesisResult, VoiceStore, EnglishG2P, BARTG2P, Phonemizer) confined to that one
file, no AVFAudio/AVFoundation import, no URLSession (the port's downloader is never reached
from the seam file). The **probe leg** (`SpeechDrive.swift`): the zero-network probe now drives
the Kokoro engine's default work — construct + empty-speak + cancel — inside the interposer.
The **env-gated suite** (`SpeechKokoroSuiteTests`): the same `SpeechFixtureSuite` body over the
real engine, gated on `VOCCA_RUN_REAL_SPEECH` **and** `VOCCA_KOKORO_MODEL_DIR` (the
two-variable pattern; CI runs the visible skip path) — fixture duration floors
(three-sentence-reply ≥1.0 s, short-reply ≥0.25 s), chunk ordering + per-chunk duration > 0,
cancel ≤50 ms wall-clock, re-invoke full render, and the KOKORO-TTFA row. *provisioning*
(`8f9113c`, `c1da5a7`): the **manifest machinery** — `KokoroModelManifest` (the parallel
loader beside the EngineTier-closed `ShippedModelManifest`, which does NOT grow),
`TarballExtractor` (idempotent, trio-marker-guarded, failure-loud on empty/corrupt archives),
the committed `kokoro-82m.json` manifest with digests from the actual provisioned bytes, the
`fixture.tar.gz` committed test fixture, and `Scripts/provision-kokoro-fixtures.sh`; the
**launch provisioning** — `AppBootstrap.kokoroModelRepository` (the pinned `models-2026-03-23`
release base), `prepareSpeechModels(store:)` (load manifest → `downloadIfMissing` → extract
into `<store>/kokoro-82m/1/kokoro`; sequenced **after** ASR preparation — the store's
single-flight slot is not per-manifest — and **never** from `configure`, so the probe contract
holds), and `kokoroSynthesizer(store:)` injecting the extracted path into the real
`KokoroEngine`. The digest-verification suite gained the TTS row (env-gated on
`VOCCA_MODEL_DIR`, sibling to the EngineTier loop).

**Measured (recorded, never gated — SMOKE step 130):** warm-run time-to-first-chunk on the
real Kokoro engine over `three-sentence-reply` = **232.5 ms** (verbatim line:
`KOKORO-TTFA 232.5ms fixture=three-sentence-reply baseline=178.8ms budget=300ms
recorded-never-gated`) — under the P3 ≤300 ms budget (`ROADMAP.md:209`), **above** the system
renderer's ~178.8 ms baseline (SMOKE 129), both real implementations measured through the same
fixtures. The env-gated real suite passed on the founder's machine (2 tests, 0 failures —
duration floors, chunk ordering, cancel ≤50 ms wall-clock, re-invoke full render); the CoreML
first compile (E5RT type-inference messages on first run) is a **prepare cost, never speak
latency** — the TTFA number is warm by construction. No skip message printed (the tell-tale —
a skipped run never records a number).

**The honesty block:**
- **No P2/P3 gate passes.** The P3 gate (`ROADMAP.md:215-219`) needs a full spoken exchange
  with barge-in — C10 is unbuilt; the TTFA number is a recorded measurement, never a gate. P2
  stays uncleared (the matrix feature closed by founder decision, unchanged).
- **TTFA recorded, never gated.** 232.5 ms is a SMOKE row, not a gate pass; an over-budget
  number would have been recorded verbatim.
- **No user-visible surface ships in this unit.** The engine's speak cannot be user-visible —
  playback/ducking is C10's (`VoccaAudio/Playback/`), the converse surface is C11's; the app
  has no speak surface this unit.
- **The seam doctrine's two-implementation state is now satisfied.** `SpeechSynthesizer` has
  two real, shipped implementations — Kokoro (`VoccaSpeech/Kokoro/KokoroEngine.swift`) and
  SystemSynthesizer (`VoccaSpeech/System/SystemSynthesizer.swift`) — the ROADMAP principle-4
  interim state recorded in the C9 first-half entry is closed.

---

**The `kokoro-binding` unit concluded at the PRD gate 2026-09-12 — the runtime decision C9
left open (`ARCHITECTURE.md:706`) is **made and recorded**; the binding's implementation is
deferred by founder decision to the next implementation unit, with the decision's vetting gate
named as its first step.** No code shipped; the planning artifacts (card, understanding, PRD)
are the unit's deliverable.

**The decision, made and recorded (four founder-ratified choices, 2026-09-12):**
1. **Runtime family: CoreML/ANE via a Swift port** — the Parakeet precedent (CoreML/ANE, one
   seam file, SPM dependency). The 2026-09-12 research found the Swift Kokoro ecosystem
   mature: pre-converted models on HuggingFace, Apache-2.0 ports, and **Misaki (English G2P
   on Apple NaturalLanguage) replacing espeak-ng** — the recorded "hidden cost of every
   option" is solved for English without a phonemizer dependency.
2. **Port: Jud/kokoro-coreml** (Apache-2.0, SPM, streaming chunks at sentence boundaries,
   ~99 MB 8-bit palettized model, 24 kHz mono PCM, macOS 15+) — vetted at the follow-on
   unit's plan gate (license, model provenance, phonemization, per-sentence cancel semantics
   verified against the port's code, not its README); mweinbach's packages are the recorded
   alternates (license review pending).
3. **Provisioning: DI from the composition root** — `KokoroEngine(modelDirectory:voice:)`
   receives a provisioned path as plain data; `VoccaBootstrap` provisions via the existing
   string-keyed store machinery (reusable unchanged); no module-boundary amendment;
   the port's own downloaders never run (zero-network default).
4. **Voices: one** — af_heart in the initial manifest; the 54-voice on-demand downloaders
   suppressed; more voices later via the store.

**The reservation overturn, recorded:** `ARCHITECTURE.md`'s VoccaBridge C-shim reservation
(for "Kokoro (C9) would be the first candidate", `:43-51`) is **overtaken by the ecosystem** —
the whisper precedent itself says a C-ABI bridge "needs no module boundary of its own; it only
needs the lint", and no maintained Swift-Kokoro-on-onnxruntime path exists. The bridge stays
reserved for a genuinely second C-ABI consumer; Kokoro is not it. The binding's guaranteed
cancel path is the SystemSynthesizer pattern (one render per sentence, cancel between calls) —
the ≤50 ms contract does not depend on the port's streaming shape.

**What this is NOT, and must not be claimed:**
- **No Kokoro engine ships.** The `SpeechSynthesizer` seam still has one real implementation
  (SystemSynthesizer); the two-implementation doctrine's interim state stands until the
  follow-on implementation unit lands the binding (its first step: the vetting gate).
- **No TTFA number exists for Kokoro** — SMOKE 129's ~178.8 ms row is the system renderer's
  alone; a Kokoro number is unmeasured until the engine exists.
- **The P3 gate stays uncleared** (unchanged, recorded posture); the runtime decision is a
  record, not a gate.

---

**C9's first half landed 2026-09-12 — the `SpeechSynthesizer` seam is real, the system
renderer is the shipped first implementation, and the first time-to-first-audio measurement
came in **under the P3 budget** (~178.8 ms vs the ≤300 ms target), recorded, never gated.**
`feat/kokoro-voice-output/aliz`. Floor **1930 → 1949** (the deliberate ratchet — the last
units' "floor 1936 → 1949" claims were executed counts never written into the script; the
raise now rides with the tests it counts). Executed count: **1977**.

**What shipped (test-first, RED→GREEN, three commits + this record).** *The seam*
(`Sources/VoccaCore/Speech/`): `AudioChunk` (PCM plain data), `VoiceIdentity` (engine +
voice, plain), the `SpeechSynthesizer` protocol (`identity`; `speak(_:) ->
AsyncThrowingStream<AudioChunk, Error>`; `cancel() async` with the documented ≤50 ms halt
contract + prompt stream termination + safe re-invoke — C10's barge-in depends on it), and
`SentenceChunker` (sentence boundaries keeping punctuation, the shipped shallow
abbreviation rule: a `.` followed by whitespace-or-end is not a boundary after a vowel-free
letter token like `Mr.`/`Dr.`/`St.`; a no-boundary run stays whole). The seam's contract is
pinned by stub tests (identity, empty-text → empty stream, ordering, cancel mid-stream,
cancel-then-reinvoke) and the parameterized suite body runs over the stub in CI. *The first
real implementation* (`VoccaSpeech/System/SystemSynthesizer.swift`): `AVSpeechSynthesizer`
`write(_:toBufferCallback:)` rendering — one utterance per sentence chunk, `AVAudioPCMBuffer`
→ `AudioChunk` conversion, a generation-tagged write queue where **cancel sets a flag and
resumes the waits rather than `stopSpeaking`** (the real renderer showed that
`stopSpeaking(at: .immediate)` kills the aborted write's completion signal and with it the
re-invoke — found and fixed test-first on the founder's machine; the ≤50 ms halt contract
holds via the flag path), voice + rate as plain data inputs (knobs for the follow-on UI),
zero network by construction. *The deliberate lint amendments:* `VoccaSpeech` moved
leaf → adapter (`ModuleBoundaryTests`), the AVFoundation expected-import set gained the new
file, and the seam-family pin confines AVSpeechSynthesizer/AVFAudio names to that one file
(planted-violation test). The zero-network probe now drives `VoccaSpeech`'s real default
work (construct + empty-speak + cancel) — the module-coverage cross-check passes.

**Measured (recorded, never gated — SMOKE step 129):** time-to-first-audio on the system
renderer over `three-sentence-reply` = **~178.8 ms** (under the P3 ≤300 ms budget,
`ROADMAP.md:209`); the env-gated real suite (`VOCCA_RUN_REAL_SPEECH=1`) passes — duration
floors, chunk ordering, cancel ≤50 ms wall-clock, re-invoke — on real speech on the
founder's machine.

**The two-implementation doctrine's interim state, stated honestly:** ROADMAP principle 4
wants two real implementations shipped. This unit ships one (SystemSynthesizer) because the
second — **Kokoro-82M — is blocked on the open architecture decision**
(`ARCHITECTURE.md:706`: C/C++ shim via the reserved `VoccaBridge` vs ONNX/CoreML on the ANE
vs bundled MLX — founder-ratified to record, not force, 2026-09-12). **The follow-on unit:
`kokoro-binding`.** The options ranked: (1) C/C++ shim via `VoccaBridge` (the architecture's
own reservation, `ARCHITECTURE.md:43-51`); (2) ONNX→CoreML on the ANE (the Parakeet
precedent); (3) bundled MLX path. **The hidden cost of every option is the phonemizer** —
Kokoro is not end-to-end: text → espeak-ng phonemes → model — so each binding carries a
phonemization dependency that must be provisioned like the C2 model store. The parameterized
suite is written so the Kokoro adapter joins by adding one entry.

**What this is NOT, and must not be claimed:**
- **No P3 gate passes.** The P3 gate (`ROADMAP.md:215-219`) needs a full spoken exchange with
  barge-in — C10 is unbuilt; the TTFA number is a recorded measurement, never a gate.
- **The unit ships no user-visible surface** (ratified: seam only; playback/ducking is
  `VoccaAudio/Playback/`, C10's concern; the widget's CONVERSING surface is C11's).
- **No audio is played by this code** — rendering only; the seam yields PCM chunks.
- **The P2 gate is uncleared** — the matrix feature closed by founder decision; this unit
  builds ahead of the gate with that posture named in the record.

---

**The matrix feature is CLOSED by founder decision 2026-09-12 — including its final
`electron-target-resolution` unit, whose live proof was waived.** The record stays honest: the
feature is closed, not finished. Test floor **1936 → 1949**.

**What shipped (the feature's last code).** *The gated frontmost-app fallback*
(`feat/electron-target-resolution/aliz`, PR #33, merged `db08249`): in Chromium/Electron apps
the AX focused-app read answers "nothing focused", so the ladder refused at rung 0 with
`.noFocusedField` and clipboardPaste — which needs no AX field — never ran (5 of 20 matrix
rows blocked; evidence: 5 recovery journals + usage ledger 2026-09-11, 2 delivered / 5
failsafeHeld). The fix, test-first (RED compile pins → GREEN; commits `fa62d0a`, `ad94351`):
a `FrontmostAppReading` seam + `SystemFrontmostApp` adapter (the only `VoccaInject` file
naming `NSWorkspace` — one-file family row with planted-violation pins), and a **gated**
fallback in `TargetResolution.resolve()` that fires only when AX answers nil AND the frontmost
app is `.regular` AND not in the seeded no-field set (`SeededNoFieldApps = ["com.apple.finder"]`
— Finder *is* the desktop; dock/menu-bar/utility apps are `.accessory` and excluded by the
policy gate). `windowTitle` nil on fallback; Secure Input read once, fresh, precedence
untouched. **`InjectionLadderDecision.swift` and `TargetContext.swift` are byte-for-byte
untouched** (pinned): `bundleID == nil` still means a genuine no-field refusal, and the
desktop case is structurally refused. The fallback never consults the frontmost read when AX
answers (M6 read-count pin). Three founder decisions ratified in the PRD (2026-09-12): the
gate, the seeded exclusion set, windowTitle nil.

**What the closure means — and what it does not.** The `electron-matrix-proof` aspect was
**concluded by founder decision without executing the live run**: the 5 Electron rows were
never re-run on a v0.3.1 build, the desktop-refusal negative proof never ran, and the fix's
empirical halves (that `NSWorkspace.shared.frontmostApplication` answers Electron apps, and
that the fallback's clipboardPaste then delivers in them) are **unverified-live at closure** —
the gate's logic is tested headlessly; its live truth is not. The tracked table stands as
recorded (v0.2.1 and v0.1.0 rows; **no v0.3.1 row is added** — none was run). **FMS remains
not computable. No gate passes. No injection-success percentage may be quoted.** The feature's
open threads at closure, named so the record cannot be misread as completion: step 92
(Passwords, PasswordField) unexecuted; GoogleDocs unrun; the 3 permanent skips
(Ghostty/IntelliJ/Zed) and the 17/20 ceiling record stand; the P2 gate's external-users leg
unbegun; the P0 gate's 7-day accumulation and the P1 gate's blind ballot still open elsewhere.

---

**The `injection-matrix-completion` unit concluded 2026-09-12 by founder decision — two harness
changes shipped test-first, the run recorded 7 of 17 installed deliverable rows with every
recorded row landing its expected rung, and the unit stopped on a **real product defect, not a
harness defect**: the ladder cannot resolve a target in Chromium/Electron apps, so five rows
are blocked, not failed. Test floor **1930 → 1936**. Branch `feat/injection-matrix-completion/aliz`.

**What shipped (test-first, RED→GREEN).** *The self-capture guard* (`d2fd842`): a terminal-class
row whose target terminal is the harness's own host terminal can no longer record a PASS —
`host_terminal_bundle_id()` walks the parent-process chain to the hosting terminal's bundle id,
`is_self_capture` fires only on equal non-empty ids, and `run_row` VOIDs with the named reason
`self-capture: harness runs inside the target terminal` before any copy; self-check pins cover
the predicate's three edges, the host-id shape, and the wiring (grep pin); planted-violation
tests were RED first (the guard did not exist) and GREEN after. Live-proofed (T5): `--row Warp`
run from inside Warp → `verdict: voided, note: "self-capture: harness runs inside the target
terminal"`, exit 3, one JSONL line (`20260909-t5-selfcapture-proof.jsonl`) — a self-capture PASS
is now structurally impossible. *The memory-ordered FMS question* (`7adaf0f`): the y/N
expected-rung question is replaced by a landing-rung observation (closed vocabulary, `none`
refused for deliverable rows) + the `attempted:` first-method fact; verdicts now record a
demotion-honored delivery (bytes matched, landed on the memory's first choice after the expected
rung was demoted) as a **PASS** with the note naming it, and the tally prints both numbers —
first-method-success (memory-ordered) and expected-rung landings — the metric the P2 gate
(`ROADMAP.md:172`) actually names. `log_run_row` records the observed landing rung on every
deliverable row; schema unchanged. RED pin first, planted-violation GREEN. The unit also
produced the planning artifacts (`5e6a23d`): resumption card, understanding note, PRD rev
(2026-09-09, four founder-ratified decisions), three aspect specs and plans.

**The run (2026-09-10, installed v0.3.0 build, `20260910-v03.jsonl` + recovery journals).**
7 of 17 installed deliverable rows recorded, **all 7 landing their expected rung**:
- **Notes, Mail — re-probe landed.** The `.accessibility` demotion re-probed (window opened
  2026-09-10) and **won in both apps** — the promotion was observed, the demotion restored
  (`strategies.json` Notes shows `demotedRungs: []`). This closes the demotion-honored question
  positively: the memory re-discovered the rung it had written off.
- **Safari, Messages, Firefox, Terminal, Warp — `.clipboardPaste` landed.** Messages' earlier
  grant-void was re-run to a pass within the same run. Terminal/Warp ran from non-target
  terminals (Warp for Terminal's row, Terminal.app for Warp's), provenance founder-reported —
  the guard-harness re-runs that make that mechanical are pending.
- Under the ratified memory-ordered definition, all 7 recorded rows were also first-method
  successes (landing rung == first `attempted:` rung); expected-rung landings: 7 of 7.
**FMS is still not computable over the 17** — 5 rows blocked, 1 unrun (GoogleDocs), 3 permanent
skips (Ghostty, IntelliJ, Zed → ceiling 17/20 vs the ≥19/20 bar, structurally unreachable on
this machine, recorded not failed); step 92 (Passwords, PasswordField) unexecuted — the Secure
Input gesture could not complete because capture is blocked by design while a password field is
focused (the tap cannot fire; the corrected gesture — dictate in a normal app, switch focus to
the password field before release, refuse at injection time — was delivered but not executed).

**The defect that stopped the unit — escalated as the next unit, not fixed here.** In
Chromium/Electron apps (VSCode, Teams, Discord, ChatGPT, Obsidian) the dictation completes but
the delivery **refuses at rung 0**: `AXSource.focusedApp()` answers "nothing focused"
(`kAXFocusedApplicationAttribute` answers nil — fast, within the 0.5 s budget), so
`TargetContext.bundleID == nil` and `InjectionLadderDecision.swift:101` fires
`.noFocusedField` **before any rung** — clipboardPaste, which needs no AX field, never runs.
Evidence: 5 recovery journals, all `{"reason":"noFocusedField", ...}`; the usage ledger
(2026-09-11: **2 delivered / 5 failsafeHeld** — the failing sessions); the failing set is
exactly the Chromium apps while every native/WebKit/Gecko app resolved fine (Sep 10: Notes,
Mail, Safari, Messages, Firefox, Terminal, Warp). The transcript was never lost — every refusal
landed in the widget failsafe, the invariant held. **The fix is a seam-level decision** (the
`.noFocusedField` refusal exists to stop text landing in the wrong place; a blind frontmost-app
fallback could paste into Finder/desktop — the silent-drop shape this product exists to forbid),
so it gets its own PRD: a gated frontmost fallback whose gate distinguishes a Chromium "nothing
focused" lie from a genuine no-field state. See the `vocca-next` handoff for the unit card.

**What this is NOT, and must not be claimed:**
- **No gate passes. No injection-success percentage may be quoted.** 7 of 7 on recorded rows is
  not a matrix rate; the denominator over 17 is not computable with 5 blocked + 1 unrun + 3
  skips.
- **The 5 Electron rows are blocked, not failed.** They have a named defect and a named next
  unit; the runs left them untried-by-the-ladder (rung 0 refusal, not a rung failure).
- **The Sep-10 rows ran against the master harness** (the founder ran from the primary
  checkout; the run log's first Safari line carries the old note text). The guard + landing-rung
  harness shipped in this unit was not the one the rows ran on — the T5 proof and the
  guard-harness re-runs are the pending half of the provenance question.
- **Step 92 and GoogleDocs are unexecuted**, and the 17/20 ceiling stands.

---

**The `daily-use-ledger` unit landed 2026-09-07 — the P0 gate's observable legs became recorded
evidence rather than founder memory, and one of them turned out not to be computable at all.**
Five aspects, on `origin/master` @ `6ac909f`. Test floor **1758 → 1930**.

**The defect found first, which reshaped the unit.** `SessionOutcomeClass.failed` was recorded at
six sites and only one of them meant a transcript was lost: `DictationPipeline.swift:376`, where
the ladder reached `.widgetFailsafe` and the journal refused custody. The other five — two stream
failures, a transcribe failure, and two bootstrap terminals — each produced nothing, and three of
them say so in their own code comments. So a count of `.failed` was not a loss count, and the P0
gate's hardest leg (`ROADMAP.md:96`, transcript loss at exactly zero, "no acceptable non-zero
value") was **unmeasurable in principle, not merely unpersisted**. `.lost` now separates them,
recorded at exactly one site, pinned by a source scan. Site 376 has two callers, not one: the
onboarding injector reaches it too, and never holds, so a refused TRY IT is a lost transcript.

**What shipped.** `SessionKind` on every record, so a setup demo is separable from real work.
`CalendarDay` with proleptic-Gregorian day arithmetic, written because `VoccaCore` imports nothing
and has no `Calendar`. `DayAggregate`'s fold, total over six outcome classes and both kinds.
`UsageWindow`: 30 days, oldest evicted on insertion, and a streak that counts only days a
transcript existed — `delivered`, `failsafeHeld` or `lost` — so a stray hotkey press, a
cancellation, and a day of nothing but transcription failures do not extend it. A bounded latency
histogram whose bounds straddle the P2 targets, so "is p95 ≤ 800 ms?" is answered exactly.
`VoccaUsage`, a new adapter module, persisting `~/Library/Application Support/Vocca/usage.json`
atomically. The wiring: a synchronous ledger sink, folds held until the launch load returns, and
writes on rollover, on termination, and otherwise debounced at 60 s — never inside a dictation.
And a sixth Settings tab, **Usage**.

**What this is NOT, and must not be claimed:**
- **No gate passes.** This instruments the P0 gate; it does not meet it. Seven consecutive days of
  founder dictation have still not accumulated, and no streak number exists yet because no real
  session has been folded on this machine.
- **The gate's third leg is untouched.** Injection success "≥90% across the matrix"
  (`ROADMAP.md:102`) belongs to the matrix harness, which remains at 10 of 20 deliverable rows and
  structurally capped at 17/20 here. The Usage tab's rung tallies are counts of what happened and
  are **not** an injection-success rate; the tab is written so it cannot render one.
- **No latency claim.** The histogram reports bucket bounds, never spot values, and a day that
  measured nothing reads `not recorded`, never `0 ms`.
- **The founder has not seen the tab with real data in it.** Everything is headless: 1930 tests, a
  probe drive, and temp directories. `~/Library/Application Support/Vocca/usage.json` does not
  exist on this machine.

**Two postures deliberately revised, not drifted.** `latency-instrumentation/prd.md:118-120` wrote
that the ledger "never leaves the process"; it now persists, shape-only and user-clearable, with
the byte-level pin asserting no transcript text and no wall-clock time can appear in the file.
And `ARCHITECTURE.md:596` reserved `metrics.sqlite` for this data; it now names `usage.json`, with
the reasoning recorded.

---

**The injection matrix resumed 2026-09-05 and stopped again at 10 of 20 deliverable rows —
6 firmly recorded, 4 voided, and one harness defect found and fixed test-first.** The run
continued on v0.2.1 after the `injection-matrix-completion` unit's early conclusion.
**Expected rung landed (4):** TextEdit `.accessibility`; Xcode, Telegram, Chrome
`.clipboardPaste`. **Delivered but missed the expected rung (2):** Notes and Mail — bytes
matched; `.accessibility` is demoted with a re-probe window to 2026-09-10, so the ladder
fell through to clipboard. That is the demotion-honored outcome and is recorded as a miss,
not a defect. **Voided (4), each reason named:** Messages and Firefox failed the
byte-compare twice each, adjudicated to a **harness** defect rather than to ASR or
injection — `open -a` returns before a cold-launched application is up, and the activation
that followed it was `|| true`, so the select-all/copy captured whatever was frontmost.
Both rows were cold-launched; every row that passed that hour was already running. The
display-name hypothesis was tested and **rejected**, not assumed: with both applications
running, `set frontmost of process "Firefox"` returns 0 even though Firefox's System Events
process name is lowercase `firefox`. Terminal and Warp are voided as **indistinguishable**
rather than as failures — the harness runs inside a terminal, so for the terminal rows the
capture can be its own scrollback, which holds the phrase the script just printed; under
the containment semantics of `386f433` that satisfies the compare, so a pass cannot be told
from a self-capture. **FMS not computable** (4 of 20 landed the expected rung, on 6 firmly
recorded rows), and the ≥19/20 bar is **structurally unreachable on this machine** — 3
permanent skips (Ghostty, IntelliJ, Zed, no same-class swap) put the ceiling at 17/20. A
recorded outcome, not a failure.

**The defect fix (`1985da6`), test-first:** activation now keys on the bundle identifier
`--verify-bundle-ids` confirms against a real `Info.plist` rather than the display name
nothing checks, polls up to 10 s for the row's application to actually come frontmost, and
**VOIDs — never fails** — a capture taken from anything else. Pins go RED against the prior
behavior (24 failures, exit 1) and GREEN after; bundle-id activation and the frontmost read
were live-verified against a running application with focus restored. The failure this
forbids is the dangerous one: since `386f433` gave the compare containment semantics, a
capture from the harness's own terminal can *satisfy* it and record a PASS for a row nothing
was injected into. Floor 1758 → 1760 tests, 0 failures.

**What this is NOT, and must not be claimed:**
- **No gate passes.** The P2 gate needs latency targets **and** ≥95% matrix **and** ≥5
  external users; the matrix leg cannot reach its bar on this machine and the external-users
  leg has not begun. The P0 gate is also unmet — its 7 consecutive days of founder dictation
  have not started accumulating.
- **No injection-success percentage may be quoted.** 4 of 20 rows landing their expected rung
  is not a success rate; 7 deliverable rows have never run and step 92 is unexecuted.
- **Terminal and Warp are not passes.** They are voids pending a re-run driven from a terminal
  that is not the row's target. Asserting a pass whose capture provenance is unknown is the
  same error as asserting a byte mismatch without knowing the selection was made — this
  repository's own first preamble rule, applied symmetrically.
- **The remaining rows are unrun, not failing.** VSCode, Teams, Discord, ChatGPT, Obsidian,
  Safari and GoogleDocs have no result of any kind.

---

**The `unmeasured-numbers-sweep` F2 real-corpus run landed 2026-09-05 — the corpus
requirement is met; the blind-judge requirement is not.** The founder recorded the 42
scripted utterances (7 per class, 16 kHz mono, `~/Vocca/f2-pairs/`); the raw side of every
pair is the real Parakeet engine transcript of the founder's voice. The ballot
(seed `0xFAF5A4891B414AC4`) was answered by a **delegated, non-blind judge** (the sides are
identifiable to the answerer), so the preference figure is recorded but does not satisfy the
P1 gate's blind-judge requirement. Result: preference 100.0%, per-class 7/7 across all six
classes, verdict `RECORDED, not gated` vs 0.8. No re-baseline; `ProvisionalCleanupTargets`
untouched. What this is NOT, and must not be claimed: no *blind* human preference number
exists — the gate's judge half takes one fresh ballot answered by the founder (~2 minutes)
to close. The 2026-09-05 stand-in run (TTS corpus) remains recorded below as the mechanism
demonstration it was.

---

**The `unmeasured-numbers-sweep` F2 stand-in run landed 2026-09-05 — recorded, not gated,
and explicitly NOT the F2 number.** At the founder's request the F2 flow was exercised with
a fully synthetic corpus: macOS `say` (Samantha) generated 42 utterances (7 per class,
16 kHz mono) into `~/Vocca/f2-pairs/`, the real Parakeet engine transcribed them as the raw
side, and the ballot was answered by a **delegated, non-blind judge** (the sides are
identifiable to the answerer). Result: preference 100.0% (41 cleaned-preferred, 1 tie
excluded), per-class 7/7 ×5 and 6/7, verdict `RECORDED, not gated` vs 0.8. The run is
**doubly disqualified** from the P1 gate: SMOKE 73's own first line ("the stand-in corpus is
provably recoverable by the shipped rules, so its percentage measures the mechanism, not the
product") and the non-blind judge. **No row lands in `tolerances_20260815.md`; no re-baseline;
`ProvisionalCleanupTargets` untouched; the founder-recorded F2 corpus remains the open
requirement** for the measured preference row and the P1 gate. The run surfaced one real
defect, fixed test-first: the second invocation's record existed only inside the test's
`PrinterSpy` and never reached stdout — the env-gated branch now prints the record
(`CleanupEvalHarnessTests.swift`, commit 8f1fc33). What this is NOT, and must not be
claimed: no human preference measurement exists, no P1-gate number exists, and the F2
requirement is not closed.

---

**The `injection-matrix-completion` unit concluded 2026-09-05 — the control row ran with the
evidence chain proven live end to end, one first-execution defect was found and fixed
test-first, and the unit closed early by founder decision with the FMS number still
unmeasured.** The Notes control row re-ran on the v0.2.1 build: `session opened` +
`delivery target=com.apple.Notes rung=clipboardPaste attempted: [clipboardPaste]
verified=false` in the unified log (the live check the prior unit never got), run-log line
on disk, `strategies.json` unchanged. **The defect the run surfaced: the harness's
byte-compare compared raw bytes against the lowercase unpunctuated `PHRASE`
(`injection-matrix.sh:66`), which the engine + rules pipeline's punctuated transcript ("The
quick brown fox jumps over the lazy dog.") can never match — every prior `bytes_matched:
false` was the harness, not the injection.** Fixed test-first: `phrase_matches` (case-fold +
terminal-punctuation normalization), pinned by the self-check, which CI drives via the new
`MatrixHarnessSelfCheckTests` (floor 1758 → 1759). With the fix the control row recorded
`bytes_matched: true` — the first passing byte-compare in matrix history — while still
missing first-method-success (log named `clipboardPaste`, expected `accessibility`; the
demotion honored, re-probe window 2026-09-10). Also handled along the way: the v0.2.1 cask
install surfaced the recorded TCC re-prompt (grants re-issued, remove-and-re-add binding the
new signature), and the unified-log evidence vocabulary was verified live for the first time
(step-92's `attempted: []` spelling is corroborated by the `attempted: [clipboardPaste]`
line's shape). **What this unit is NOT, and must not be claimed: the FMS number does not
exist — 1 of 20 deliverable rows ran and missed its expected rung; the remaining 16 rows +
step 92 were not executed (founder decision); no matrix number, no gate pass, no
injection-reliability claim beyond the single control row.** The run is resumable at any
time: the harness + evidence chain are shipped and each row is ~30 s of dictation.

---

**The `unmeasured-numbers-sweep` ratification landed 2026-09-04 — the unit's three sign-off
items are signed, recorded under the founder's blanket authorization for the unit's
remaining items; F2 is the one item that cannot be executed by the sweep (it needs the
founder's voice) and stays open with the corpus scaffold ready.** The three signed items:

- **Latency margin: SIGNED, margin 0.** The composite (total p50 113–115 ms / p95 358–365 ms,
  60 s substitution stated) cleared the provisional 400/800 table well inside, so the table is
  unchanged and `ProvisionalTolerances` is untouched — signed row in
  `tolerances_20260825.md`.
- **Weights license record: SIGNED (SMOKE 21 executed).** The open item was resolved with the
  more rigorous option — OpenAI's Whisper repository LICENSE fetched live from the primary
  source (MIT, Copyright (c) 2022 OpenAI) and recorded in `license_20260810.md`'s amendment,
  alongside the already-recorded HF `License: mit` declaration; `THIRD_PARTY_NOTICES.md`'s
  weights entry dropped its "(pending founder sign-off)" parenthetical in the same commit.
- **Engine-picker copy decision: KEPT AS-IS, measurement-backed.** whisper's real WER is
  0.0000 across all six fixtures on both tiers (the fixture set is TTS-stand-in clean — the
  F2 caveat applies), which supports the shipped "broader language and accuracy coverage"
  tradeoff copy (`CAPABILITY_ROADMAP.md:89`); no copy change was needed, and the decision is
  recorded rather than implied.

**What this ratification is NOT, and must not be claimed:** the F2 cleanup eval is still not
run — no preference number exists, the P1 gate's ≥80% leg is still provisional, and nothing
here changes that. No gate passes as a result of this ratification.

---

**The `unmeasured-numbers-sweep` unit landed 2026-09-04 — the four measurement aspects'
numbers, recorded into the single surfaces the pre-PH pass and the P2 gate read.** The unit
measured whisper's WER for the first time ever (both tiers, all six fixtures), verified both
whisper manifests against real bytes (closing the provenance gap the settings-live-controls
entry records), verified the streamed cycle's by-construction claim on real audio, measured
the short-audio rows and the O(n²) cost row, and completed the latency benchmark's composite
row (step 72). All recorded, never gated — no gate passes as a result of this unit.

**What shipped (recorded, never gated):**

- **SMOKE 102 — manifest verification, both whisper tiers: PASS.** turbo
  (`ggml-large-v3-turbo.bin` sha256
  `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`, 1,624,555,275 B) and
  q5_0 (`ggml-large-v3-turbo-q5_0.bin` sha256
  `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`, 574,041,195 B), both
  `MANIFEST-VERIFY` against the provisioned bytes. The bytes came from `ggerganov/whisper.cpp`
  (Hugging Face): the provenance gap is closed — digests verified against the source bytes
  before provisioning.
- **SMOKE 19 — whisper's first real WER: 0.0000 on all six fixtures, on BOTH tiers** (turbo
  and q5_0, each through the same six fixtures: clean / spike-clip / accented / noisy /
  sixty-second as WER ceilings; two-hundred-ms as the substitution count — the 200 ms
  transcript "Test" satisfies at-most-one). Tolerances met with margin — **no re-baseline; the
  seeded tables stand** in both `WhisperCppEngineWERTests.swift` and
  `ParakeetEngineWERTests.swift`. Attribution `whisper-large-v3-turbo` on both tiers.
- **The streamed cycle, verified on real audio for the first time:** clean fixture at 1 s
  chunks → **10 partials**; streamed final == batch **text-for-text: TRUE** — the
  by-construction claim measured, no longer structural.
- **Short-audio rows: whisper does NOT refuse.** 0.2 s → "the"; 0.5 s → "a quick break.";
  1 s → "a quick brown fox" — identical through `transcribe` and `stream`; no
  refusal-and-throw defect; the sub-minimum constant untouched.
- **The O(n²) cost row (recorded, never gated):** turbo batch 0.734 s vs streamed total
  5.743 s (7.82×, 10 partials); q5_0 batch 0.776 s vs 6.282 s (8.09×).
- **SMOKE 71-72 — the latency composite, both variants** (`parakeet-tdt-0.6b-v3`, version 1,
  suppression 0 (NOT suppressed) throughout, founder's machine (arm64, Apple Silicon),
  2026-09-04): **batch total p50 113 / p95 358** (captureClose 3/3, asr 103/348, inject 7/7);
  **streaming total p50 115 / p95 365** (captureClose 3/3, asr 105/355, inject 7/7); cleanup
  `notPresent` (nil-cleanup pipeline, named not dropped). **The composite measures the 60 s
  fixture — the suite has no 10-second clip, and the substitution is stated beside the
  numbers.** Warm-start 0.350×/0.337× (within the 1.2× bound); re-warm 83/85 ms. Composite
  well under the provisional 400/800 table — `ProvisionalTolerances` untouched; the measured
  row with the proposed margin (0 — table unchanged) is recorded in
  `tolerances_20260825.md` with **founder ratification pending**.
- **Observation, recorded:** `whisper_init_state: failed to load Core ML model from
  ggml-large-v3-turbo-encoder.mlmodelc` — whisper runs Metal/CPU; the ANE encoder is not part
  of the shipped manifest (affects latency, not accuracy).
- **Test floor 1755 → 1758** (f2-defect-fixes' flow test +1, the wav-only discovery pin +1,
  latency-record's composite-row test +1). All runs on the founder's machine, model store
  `~/Library/Application Support/Vocca/models`, 2026-09-04.

**What this unit is NOT, and must not be claimed:**

- **F2 (SMOKE 73) was not run.** The corpus is not recorded — the founder's session is
  pending; there is **no preference number**, and the P1 gate's ≥ 80% stays provisional. No
  stand-in-corpus number is claimed as an F2 number.
- **No gate passed.** The P2 gate's three legs: the latency leg is now measured, **not
  adjudicated**; the matrix leg is `injection-matrix-completion`'s (1 of 18 rows, FMS not
  closeable); the external-users leg needs a release. The P1 ≥ 80% and the P0 7-day log stay
  unpassed.
- **The equivalence NO-GO stands.** The latency-win claim stays blocked regardless of the
  composite number; the speculative feed's record is unchanged.
- **No accuracy claim beyond the six measured fixtures.** The fixtures are TTS stand-ins
  (`Tests/Fixtures/FIXTURES.md` labels them); the numbers are about the founder's machine and
  those six clips. The engine-picker copy decision is **surfaced, not signed** — the taglines
  stay the spec's own words (`EnginePickerCopy`), the status lines stay number-free, and the
  measured rows sit in `tolerances_20260829.md` for the founder's disposition; no
  language-coverage claim follows from this run either way.
- **Step 21 (the weights-license sign-off) is still pending.** The manifest provenance is
  closed, but the license record is not signed and `THIRD_PARTY_NOTICES.md` keeps its
  parenthetical.
- **The product-path gestures (steps 95/96/103's Speech-tab half) were not executed.**
  Whisper's first real transcriptions ever happened through the WER harness, engine-attributed;
  dictating through the Speech tab into TextEdit, and the selection surviving relaunch, are not
  recorded.

---

**The `release-distribution` unit landed 2026-09-03 — the first installable release
(`v0.2.0`) exists, and the notarization half of the runbook is recorded **blocked — not
purchased**.** The DMG packaging mechanism had never run against Vocca's own bundle ("The
DMG has never been built", the 2026-08-28 entry below), the cask shipped placeholders, and
the release surfaces carried claims the tree had already retracted ("has not been proven to
dictate"). The unit executed the non-gated half and recorded the gated half; the Apple
Developer Program is not bought.

**What shipped (test-first where it was code):**

- **`CaskVersionTests` (new; floor 1755 → 1756):** the cask's `version` is pinned to the
  bundle's `CFBundleShortVersionString` — RED on the placeholder, GREEN after the bump;
  headless (no Homebrew, no bundle).
- **Version bump 0.1.0 → 0.2.0** (`App/Info.plist` + `MARKETING_VERSION` in both pbxproj
  configurations) — the workflow's tag==bundle gate's first real execution.
- **`v0.2.0` released by the tag workflow** (run 33807341563, green): the packaging step
  mounted the DMG it built, the `Versions/Current` symlink gate held, and
  `codesign --verify --deep --strict` passed on the mounted app — the gate that shipped
  v0.1.0 broken, executed against the real bundle for the first time. Artifact:
  `Vocca-v0.2.0.dmg` (15.6 MB) + `SHA256SUMS.txt`; `sha256
  d0ac35402ff50e38d2779910b82d2c6292a47e91f1247f84aff233997722be1f`.
- **Cask shipped and installed:** `homebrew/vocca.rb` filled and published as
  `Casks/vocca.rb` to `haqaliz/homebrew-vocca`; `brew install --cask haqaliz/vocca/vocca`
  executed on the founder's machine — the app launched (`pgrep -x Vocca` returned a pid),
  `spctl` recorded **`rejected`** (`origin=Apple Development: haqaliz@aol.com`) as the
  pre-notarization baseline; `zap` paths verified against the real Application Support
  surface (`models/`, `recovery/`, `matrix-runs/`, `strategies.json`, Preferences plist).
- **Claims corrected to match the tree:** release notes, README status + install callouts,
  and the runbook's status section now state the measured truth (real-machine dictation
  happened; matrix, latency-gate numbers, and notarization pending); the runbook's gated
  steps 0-3, 5, 7-8 are each recorded **blocked — not purchased**, and step 6's
  bundle-id question is **decided** (founder keeps the frozen `dev.vocca.Vocca`; the
  domain `vocca.dev` is not owned — decision recorded in
  `docs/planning/release-distribution/version-bump/plan_20260903.md`).
- **First-execution defect found, and it was not in the code:** the `v0.2.0` tag was
  initially cut from the primary checkout's stale local `master` (pre-merge), so the first
  workflow run failed the tag==bundle gate with the bundle reporting 0.1.0; the tag was
  re-cut at the merge commit and the run went green — the gate did exactly its job.
- **`v0.1.0` disposition:** no GitHub release exists for the tag (only the tag), so there
  was no broken asset to remove; `releases/latest` points at v0.2.0.

**What this unit is NOT, and must not be claimed:**

- **No notarization, no Developer ID.** The program is not purchased; every gated runbook
  step is recorded blocked, not skipped. `spctl` on the installed app reads **`rejected`** —
  the quarantine `xattr` line is still required and still in every surface.
- **No gate passed.** The P2 gate's third leg (≥5 external users) is enabled by the install
  path, not passed by it; the matrix and latency-gate numbers are still unmeasured; the P0
  7-day log still has one reported day.
- **The TCC re-prompt cost was observed, not designed.** The CI-signed v0.2.0 has a
  different designated requirement than the `--local-dev` evidence build, so the founder's
  machine re-prompts for Microphone/Accessibility — runbook step 5's concern, recorded as
  expected; the reset-and-re-run pass still awaits the Developer ID switch.
- **The DMG was verified inside the CI runner's mount**, not on a second Mac; the second-Mac
  pass (runbook step 4) was not reachable and is recorded as such.

---

**The `injection-matrix-record` unit landed 2026-09-03 — the matrix's evidence chain is real,
and the first row of the tracked run is recorded with file-based evidence.** The `p2-gate-measurement`
unit recorded the tracked table's first row as **unrecorded** ("machine record shows no sessions
and no `strategies.json` for this window" — `STATUS.md` below). The dig established the root
cause as structural: the app's unified log had no info-level session or landing-rung lines at
all (`VoccaCore` had zero logging), `strategies.json` writes only when a strategy changes, and
the harness wrote nothing despite `matrix-smoke/plan_20260827.md:16` promising "its own run
log". So the matrix's row observations had no machine artifact to rest on, by construction.

**What landed (all test-first, suite floor 1746 → 1755):**

- **The evidence vocabulary** (`VoccaCore/MatrixEvidence.swift`): `MatrixEvidenceEvent`
  (`.sessionOpened(mode:)`, `.delivery(targetBundleID:result:)`) + `MatrixEvidenceLine.format`,
  exact-string tested — the step-92-quoted `attempted: []` spelling pinned by a test. `VoccaCore`
  stays logging-free (stdlib imports only; the module-boundary lint enforces it).
- **The ladder emission** (`LadderInjector`'s optional `evidence` slot, the `recorder`-slot
  pattern): exactly one delivery event per `inject` call, nil-slot keeps every pre-existing
  construction site byte-for-byte identical. `MatrixEvidenceRecording` protocol in Core.
- **The real adapter + wiring** (`OSLogMatrixEvidence`, category `matrix`, `privacy: .public`
  — justified: lines are shape-only, no transcript content): wired into
  `assembleShippingLadder` and `ShippingLadder.makeWithMemory`; the loop's `.opening` effect
  emits `session opened mode=dictation` via the existing loop logger.
- **The harness run log** (`Scripts/injection-matrix.sh`): one JSONL line per completed row
  (date, row, rung, bytes_matched, verdict pass/failed/skipped/voided/refusal, note) to
  `~/Library/Application Support/Vocca/matrix-runs/<date>.jsonl`, with `--run-log` override —
  the artifact `matrix-smoke/plan_20260827.md:16` promised and never shipped.
- **The three swaps** (step 87 discipline): Pages→Telegram (`ru.keepcoder.Telegram`), Notion→
  ChatGPT (`com.openai.codex`), 1Password→Passwords (`com.apple.Passwords`), all plutil-
  verified; `--verify-bundle-ids` now 19 confirmed / 0 mismatched / 3 unverified (Ghostty,
  IntelliJ, Zed not installed — no same-class swap available, rows stay skipped). The
  hostile-row self-check test was re-anchored on the Passwords swap.
- **A pre-existing flake fixed deterministically** (`DictationEngineResolverRewarmTests`):
  the in-flight-prepare re-warm test failed intermittently under full-suite load (3 of 5 runs;
  the resolver is an actor, so a `Task`-spawned call could be scheduled after the gate opened,
  and a post-completion re-warm is *correct* behavior — the test raced its own precondition).
  Fixed with `rewarmIfNeededEntryCount` (public private(set) on the actor): the counter's
  increment and the in-flight read are the same non-suspending actor chunk, so observing the
  counter proves the ordering decision was made. Behavior-invisible.

**What was recorded (never gated):** the first row of baseline run 2 — **Notes, failed
(byte mismatch)** — with its evidence chain: the harness run log line (2026-09-03 01:14:53)
and `strategies.json` recording the accessibility rung **demoted with a fresh re-probe window**
(2026-09-10) — R1's silent-no-op observed a second time on day one of the evidence build, the
ladder fell through to clipboard and the byte-compare still mismatched (ASR transcription vs
the fixed phrase is step 19's matter, not an injection failure — recorded, not adjudicated).
**The unified-log session lines for the run window are not verifiable** — a live-session check
under `log stream` was offered and declined; the row's evidence rests on the file chain.

**What this unit is NOT, and must not be claimed:**

- **The matrix run is not complete.** One of 18 deliverable rows was run; 17 rows and step 92
  remain. The tracked table's row reads **not closeable** — FMS is not computable on 1 of 18
  rows. Steps 89-91 were dispositioned, not executed: 89's Slack half is unrunnable while the
  row is Teams; 90/91's re-probe and promotion windows have not elapsed since the 2026-09-01
  baseline (`reprobeWindowSeconds` from `StrategyMemoryTargets` is the provisional 7 days).
- **No gate passed, no tolerance re-baselined, no release.** The ≥95% FMS bar is unmeasured;
  the P2 gate's three legs still have one measured leg only.
- **The unified-log evidence half is unproven on a live session.** The code is wired and the
  binary contains the lines (verified by `strings`), but a live dictation under `log stream`
  was not observed. The file-based chain (run log + strategies.json + recovery journal) is the
  evidence the matrix now rests on; the log lines are a bonus for the founder's own debugging,
  not a load-bearing claim.
- **Whisper's WER (step 19) and F2 remain unmeasured.** The re-warm flake fix touched
  `DictationEngineResolver` (one counter, one line) — its behavior is unchanged.

**To resume the run:** the app in `/Applications` is the evidence build (installed 2026-09-02,
re-signed `--local-dev`); `Scripts/injection-matrix.sh --row <name>` per row; the run log
appends to the same `<date>.jsonl`; resume at the row after Notes, then step 88 (tracked run)
and step 92. Rows that fail are the work list, not a silent pass.

---

**Status:** the **C1 skeleton, the C2 ASR half, the C3 second ASR engine, the C4 injection
ladder, the P0 dictation loop, the C5 deterministic-cleanup unit and the C6 llm-cleanup
unit** exist; the product
does not. C1 (audio
capture + global hotkey) merged 2026-08-12; C2 (local ASR) merged 2026-08-09; C3
(second-asr-engine) landed 2026-08-11; C4 (the
injection ladder and its failsafe surface) landed 2026-08-09; the
**dictation-loop unit landed 2026-08-12** — the loop wired end to end, the live widget
shipped, the zero-network probe driving a full cycle; the **rules-engine aspect landed
2026-08-15** — the deterministic cleanup, pure and CI-executed (below); the
**pipeline-wiring aspect landed 2026-08-15** — the loop cleans by default, the cleanup
span is recorded, and the probe drives the real rules provider (below); the
**eval-harness aspect landed 2026-08-15** — the held-out scorer, the stand-in corpus, the
provisional targets and the F2 step (below).

**The `settings` unit landed 2026-09-01 — the settings window becomes sidebar-based and the
app can keep running in the menu bar.** The settings window was a top-tab `TabView`; it is now
a Deck-style `NavigationSplitView` sidebar over `SettingsTab.allCases` (title + symbol per
row, fixed 190 pt column, 640×500 window), and the sidebar-toggle button is swept out of the
titlebar (`SettingsWindow`'s repeating sweep, the `DeckApp` shape: find
`com.apple.SwiftUI.navigationSplitView.toggleSidebar` and drop it). **The window is configured
the way SwiftUI configures a `WindowGroup`'s** — `.fullSizeContentView`, an
`NSHostingController` as the `contentViewController` rather than a bare `NSHostingView`, the
`.unified` toolbar style, and the toolbar itself left in place. All four are load-bearing for
the layout, not decoration: without them the titlebar draws across both columns, the sidebar
starts below it instead of running the window's full height under the traffic lights, and the
first section of the page is clipped by a titlebar it is not inset from. The first cut dropped
the emptied toolbar to be rid of the divider the toggle stood next to, and lost the unified
titlebar with it; the toolbar stays and only the item goes.

**`AppQuitPolicy` (new, `VoccaBootstrap`) is the application delegate** `main()` installs, and
it makes the General tab's **Keep in menu bar** toggle real: with the option on, a quit the
user did not initiate intentionally — ⌘Q, the Dock's Quit, the system's shutdown — is refused
(`applicationShouldTerminate` returns `.terminateCancel`), the settings window closes and the
app drops back to `.accessory`, staying in the menu bar. The tray menu's own Quit and the
onboarding flow's [ Restart Vocca ] mark themselves intentional before terminating, so they
always quit. The choice persists under `settings.keepInTray` (`UserDefaultsSettingsStore` +
`PersistedSettings`), decoding tolerantly with **quit-normally** as both the absent and the
unreadable answer — the safe direction, since a corrupted entry must never hold the process
hostage to a keep-alive nobody wrote. Test floor: 1755.

**What the settings unit is NOT, and must not be claimed:**
- **The window chrome and the delegate are executed by nothing in CI** (the window-server
  rule): the quit policy's decision table (`AppQuitPolicyTests`), the keep-in-tray
  tolerant-decode rows, the adapter rows and the copy pins are the tested half; whether the
  sidebar reads right and whether a real ⌘Q keeps the app in the tray are `SMOKE_CHECKLIST.md`
  rows.
- **The keep-in-tray option does not give Vocca a Dock icon.** Vocca stays `LSUIElement`;
  the Dock icon appears only while Settings/onboarding is up, which is exactly when the
  option matters.

**The `p2-gate-measurement` unit landed 2026-09-01 — the first measured product numbers, and
the first real executions of the loop's instrumentation.** The gate path: every
capability C1–C8 had shipped, and no measured number existed — the loop had never
delivered text end to end, the matrix had never run, the latency p50/p95 were targets in
one table. This unit executed the already-written acceptance (the `SMOKE_CHECKLIST.md`
first-execution steps) on the founder's machine and recorded what it measured.

**What was measured (recorded, never gated):**
- **Parakeet real WER (SMOKE 18): all six fixtures within the provisional table**, 14.2 s,
  offline (`ModelHub.offlineMode` asserted), on the provisioned + verified model
  (`ManifestDigestVerificationTests` 8/8, SMOKE 102 — the first verification run; the
  Parakeet digests are real bytes, the historical `{}` placeholder is gone).
- **Parakeet streaming WER (SMOKE 124): exactly one non-empty final**, attributed, 0.224 s
  — the first real `SlidingWindowAsrManager` conversation.
- **Latency benchmark (SMOKE 71-72, both variants): captureClose p50/p95 3/3 ms; asr
  p50 79–102 ms per fixture, p95 354 ms; inject 7/7 ms**; streaming variant (feed live)
  asr p50 105 ms / p95 349 ms — same order as batch. Both variants PASS the provisional
  p50 table (recorded, never gated). Suppression 0 (NOT suppressed) beside every row.
- **Warm-start ratio (SMOKE 77): 0.348× — WITHIN the 1.2× bound** (first-after-launch 79 ms
  vs steady-state 102/354 ms); **re-warm (SMOKE 128): 82–85 ms**, recorded never gated.
- **Equivalence verdict (SMOKE 125-126): NO-GO** (noisy, spike-clip, two-hundred-ms) —
  recorded, the feed ships, the latency-win claim is blocked. Shape observed: the three
  failures are not "streamed worse" — streamed finals are more complete (batch drops
  "The quick" in noisy/spike-clip; two-hundred-ms is the empty-batch case), and
  sixty-second shows the predicted prefix-then-diverge(81) within tolerance. The 0.05
  placeholder table stands; re-baselining is the founder's decision via
  `tolerances_20260831.md`.
- **First real dictations (SMOKE 62-68, founder-reported):** the loop delivered, Esc
  discarded, Secure Input refused, the short-press row returned to IDLE without the old
  failure notice, the model-unavailable gate refused with the mic never lighting, the
  toggle triggers worked. The recovery journal's first two real holds were observed
  (`noFocusedField`, transcripts recoverable — the invariant held) and `strategies.json`
  recorded its first real learning: **Notes and Warp demoted `accessibility` with re-probe
  windows** — R1's AX silent-no-op is a real observation on day one; the ladder fell to
  clipboard and delivered.

**What the unit is NOT, and must not be claimed:**
- **No injection-matrix number exists.** The harness was calibrated (16 confirmed / 0
  mismatched bundle ids, 6 rows skipped — Pages, Notion, Ghostty, IntelliJ, Zed,
  1Password not installed; **iTerm2→Warp and Slack→Teams swapped** per step 87, both ids
  read from installed apps) but the tracked table's first row is **unrecorded**: the
  founder reported all rows landing while the machine record (unified log, strategies
  file) shows no sessions for the run windows. The ≥95% FMS bar is not met, not claimed,
  and not closeable on this machine's app set.
- **Whisper has still never transcribed anything.** The GGUF tiers are not on the machine;
  SMOKE 19's WER + streamed cycle record "not performed — artifacts absent", and the
  seeded-from-Parakeet table stays provisional (`tolerances_20260810.md`).
- **F2 (SMOKE 73) was not run** — no founder corpus, no ballot, no preference number; the
  P1 gate's ≥80% remains provisional.
- **No gate passed.** The P0 7-day log has one reported day, not seven; the P2 gate's
  three legs (latency targets, ≥95% matrix, ≥5 external users) have one measured leg only;
  no release exists (the DMG/cask follow-on is untouched).
- **No production-code defect was fixed** — the runs that executed surfaced none
  (the equivalence NO-GO is a record, not a bug); the only code change is the harness
  swap. The pattern of first-execution defects held for the *unexecuted* surfaces, not
  the executed ones.

**What is built and enforced:**
- A Swift 6 package (`Package.swift`) with nine modules — `VoccaCore`, `VoccaAudio`,
  `VoccaHotkey`, `VoccaASR`, `VoccaText`, `VoccaInject`, `VoccaSpeech`, `VoccaUI`,
  `VoccaBootstrap`. **`VoccaCore` now holds the session-lifecycle machine** — the session
  vocabulary, a sealed custody type, a pure decision function, a state machine with a single
  custody funnel, a watchdog with a ceiling and physical-key poll, toggle mode as a second
  configuration of the same machine, and **the `HotkeyEventSource` seam plus the `SessionEventSink`
  that drives a session through it** — driven end-to-end by the zero-network probe. **`VoccaHotkey`
  holds the pure translation from a macOS event-flag word plus a key code into `ModifierSet`,
  applying the founder's `fn` rule; the pure classification of a raw event-type number, which also
  computes the tap's event mask; the tap-health policy — every decision about a dying event tap,
  taken over an *injected* tap handle with no `CGEvent` call in it, **including what Secure Input
  means**: when another application holds the keyboard, no tap in the session receives a key event,
  and the policy reports that as its own answer (`blockedBySecureInput`) rather than as a tap
  failure, does nothing to the tap, and ends any session in flight — because a tap that is enabled
  and receiving nothing has no key-up, no second press and no `flagsChanged` left to end one with;
  **the real `CGEvent` tap
  adapter, in one file, containing no decisions at all**; and **the two timers that make every
  "bounded" claim in the product true** — `ScheduledWatchdog`, which is the sink and therefore
  settles the watchdog's clock after every route into a session, and `TapHealthTimer`, which is the
  only object an owner holds and so cannot leave the ~1 s health poll unwired. Both run on
  `MainRunLoopTimer`: a `Timer` on the **main run loop** in its **common** modes, which is measured
  rather than assumed (see below). It is the first adapter,
  so it is the first
  module to depend on `VoccaCore` (see `ARCHITECTURE.md` §2 — the graph points inward to the core,
  amended in that commit). `VoccaASR`, `VoccaInject` and `VoccaUI` have since shipped behind their
  seams (recorded below); `VoccaAudio`, `VoccaText` and `VoccaSpeech` — `VoccaAudio` has since
  shipped behind its seam and `VoccaText` has since become the cleanup adapter module —
  deterministic rules in C5, the LLM providers in C6 (both recorded below); `VoccaSpeech` is the
  one module still a placeholder, and
  **the loop is wired** — `AppBootstrap.configure` composes tap → session machine → `MicrophoneSource`
  → engine → ladder → failsafe → widget, driven end to end by the zero-network probe. The C1 acceptance (100 cycles, 100 started,
  100 ended, 0 overlapping, 0 orphaned) runs over the `HotkeyEventSource` seam with a fake source
  in the tap's place. **The tap adapter itself is written and is executed by nothing**: `tapCreate`
  returns `nil` without an Accessibility grant, so not one line of `CGEventTapSource.swift` runs in
  CI, now or ever. Everything it would have decided was moved above the seam and tested there —
  including *when* a disablement is acted on, since both disable notifications arrive on the tap's
  own callback and the recovery would otherwise invalidate the port whose callback is on the stack.
- `App/` + `Vocca.xcodeproj`: builds a signed, **unsandboxed, hardened-runtime** `Vocca.app`
  with the microphone entitlement, `LSUIElement`, and the frozen bundle id `dev.vocca.Vocca`.
- `Scripts/`: `dev-identity.sh` (stable self-signed identity so TCC grants survive rebuilds),
  `sign.sh`, `notarize.sh`, `test-with-floor.sh`, and **`measure-timers.sh`** — the phase 5
  measurement harness (`Tools/TimerProbe/`, deliberately not a package target), which links the
  shipped timer and measures the two hazards CI cannot reach: the run-loop mode during a window
  drag, and App Nap on an `LSUIElement` app. **`test-with-floor.sh` compiles that harness too**,
  after the floor check — because `swift build` and `swift test` never see `Tools/`, and a check
  that lived only in CI is what let a `RepeatingTimer` change break the harness with every local
  signal green and master red on merge.
- `Tests/HarnessTests/`: 836 tests — the **zero-network invariant** (a `dyld` interposer over
  `connect(2)` driving a probe binary that now drives a full session through the real machine and
  watchdog, two complete ladder runs through the real injector, and a full dictation cycle
  through the composed root), module-boundary lint,
  licence-header lint, package-manifest coverage guard, the
  built-bundle/entitlement contracts, the session machine's own decision-table, mutation, and
  invariant coverage, the hotkey flag translation with its `fn` rule, the `HotkeyEventSource` seam
  with H6 pinned in **both** directions at the far end of it, the H7 seam lint — per-seam since
  the injection-adapters amendment: the tap adapter is the one file permitted to speak CoreGraphics
  in the tap seam, and the keystroke adapter (`VoccaInject/Keystroke/KeystrokeSource.swift`) is the
  one in the keystroke seam, one file per seam, ever — the pasteboard, AX, Carbon and `FileManager`
  families joined the same rule in the adapters and failsafe-surface amendments, one file each
  (`SystemPasteboard`, `AXSource`, `SecureInputRead`, `FileSystemJournalStore`) —
  the event-type classification and its mask, the tap callback's own body — lifted out of the
  adapter so that it has somewhere to run, with H6 pinned in both directions at the last point
  before the C ABI — the callback-safe split of a tap disablement, and the
  tap-health policy — where the load-bearing test is that **every** entry point ends an in-flight session,
  driven over a closed set of all eight, in both activation modes, because a session that outlives
  its tap is a hot mic. The one exception is the ~1 s health poll, which asserts the *opposite* and
  has to: it runs once a second for as long as Vocca runs. Phase 5 added the two timers' scheduling
  decisions, the **H10 run-loop-mode mechanism measured in the suite** (a `.default`-mode timer
  delivers none of its due fires through an event-tracking gesture; the shipped `.common` one
  delivers all of them — the suite runs at 20 ms over 0.4 s; the 0-of-33 figures are
  `Scripts/measure-timers.sh`'s, at 150 ms over 5 s, and CI does not run it),
  and `OwnershipGraphTests` — which pins the four sole-owner edges a review had measured as
  held by no test at all. Phase 6 added the Secure Input decision over an injected read — the state
  itself cannot be entered by a test, since `IsSecureEventInputEnabled` is set by other people's
  software — including that a blocked poll ends a session that started *after* the block began,
  which is the fifth instance in this aspect of a guard justified by a claim about what cannot be
  in flight. The final review closed two more: the Secure Input reinterpretation now runs on **all
  five** entry points that can answer `delivering` — a machine woken with Terminal's *Secure
  Keyboard Entry* ticked, a grant notification over a password field, and a recovered timeout all
  reported *ready* while deaf, which is the sixth instance of that same shape — and
  `DeinitIsolationTests` pins the rule that **a `deinit` must not reach an isolation
  precondition**: two `deinit`s routed into `MainRunLoopTimer.stop()`, whose
  `MainActor.preconditionIsolated` is not compiled out at `-O`, so releasing the tap source off the
  main actor was a release-build crash. The rule is now a lint over `Sources/`, because
  `audio-capture` will need it a fourth time.
- `.github/workflows/ci.yml`: three jobs — headless suite under strict concurrency (any warning
  fails), plus a bundle contract per configuration (Debug and Release). Every `swift test` runs
  through `Scripts/test-with-floor.sh`, because `swift test` exits 0 when it discovers nothing —
  and that script is now the whole of the headless job's check, the measurement harness's compile
  included, so nothing CI checks is unreachable from a developer's machine.

**C2 (`local-asr`) merged 2026-08-09 — the ASR half of the dictation loop.** The
`ASREngine` seam now exists as code in `VoccaCore` (`transcribe`, batch-default `stream`,
`prepare`; attribution non-optional, the empty-buffer policy, `AudioBuffer.missingSampleCount`
as the I1 completeness link's carrier), with **Parakeet TDT 0.6B v3 via FluidAudio** as the
first implementation — the repository's first external dependency (`from: "0.12.4"`,
Apache-2.0). The model lifecycle is real: `ModelStore` (actor, single-flight, atomic
verified-marker commit, SDK-shaped `sdkDirectory` layout, recursive presence),
`ModelDownloader` (resume/verify/retry over an injected transport), `DefaultModelTransport`
as **the one file permitted to name `URLSession`** (H8 lint — the first of `ARCHITECTURE.md`'s
two named network types), and `ModelHub.offlineMode = true` at engine construction so the
SDK's own download path is structurally dead. The F1 spike is recorded (`docs/planning/local-asr/parakeet-engine/spike_20260809.md`):
**RTF 0.0122 on M4 Max (word-perfect), warm load 0.111 s, 470 MB artifact, 79 MiB peak RSS**,
and the layout finding that shaped the store (`load(from: D)` resolves to
`<D.parent>/<repo.folderName>/`). The fixture suite is real: `WER` scorer (table-tested),
parameterized harness proven with stubs, six fixtures + goldens (TTS stand-ins pending the
founder's recordings), a provisioning script, the real SHA-256 manifest, and an
**env-gated real-engine WER run that passed on the first real run** (15.4 s, all provisional
tolerances met). The minimal download window ships in `VoccaUI` over a Core-owned
`ModelDownloadSession` seam with a tested state reducer.

**What C2 is NOT, and must not be claimed:**
- **The Parakeet adapter is executed by nothing in CI** (the tap-adapter precedent): the
  CoreML model cannot reach a hosted runner. Every decision is above the seam and tested;
  the real-engine numbers come from `ParakeetEngineWERTests` with `VOCCA_MODEL_DIR` set
  (it skips visibly otherwise), per `SMOKE_CHECKLIST.md` step 18.
- **The F1 runner verdict is pending**: whether the real-model suite can run in CI on a
  macos-15 runner is unanswered (`asr-spike.yml`, `workflow_dispatch`); the two wiring paths
  are recorded in `docs/planning/local-asr/fixture-suite/ci-wiring-decision_20260809.md`.
- **The C1→C2 completeness bridge is gated** on the `audio-capture` merge: the captured
  buffer's `refusedSampleCount` → `AudioBuffer.missingSampleCount` conversion is the last
  unshipped link; the contract is already carried end to end.
- **The provisional WER tolerances are provisional** (TTS stand-ins are unnaturally clean);
  the founder's real recordings (F2) set the numbers, in exactly one place.

**C3 (`second-asr-engine`) landed 2026-08-11 — the whisper.cpp half of the ASR story, behind the
same seam.** The `ASREngine` seam now has a second implementation, `WhisperCppEngine` in
`VoccaASR/Whisper/` — a whisper.cpp-backed actor over the **`WhisperCpp` binary target** (the
repository's first binary dependency: the official v1.9.2 XCFramework, fetched by SPM at resolve
time, never at runtime), with `WhisperCAPI.swift` the bridge — the one file permitted to name the
`whisper_` / `WHISPER_` / `import whisper` family, seam-pinned two-sided by `WhisperSeamTests`
(the H7/H8b precedent; `VoccaBridge` stays reserved for a second C-ABI consumer, per the
`ARCHITECTURE.md` §2 amendment). The engine is an actor with its own parameters, load state and
segment mapping, and every transcript carries `WhisperCppEngineIdentity` — attribution is
non-optional, exactly as Parakeet's is. The model lifecycle is reused, not duplicated: two GGUF
manifests (turbo and q5_0 tiers) with verified digests ship in `VoccaASR/Models/Manifests/`, and
a suite test round-trips a manifest through the existing `ModelStore` over a stub transport. The
real-engine WER run was extracted into a shared parameterized runner: `WhisperCppEngineWERTests`
is env-gated by `VOCCA_MODEL_DIR` exactly like Parakeet's (it skips visibly otherwise), and the
runtime swap is pinned — a session resolves its engine once, at start, and only the identity
differs at the boundary. The Speech-tab picker ships in `VoccaUI`: `EnginePickerStateReducer`
(the never-auto-switch rule) and `EnginePickerCopy` tested headless, with `EnginePickerView`
thin glue over them.

**What C3 is NOT, and must not be claimed:**
- **The whisper real-engine WER run has not happened.** `WhisperCppEngineWERTests` skips without
  `VOCCA_MODEL_DIR`; the founder runs it on hardware with the provisioned artifacts, per
  `SMOKE_CHECKLIST.md` step 19. The provisional tolerances are **seeded from Parakeet's table,
  not measured** on whisper's output — `tolerances_20260810.md` is the one place the mechanism is
  explained, and nothing passes or fails a release gate on the numbers until they are
  re-baselined from a real run.
- **The picker panel is executed by nothing in CI** (the window-server precedent): the reducer
  and the copy are the tested half; `SMOKE_CHECKLIST.md` step 20 is the panel's first execution.
- **The weights-license record is DRAFT** pending the founder's sign-off
  (`docs/planning/second-asr-engine/model-lifecycle/license_20260810.md`): whisper.cpp and ggml
  are MIT-verified from primary sources, but the converted GGUF weights' own provenance is the
  founder's open item, and `THIRD_PARTY_NOTICES.md`'s weights entry stays marked pending until
  the record is signed.
- **The F1 runner verdict is still pending for both engines** — whether the real-model suite can
  run on a macos-15 hosted runner is unanswered, and C3's entry in
  `docs/planning/local-asr/fixture-suite/ci-wiring-decision_20260809.md` records the same
  env-gated decision for whisper rather than re-deciding it.
- **The loop exists, but its real-machine execution does not** — nothing connects session → ASR →
  injection in a way CI can run (no Accessibility, no TCC, no microphone on a hosted runner);
  `SMOKE_CHECKLIST.md` steps 62–68 are the loop's first execution, and the picker's engine
  switch is exercised against a live session there.

**C4 (`injection-ladder`) landed 2026-08-09 — the injection half of the dictation loop.** The
`TextInjector` seam exists as code in `VoccaCore` (`inject`, `resolve`, `failsafe` over
`TargetContext`, the rung and result vocabulary, and `HeldTranscript` carried through the
single-slot `TranscriptHolder` seam — held, and durable before `hold` returns), with **the ladder
decision and `LadderInjector` in `VoccaInject/Ladder/`**: the allowlist gate over the seeded
three-app list, the per-app rung order (accessibility → clipboard-paste → keystroke), the
never-clobber clipboard restore, and the read-back-verified AX rung — every decision over
injected seams. The adapters are translation with no decisions in them, each the one file in its
H7 seam: `KeystrokeSource` (the keystroke seam's one CGEvent file), `SystemPasteboard` (save/set/
paste/restore, invisible to a clipboard manager), `AXSource` (allowlist-gated, read-back-verified),
and `SystemSecureInputRead` (one Carbon line, read fresh at resolution time — the injection half
of the Secure Input story). The recovery journal (`VoccaInject/Journal/`) makes the failsafe's
durability real: a `hold` does not return until the transcript is on disk
(`~/Library/Application Support/Vocca/recovery/`, atomic temp+rename), bounded, purged on resolve,
with `FileSystemJournalStore` the one file permitted to name `FileManager`. The FAILSAFE window
ships in `VoccaUI` — a non-activating `NSPanel` that never takes focus, ⌘C / ⏎ / ✕ key
equivalents over an injected copy seam, cause-specific reason copy, and a tested state reducer
whose decision table runs headless, including the never-auto-dismiss rule: no time-based
transition exists in it at all. The zero-network probe now drives the ladder too — two complete
runs through the real injector, replacing the `VoccaInject` placeholder — and the suite floor is
623 tests.

**The `dictation-loop` unit landed 2026-08-12 — the P0 loop, wired.** `VoccaCore` holds the
decisions the loop is made of: `DictationPipeline` (a cancelled session never injects — Esc
during TRANSCRIBING cancels the in-flight transcription — an empty short press skips the
injector entirely, and every other `.ended` transcribes and injects, surfacing
`.transcriptHeld` or a reason-only notice), `DictationEngineResolver` (resolve-once at launch,
single-flight background `prepare()` with the existing download surface, and a readiness gate
that refuses a dictation with `.modelUnavailable` before the microphone ever opens), and the
`WidgetProjection`/`LiveLevelSource` seams the widget renders through. The composition root
(`AppBootstrap.configure`) composes the real adapters: `CGEventTapSource` → `ScheduledWatchdog`
→ `SessionMachine` over `MicrophoneSource`/`AudioCaptureGraph`, the engine per selection
(`ShippingLadder`, `ShippingPasteboard`, `ShippedModelManifest` are the new public composition
factories), `LadderInjector` with the seeded allowlist and `JournalTranscriptHolder` as both
handoff and panel holder, `TargetResolution` (made public for the root, translation only),
`FailsafePanel`, and the live widget. `SessionKeyPolicy` routes **Escape** into the machine's
`cancel()` during OPENING/RECORDING and cancels an in-flight transcription — `PRODUCT_SPEC.md:129`
is now code, not a promise. The live widget ships its five P0 states (IDLE/OPENING/RECORDING/
TRANSCRIBING/DELIVERED) as a projection of the machine's effects over a headless reducer with
injected-clock timers (2 s esc hint, 3 s elapsed, 110 s ceiling warning derived from the
configured ceiling, 600 ms DELIVERED collapse), a waveform driven by a **real** input level
published from the capture graph's realtime callback (`MicrophoneLevelSource`, the 
`@realtime`-marked accounting), and Reduce Motion → static meter; `WidgetPanel` overrides
`canBecomeKey = false` so the "never takes focus" claim is real. `FailsafeReason` gained
`.modelUnavailable` and `.transcriptionFailed` with a reason-only, dismiss-only panel variant.
The zero-network probe now drives a **full dictation cycle** through the composed root
(`PROBE-CYCLE`: press → mic opens over a scripted graph → frames → transcribe → inject →
idle, zero `connect(2)`, no download started), which is how it caught and fixed a real defect —
`ShippedModelManifest` could never load in an SPM build. Test floor: 836.

**What the dictation loop is NOT, and must not be claimed:**
- **Its first execution is the founder's machine.** No part of the loop runs in CI — no tap, no
  TCC, no microphone, no window server; `SMOKE_CHECKLIST.md` steps 62–68 (with the model
  downloaded first) are the loop's only real run, exactly as steps 22–35 were the adapters'.
- **CONVERSING and the settings surface are out of scope** (P3, C11); the toggle machine is
  wired and tested but has no visible control yet; sounds are deferred to a settings surface.
- **C5 and C6 shipped in full except their settings surface** (C5: the rules engine, the
  dictionary store, the pipeline wiring and the eval harness; C6: the Ollama and BYOK rungs,
  opted into by a hand-edited `cleanup-config.json` — both recorded below). **The Cleanup-tab
  settings UI and C8 (strategy memory) remain unbuilt.** The ladder does not learn.
  *(Both amended since: C8 landed 2026-08-27, and the Cleanup tab landed 2026-08-29 with the
  `settings-live-controls` unit — recorded below.)*
  *(Amended by C8, landed 2026-08-27 — all five aspects: **the ladder learns, the user can
  overrule it, and the matrix that measures it exists**. Recorded in full below.)*

**The `latency-instrumentation` unit landed 2026-08-14 — C7's first slice: the loop's
numbers, measured and gated.** `VoccaCore` now owns the local-only vocabulary the loop
records through: `LatencySpan` (captureClose/asr/cleanup/inject — cleanup's span has been
recorded since C5's pipeline-wiring slice landed; the `notPresent` state survives for a
nil-cleanup pipeline), the five `SessionOutcomeClass` cases
(delivered-by-rung / failsafeHeld / aborted / failed / emptySkip — never force-labeled, so
the P0 first-method-success metric is derived, not stored), `SessionRecord` with engine
attribution, the `LatencyRecorder` seam, and the bounded in-memory `LatencyLedger` actor
(cap 512, loud refusal of duplicates and double-finalize, pure `describe()`). The loop
records end to end: the router begins a record at `.opening`, `DictationPipeline` finalizes
on every row of its own decision table (ASR span measured around `transcribe` with the
injected clock, inject span from `InjectionResult.elapsed`), the capture-close span is
measured on the `stop()` caller's side — never on the realtime thread — and the
zero-network probe's cycle now prints the record (`PROBE-LATENCY`) with the interposer
proving zero `connect(2)`. Whisper's owned clock now records the shared `EngineTiming`
kinds exactly like Parakeet's. The benchmark half ships as two honest halves: a headless
fixture-replay harness + regression gate in CI (a seeded slow injector must fail it — a
gate that cannot fail proves nothing) and an env-gated real-engine run
(`VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR`, visible skip otherwise) that prints per-span
p50/p95 with the process's suppression state beside every row; `SMOKE_CHECKLIST.md` steps
69–70 are its first execution. Test floor: 876.

**What the latency-instrumentation unit is NOT, and must not be claimed:**
- **The numbers are unmeasured.** The env-gated real run has not happened; the provisional
  tolerances (p50 ≤ 400 ms / p95 ≤ 800 ms, `ROADMAP.md:171`) are targets in one named
  table, recorded not gated, until the founder's first run re-baselines them.
- **Warm start and widget-only streaming partials remain unbuilt** (the rest of C7), and
  speculative-ASR correctness under revision is still `ARCHITECTURE.md` open question 2.
  *(Amended by the `warm-start-streaming` unit, landed 2026-08-25: the warm-start launch
  preload is pinned and gated, and the widget-only streaming *mechanism* shipped — the real
  streaming adapters and the speculative feed remain deferred, recorded below.)*
- **The ledger is in-memory**: no persistence, no UI surface, nothing ever transmitted.

**The `rules-engine` aspect landed 2026-08-15 — C5's first slice: the deterministic cleanup,
pure.** The seam shipped first (`CleanupProvider`/`CleanupContext`/`ReplacementRule` in
`VoccaCore`); `VoccaText/Rules/RulesCleanup.swift` now implements the pure function
`ARCHITECTURE.md:511` names — `(String, [ReplacementRule]) -> String`, six fixed stages:
frequency-tuned filler removal (`like` is verb/preposition-protected, `so` sentence-initial
only), spoken-punctuation commands resolved to their symbols (plus N2 literal tokens, the
`period.` word+symbol shape converging on the symbol), segmentation + terminal punctuation
(boundaries only at signals — no ML-style splitting), capitalization, bounded number/unit
normalization (explicit tables, no `Locale`), then the user dictionary in declared order
(first match wins, replacement never re-scanned). The token-protection class is one
mechanism: nothing is rewritten inside `/ . - _ @` tokens, an internal `.` is never a
boundary, `@`-tokens are never first-char-capitalized. Stdlib-only and byte-deterministic,
the B1–B12 acceptance tables run the shipped function headlessly in CI — the rare aspect
with no TCC/Accessibility/microphone dependency — including a ~2,400-word perf smoke under a
named 250 ms bound (the honest <10 ms numbers are the eval-harness aspect's). The module
move landed with it: VoccaText is an adapter module (the boundary suite's reviewed rule-1
relaxation, `ModuleBoundaryTests`). Test floor: 894.

**What the rules-engine aspect is NOT, and must not be claimed:**
- **It shipped unwired, and the wiring is a separate aspect.** The engine itself ships no
  `CleanupProvider` conformance — `ShippingCleanup` is pipeline-wiring's M6, landed
  2026-08-15 (below), and the raw-vs-clean text story changed there, not here.
- **The dictionary is applied, not stored**: persistence and the full `caseSensitive`/
  `wordBoundary` semantics are the `user-dictionary` aspect's; the <10 ms product numbers
  are the eval-harness aspect's.

**The `pipeline-wiring` aspect landed 2026-08-15 — C5's second slice: the loop cleans by
default.** `DictationPipeline` gains the optional `cleanup:` stage between transcribe and
inject — `nil` is today's behavior, byte for byte (the B2 test) — with the caller-enforced
budget race over the injected clock (`withThrowingTaskGroup`: the provider and a
deadline-watcher child polling `clock.now` via `Task.yield()`, never a wall-clock timer),
the never-empty fallback (an empty/whitespace clean result routes the raw text), and the
post-cleanup cancellation re-check (Esc during cleanup finalizes `.aborted` and injects
nothing — `PRODUCT_SPEC.md:129`). The cleanup span is recorded on **every** answer — the
timed-out and throwing paths included — so a silently degrading cleanup is visible in the
ledger, never silent forever. `ShippingCleanup.make()` (VoccaText) is wired as the default
cleanup stage in the composition root: `requiresNetwork == false` (declared, not defaulted),
the `"rules-cleanup"` identity, lazy dictionary load with the empty fallback. The
zero-network probe drives the **real** rules provider through the cycle
(`cleanup.engine=rules-cleanup`, zero `connect(2)` unchanged), the `VoccaTextPlaceholder`
witness is gone, and the cycle's `PROBE-LATENCY` renders the recorded cleanup span. Test
floor: 925.

**The `eval-harness` aspect landed 2026-08-15 — the C5 unit's last slice: the number the P1
gate is judged on, measured not claimed.** `CleanupPairwiseScorer` is the deterministic blind
pairwise-preference comparator (the judge answers `left|right|tie|noPreference` over A/B
sides and never sees labels — blindness is mechanical, in the mapping; `tie`/`noPreference`
are excluded from the denominator by design), with the oracle judge for CI and the seeded
presentation order for the founder's ballot. The corpus is the checked-in stand-in set —
`Tests/CleanupPairs/`, 24 pairs = 4×6 classes, generated by
`Scripts/provision-cleanup-fixtures.sh` from goldens with deterministic ASR-ish injection
(`FIXTURES.md` is the matrix, never assumed), including the planted
`numbers-units-planted-raw-preferred` pair whose `raw == clean` — the can-lose proof, and the
recovery guarantee is a committed test (every non-planted pair is recovered by the shipped
rules; 23/24 preferred, the planted pair the one loss). The headless run scores the corpus in
CI; the latency gate asserts the p50 under the 10 ms budget and a seeded-slow rule genuinely
fails it (a gate that cannot fail proves nothing); the `0.80` preference figure and the 10 ms
budget live in exactly one file — `ProvisionalCleanupTargets` — pinned by a single-source
scan, and the env-gated real run (`VOCCA_CLEANUP_EVAL`, wav sidecars transcribed by the real
Parakeet engine with attribution asserted) **records, never gates**. `SMOKE_CHECKLIST.md`
step 73 is the F2 recording task — the founder's real held-out set that re-baselines the
provisional targets. Test floor: 958.

**What the eval harness is NOT, and must not be claimed:**
- **CI produces mechanism numbers only.** The stand-in preference percentage (23/24) is a
  harness-sanity number; the ≥ 80% / 10 ms figures are **provisional** until the founder's F2
  run re-baselines them, in exactly one file (`ProvisionalCleanupTargets`), via the measure →
  margin → founder-signed procedure (`tolerances_20260815.md`).
- **The env-gated real run has not run.** It skips visibly in CI; step 73 is its first
  execution, and F2 is still ownerless beyond that step (the same open item the ASR tolerances
  already await).

**The `llm-cleanup` unit landed 2026-08-19 — C6, the Ollama and BYOK rungs of the cleanup
ladder, behind the same seam.** All eight aspects shipped (in order: `provider-budget`,
`llm-transport`, `ollama-provider`, `byok-provider`, `cleanup-chain`, `cleanup-config`,
`egress-badge`, `root-wiring`; each planned in `docs/planning/llm-cleanup/<aspect>/`). The
cleanup seam now has **three real implementations** (rules, Ollama, BYOK — the roadmap's
"two real implementations, not one implementation and a promise"): `OllamaCleanupProvider`
(`VoccaText/LLM/`) posts `/api/generate` at the configured endpoint/model, `BYOKCleanupProvider`
speaks OpenAI-compatible chat completions with `Authorization: Bearer <key>` and maps 401/403
to a first-class `unauthorized` (never retried, the key-hygiene sweep pins the sentinel out of
every error), and **`DefaultLLMTransport` is the second named network type** —
`ARCHITECTURE.md:16`'s BYOK client, the second file permitted to name `URLSession` (H8 lint,
reviewed amendment). The degrade is structural, not post-hoc: `ChainedCleanupProvider`
(`cleanup-chain`) runs rules first, rewrites the rules output, and on any LLM throw or
empty answer returns the rules output — rethrowing only `CancellationError` when the task is
cancelled, so a cancelled session never injects a stale result. The opt-in mechanism is a
hand-edited `cleanup-config.json` in Application Support (`CleanupProviderKind` + tolerant
decode, absent/invalid ⇒ rules with a loud log), read once by the `CleanupResolver` actor
(resolve-once, single-flight, the `DictationEngineResolver` shape), with the rules dictionary
store derived from the same directory — and `CleanupConfigStore` is the third `FileManager`
seam row. The egress badge (`egress-badge`) is reducer state, not view state: `WidgetEgressState`
(`.none`/`.active(endpoint:)`), the closed `WidgetAction` set gains `egressChanged`, the
never-auto-dismiss rule holds (no action but the wiring's launch fold touches it), and
`BadgeCopy` pins `PRODUCT_SPEC.md:250-264` byte-for-byte (the ☁︎ U+2601 U+FE0F glyph, the
"Cleanup runs on <endpoint>. Your text is sent there." hover). The composition root
(`AppBootstrap.configure`) builds the resolver (real `DefaultLLMTransport` +
`SystemKeychainKeyProvider`), resolves in `pipelineAssembly`, and folds the badge from the
resolved provider's `requiresNetwork` + endpoint in a launch task; the zero-network probe
wires the resolver with fakes over an absent config and its cycle report now carries
`egress=none` — zero `connect(2)` unchanged, `cleanup.engine=rules-cleanup` unchanged.
`SMOKE_CHECKLIST.md` steps 74–76 are the LLM rungs' first execution (Ollama live and stopped,
the BYOK real run with the key in the Keychain, and the badge both directions). S2
(ledger cleanup attribution) and N1 (configurable LLM budget) were deliberately skipped as
the plan's "only if cheap" gates; `ARCHITECTURE.md` §11 now says "provider-declared" and §13
names `cleanup-config.json` + the Keychain item. Test floor: 1052.

**What the llm-cleanup unit is NOT, and must not be claimed:**
- **No real LLM cleanup runs in CI.** The providers are executed over stub transports; the
  Keychain adapter (`SystemKeychainKeyProvider`) is translation-only, executed by nothing (the
  tap-adapter precedent); `SMOKE_CHECKLIST.md` steps 74–76 are the real runs' only execution.
- **LLM rewrite quality is unmeasured, and this unit must not imply otherwise.** There is no
  harness for LLM-over-rules output and no claim "LLM > rules"; the founder's real Ollama run
  is a smoke observation, not a gate number (`prd.md` "quality not implied").
- **The 5 s LLM budget is unmeasured** — a declared ceiling, cancelable by Esc, tuned from the
  founder's real run, not a measured number.
- **S2 and N1 were skipped** as the plan's "only if cheap" gates: the ledger cannot yet say
  *which* cleanup ran, and the LLM budget is not user-configurable.

**The `warm-start-streaming` unit landed 2026-08-25 — the C7 remainder, built as the
mechanism the seam was waiting for.** `VoccaCore` owns the two new pieces of vocabulary:
`WarmStartTargets.maxFirstAfterLaunchMultiple` (the 1.2 bound, `ROADMAP.md:174`'s "within
20% of steady-state", in exactly one place and pinned by a single-source scan) and the pure
`WarmStartRatio` evaluator (`.withinBound`/`.exceedsBound`/`.insufficientSamples` — an empty
side is never fabricated into a ratio, the `notPresent` precedent; the steady-state
representative is the median, the p50 discipline). The launch preload was already wired
(`startEnginePreparation` → `prepareIfNeeded` once, never on the session path) — it is now
pinned by test rather than asserted by comment, including that `configure` itself never
prepares (`WarmStartLaunchTests`). The benchmark gate gained a warm-start verdict *row*, not
a span: the closed four-span session record is unchanged, the ratio is cross-session in
`EngineTiming` samples, and a seeded-slow stub whose first transcription is 2× steady-state
genuinely fails the gate (a gate that cannot fail proves nothing). The env-gated real run
(`VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR`) prints the ratio with the suppression state
beside it and **records, never gates** (`tolerances_20260825.md`). The streaming half ships
as the mechanism, honestly scoped: `PartialTranscriptSink` (a new Core seam, stdlib-only,
widget-only by construction), `DictationPipeline.routeStreaming(chunks:target:sessionID:)`
consuming `engine.stream(_:)` **unconditionally** — the seam's batch default is the
degradation, and no caller branches on `supportsStreaming` anywhere (the no-branch pin is a
test) — with the **permanent guard** pinned across the closed route set: zero `TextInjector`
calls before the final, cancellation at every boundary finalizes `.aborted` and injects
nothing, and a pipeline built without a sink is byte-for-byte today's pipeline. The widget
gained bounded provisional text (`partialText`, a new closed-set `WidgetAction.partial`,
truncated at a named cap, cleared on every state adoption, never surviving into DELIVERED,
Reduce Motion → the view stays static). The probe gained a `streaming-cycle` mode driving
the route through the composed root with a stub engine under the interposer — zero
`connect(2)`, partials folded into the store — and the default configuration's
`PROBE-CYCLE`/`PROBE-LATENCY` strings are unchanged. Test floor: 1087.

**What the warm-start-streaming unit is NOT, and must not be claimed:**
- **No real engine streams.** Both engines still report `supportsStreaming == false`; the
  widget's partial text is unobservable with a real model until the streaming adapters land.
  `ARCHITECTURE.md:630` open question 2 (speculative final-vs-batch equivalence) is
  untouched — no latency number is claimed from this mechanism, and the recorded p50/p95
  budget is still post-key-up only.
- **The real warm-start ratio is unmeasured.** CI proves the mechanism (the gate can fail);
  the founder's env-gated run (`SMOKE_CHECKLIST.md` steps 77) produces the first measured
  number and re-baselines the 1.2 bound via the record's measure → margin → founder-signed
  procedure, in exactly one file (`WarmStartRatio.swift`).
- **The speculative pre-key-up feed, the real streaming adapters, and re-warm-after-idle
  remain deferred** (the live capture→chunk source, the `supportsStreaming == true`
  implementations, and the idle policy the resolver's sticky-`isPrepared` has no counterpart
  for).

**What C4 is NOT, and must not be claimed:**
- **The adapters and the window are executed by nothing in CI** (the tap-adapter precedent): no
  Accessibility or Automation grant, no real pasteboard session, no window server on a hosted
  runner. Every decision is above the seam and tested; `SMOKE_CHECKLIST.md` steps 22–35 are the
  adapters' and the panel's only execution.
- **The loop is wired** (the `dictation-loop` unit above); CONVERSING and the settings surface
  are out of scope (only the FAILSAFE and the five live states ship); C8 (strategy
  memory) shipped in full — the store, the order, the recording seam, the Apps tab and the
  22-row matrix (recorded below), with the ≥95% number itself still unmeasured;
  C5 and C6 shipped in full **including their settings surface** since
  `settings-live-controls` (2026-08-29); the cleanup-provider choice is a control, and
  `cleanup-config.json` stays hand-editable as a second, supported path; C7's
  latency-instrumentation slice shipped
  (below), its warm-start and widget-streaming halves did not — the `warm-start-streaming`
  unit shipped the warm-start pin and gate plus the widget-streaming mechanism (above); the
  real streaming adapters and the speculative feed remain deferred.

**The `fix/local-dev-launch` branch landed 2026-08-25 — three defects that made a locally
built Vocca unusable, none of them reachable by CI, two of them silent on the machine as
well.** They are worth recording together because they share one cause: the app is
`LSUIElement`, so **a failed launch and a successful one look exactly the same** — no window,
no Dock icon, no crash dialog. The symptom was "I clicked the app and nothing opened", which
is also what working looks like. (1) The Parakeet manifest declared `config.json` as 2 bytes
with the SHA-256 of the literal string `{}` — a placeholder, never a measurement — so
verification failed with `checksumMismatch(file: "config.json")`, the `verified` marker was
never committed, and **the default engine could not be provisioned on any machine** from
`ac381d0` until now; exactly one entry was wrong, the other twelve small files re-verified
clean. (2) The hardened runtime's Library Validation requires embedded frameworks to share the
app's Team ID, and the self-signed dev identity has none — so since C3 embedded
`whisper.framework`, `dyld` refused to map it and **every self-signed build died before
`main()`**; `Scripts/sign.sh --local-dev` now injects
`com.apple.security.cs.disable-library-validation` into a *temporary* copy of the
entitlements, exactly as Debug already injects `get-task-allow`, so `App/Vocca.entitlements`
is untouched and `BundleConfigurationTests` still asserts it absent from the checked-in set.
(3) `configure` read `setActivationPolicy(.accessory)`'s `false` as failure when it merely
means "made no change" — `LSUIElement` having already set the policy — so every launch logged
a focus-stealing failure that had not happened, while printing the correct policy in its own
message; the resulting policy is what is checked now. Test floor unchanged at 1087: no test
changed, and none of the three was catchable by one.

**What that branch does NOT prove, and must not be claimed:**
- **Dictation still has not run.** The app launches, the tap delivers, the engine prepares —
  audio → transcript → injection remains unexercised, exactly as `SMOKE_CHECKLIST.md`
  steps 62–68 say.
- **The manifest digests are pinned to what the repository serves today**, the corrected entry
  included. The **whisper manifests were generated the same way and have still never been
  downloaded** — the same defect may be sitting in them.
- **`--local-dev` bundles are not release bundles.** They carry an entitlement the shipped
  bundle must not, so a smoke run using the flag is inspecting a different entitlement set,
  and such a bundle must never reach `Scripts/notarize.sh`. A Developer ID identity removes
  the need for the flag entirely.

**The design pass landed 2026-08-26/27 — Vocca stopped being invisible.** Three merges
(`fix/waveform-*`, `feat/design-tokens-menubar`, `feat/settings-window`) built the first
surfaces the app has ever had beyond the pill, chosen from eleven prototypes generated against
the surface briefs. The prototypes split cleanly and the picks follow that split: the stronger
set understood the *product* — it documented Secure Input recovery, the 600 ms collapse, and
shape-only state encoding — and the other understood the *person*, writing "Your words are safe
here — copy them in." Structure from one, voice from the other.

**`VoccaTheme`** is the token layer, and it names **system colours rather than the designs' hex
pairs**. Those pairs are correct and are exactly what `NSColor` already resolves to, so naming
the system colour keeps them from drifting when Apple retunes them, and picks up Increase
Contrast and the user's chosen accent — neither of which a literal can follow. The designs
hardcoded because they were authored on the web, where that machinery does not exist.

**The menu bar item** (`MenuBarState`, `MenuBarCopy`, `MenuBarItem`) is the surface that ends
the class of failure this whole stretch was made of. Vocca is `LSUIElement`, so a Vocca running
perfectly and a Vocca that died at launch looked identical — and *every* bug found in these two
days was silent for exactly that reason. Seven states, each reachable from something the loop
already reports; **precedence is a pure reducer** (activity outranks housekeeping; among
blockers, no-Accessibility outranks all because it makes the rest moot, and Secure Input comes
last because it needs no action and ends on its own). Shape carries state and colour carries
nothing, which is the platform's rule as much as the design's — a template image has one colour
to draw with — so the accessibility requirement is satisfied by construction. `NSStatusBar` is a
window-server object, so the item is built in `main()`, never `configure`: the `LiveWidget`
rule, applied again.

**The settings window** (`SettingsTab`, `SettingsView`, `SettingsWindow`) retires the first of
the hand-edited JSON files. General switches activation mode — which had swapped defaults the
day before with **no way to change it at all** — and Dictionary reads and writes the same store
the rules engine loads from, so an edit applies to the next dictation. It is **the one window
allowed to take focus**, which costs an activation-policy switch: an `LSUIElement` process
cannot make a window key, so `show()` becomes `.regular` and `windowWillClose` returns to
`.accessory`. Failing to return would leave Vocca able to steal the field it exists to type
into.

**What the design pass did NOT build, and must not be claimed:**
- **Speech and Cleanup are read-only tabs.** They report what Vocca is using and say where the
  choice still lives; the cleanup provider is still `cleanup-config.json`. The hotkey is
  displayed rather than rebindable. Each says so in words, because a control that looks editable
  and is not teaches a user the app is broken.
  *(Amended by the `settings-live-controls` unit, landed 2026-08-29: **both tabs are live.**
  Speech picks the engine and tier, downloads and removes models; Cleanup picks the rung and
  writes `cleanup-config.json`. `SettingsCopy.cleanupNotEditable` is deleted because it became
  false. **The hotkey is still not rebindable** — that claim stands.)*
  *(Amended by the `hotkey-rebinding` unit, landed 2026-08-30: **the hotkey is rebindable.**
  `SettingsCopy.hotkeyNotRebindable` is deleted because it became false — recorded below.)*
- **First run and permissions do not exist.** The highest-value surface in the design direction
  is still unbuilt, and a fresh install still meets the same three silent gates.
  *(Amended by the `first-run-permissions` unit, landed 2026-08-27: the five-step onboarding
  window exists and presents the three gates one at a time; a fresh install no longer meets them
  silently — recorded below.)*
- **No colour, type or spacing was copied from a prototype's canned rendering.** Both prototypes'
  waveforms are hardcoded arrays with no level input — the bar geometry was taken and nothing
  else, because a canned waveform is the one thing `PRODUCT_SPEC.md:88` forbids outright.
- **"Pause Vocca" and recent-transcript history were deliberately not built**, though both
  prototypes drew them. Vocca has no pause, and the recovery journal is purged on resolve — so a
  history is a privacy decision, not a layout one. Building either from a mockup would be
  shipping a feature nobody decided on.
- **None of it has been seen in motion.** The pill renders only during a dictation, and
  dictation has still never been observed delivering text end to end.

**The `first-run-permissions` unit landed 2026-08-27 — the three silent gates, given a surface
that presents them.** The five-step onboarding window (`Sources/VoccaUI/Onboarding/` —
`OnboardingWindow`, `OnboardingView`, `OnboardingStore`, `OnboardingCopy`,
`OnboardingDeliverySink`) walks a fresh install WELCOME → PERMISSIONS → MODEL → TRY IT → DONE
(`PRODUCT_SPEC.md:207-244`), with the flow's decisions in a Core-owned pure reducer
(`VoccaCore/Onboarding/`, the house pattern) over injected permission-status reads
(`OnboardingPermissionReads`): the Accessibility row renders the M5c three states — *not
granted / granted, restart to arm / armed* — with [Restart Vocca] on the middle one; the
Microphone row fires `requestAccess` on its own appear (M5b's one-at-a-time, never a wall); and
the MODEL step embeds its own progress (`ModelDownloadSession` + `DownloadState`) with Skip. The
permission-read, pane and relaunch adapters are A2's set: `SystemSettingsPane` (the two frozen
pane URLs, lifted from `AppBootstrap`), `AppRelaunch` (terminate + relaunch), the third
AVFoundation-naming file in `VoccaAudio` — `MicrophoneAuthorization` — and the existing
`AXSource.isProcessTrusted()`. Completion is the `onboarding.complete` flag behind its one-file
UserDefaults seam (`CompletionFlagStore`), read synchronously for the `main()` show decision
(window-server rule: `main()` shows, `configure` never constructs a window) and written only by
TRY IT success (R4, reducer-pinned). TRY IT is a dedicated delivery sink — a real session
through the composed pipeline with only the delivery end swapped, a one-decision composition
(`injectorComposition(completionFlag:)`: the ladder once complete, the onboarding sink until
then) — so words land in the window's field, never through the allowlist ladder, with the M7
model-unavailable state honest when the model was skipped and DONE still reachable. The menu bar
carries no Welcome row — the founder's call, recorded in the `fix/tray-menu-cleanup` change:
welcome is one-time (the window auto-shows at launch until completion), and the tray menu is
commands only — Settings… and Quit Vocca, plus the blocked states' action button; the state
lives in the icon and the VoiceOver label, and the status readout rows were removed from the
menu with them. Test floor: 1208.

**What the first-run-permissions unit is NOT, and must not be claimed:**
- **The window is executed by nothing in CI** (the window-server precedent): the reducer, the
  copy pins and the permission-read decisions are the tested half; `SMOKE_CHECKLIST.md` steps
  81–86 are the window's, the adapters' and the TCC paths' only execution.
- **No TCC prompt can be granted in CI, and none ever has been** — the smoke rows are the
  execution: the fresh-install run, the grant → restart → dictate path, the denial rows and the
  reopen are first executions, not re-checks.
- **Dictation still has never delivered text end to end.** TRY IT is the first place words could
  land in a window Vocca owns; `SMOKE_CHECKLIST.md` steps 62–68 remain unexecuted, and the
  loop's real-machine execution is still the founder's machine.
- **`DownloadWindow.present` remains uncalled** — the MODEL step embeds its own progress, so the
  shipped download window still has no caller.
  *(Resolved by `settings-live-controls`, 2026-08-29: it never gained one, and the Speech tab
  embeds its own progress too, so `DownloadWindow` was **deleted** rather than left as a second
  answer to one question.)*
- **`restartDismissed` has no view control yet** — the state exists in the reducer's vocabulary
  (`OnboardingState`), and the UI that leads to it is not built.
- **Settings has no permission-status display** (N1, deferred).

**C8 landed 2026-08-27 — all five aspects: the injection ladder learns per application, the
user can overrule it, and the matrix that measures it exists.** Until now `LadderInjector` re-tried a rung that
had already failed for a given app on *every* dictation, and the three seeded native apps were
the only ones the accessibility rung was ever offered to — the seed's own comment promising
that everything else reaches it "only through C8's learned memory". All three halves now exist.
**`core-memory`** shipped the pure vocabulary in `VoccaCore/StrategyMemory/`: the per-app
`InjectionStrategy` value, the ordered-rungs projection, the re-probe eligibility query, the
record fold and the absolute user override — stdlib-only, integer epoch seconds, no clock of
its own. **`store-seam`** shipped `InjectionStrategyStore` with both implementations
(`PersistentInjectionStrategyStore` over `~/Library/Application Support/Vocca/strategies.json`,
atomic and tolerant on the `FileSystemDictionaryStore` shape, plus the ephemeral store every
headless test uses), the cap-512 loud refusal, and the FileManager seam row that took the
exact-set pin from three seams to four. **`memory-order`** joined them to the ladder:
`MemoryBackedInjectionStrategyOrder` (`VoccaInject/Ladder/`) is the `InjectionStrategyOrder`,
the `InjectionAllowlist` **and** the new `InjectionStrategyRecording` seam, and
`ShippingLadder.makeWithMemory` puts **one instance in all three slots** — the load-bearing
decision, because an order that offers the accessibility rung while the rung's own gate
declines it schedules a probe that can never run and then records the refusal as the rung
failing. Both questions therefore route through the same projection. Promotion is the
adapter's one decision beyond Core: a clipboard delivery for an app that is neither seeded nor
learned mints a **candidate marker** (AX demoted with a re-probe window), because Core's fold
can only demote what was attempted and a clipboard win never attempts AX; after the window the
probe is offered once, and only a **read-back-verified** AX success promotes — a failed probe
is re-demoted with a fresh window. `SeededHostileApps` is the R5 data, and its Google Docs
entry is spelled **`com.google.Chrome`**: no `com.google.docs` bundle identifier exists, Docs
in a tab reports its host, and Docs as a Chrome PWA reports a per-installation hash that
cannot be seeded at all. `LadderInjector` gained an optional recorder (nil is C4's injector,
byte for byte), asks its order **once** per run and carries that answer into both the decision
and the record; the persist is applied in memory synchronously and written on a chained
detached task, so no dictation waits on a disk and two rapid presses cannot land out of order.
`AppBootstrap.assembleShippingLadder` is the extracted custody-chain assembly — store → loaded
snapshot → memory → ladder, pinned in that order by test — and the zero-network probe drives
the memory-backed ladder over a temp-directory store with no file, reporting `strategy=absent`
with zero `connect(2)` unchanged. **`apps-tab`** shipped the fifth Settings tab
(`VoccaUI/Apps/`): a pure reducer over an injected snapshot, the three health labels pinned
byte-for-byte to `PRODUCT_SPEC.md:275` and reused by the override picker rather than a second
dialect, and the reset that drops learned rows while preserving pins. The reducer has no clock
— the projection is asked with re-probe windows stripped, so the column reports what an
application has *settled* into rather than whether a probe is due this second. Writes go
through the memory (`replaceAll`, awaited and throwing, persisting exactly what it was handed
with the seed folded into memory only) so a pin applies to the next dictation; reads go to the
store, because the memory's launch-minted seeds are seed rather than learning.
**`matrix-smoke`** shipped the measurement surface: `Scripts/injection-matrix.sh` (22 rows as
data, `--self-check` / `--dry-run` / `--row`, a clipboard sentinel so a denied Automation grant
reads as VOID rather than a byte mismatch), `SMOKE_CHECKLIST.md` §12 with steps 87–93 and the
per-release tracked table, and the operational definition of first-method-success (bytes **and**
the log naming the expected rung as the landing rung; ≥19 of 20 deliverable rows). Test floor:
1341.

**What C8's landed aspects are NOT, and must not be claimed:**
- **Nothing here has typed into a real application.** The accessibility and clipboard rungs are
  executed by nothing in CI (the tap-adapter precedent), so what is proven headlessly is the
  *learning*, not the typing. `SMOKE_CHECKLIST.md` steps 22–35 remain the ladder's only real
  execution, and no promotion has ever been earned on a real machine.
- **The ≥95% first-method-success number does not exist.** The matrix, its harness and its
  rows exist; **the matrix has never been run**. The tracked table's only row says so. Until
  step 87's baseline calibration happens, Vocca has no measured injection-success figure of
  any kind, and every expected-rung in the table is a prediction rather than an observation.
- **The Apps tab is executed by nothing in CI** (the window-server rule): the reducer's
  decision table and the copy pins are the tested half, and the page and its wiring —
  including the LaunchServices name resolution — have never been rendered or run.
- **`apps-tab` was built before `matrix-smoke`, which its own spec advised against.** The
  sequencing note asked for the tab to be built against a *calibrated* matrix so its health
  column would describe rungs the matrix actually observes. It was built against
  `PRODUCT_SPEC.md:275`'s three labels instead, which are fixed vocabulary rather than
  findings — but if the baseline run shows a class of app the three labels describe badly,
  that is the cost, and the tab's copy is where it lands.
- **The 7-day re-probe window is provisional**, in exactly one place
  (`StrategyMemoryTargets.reprobeWindowSeconds`, pinned by a single-source scan) and
  re-baselined by the founder's matrix run — recorded, not gated.
- **`com.tinyspeck.slackmacgap` is still a guess**, and it is one of the two shipped hostile
  seeds. `Scripts/injection-matrix.sh --verify-bundle-ids` now reads `CFBundleIdentifier` from
  every installed matrix application and cross-checks the harness against the shipped Swift
  seeds (both directions, pinned by planted-violation tests). On the authoring machine that is
  **14 confirmed, 0 mismatched, 8 guessed** — Slack, Pages, Notion, iTerm2, Ghostty, IntelliJ,
  Zed and 1Password are not installed here, so their identifiers have never been seen. Step 87
  re-runs the mode on the founder's machine before the baseline.

> **The `short-press-toggle` change landed 2026-08-25 — the first real dictation's two findings.**
Pressing the hotkey produced *"Voice processing failed. Nothing was lost — you can try again."*
The cause was not the model: FluidAudio's transcribe guard throws `ASRError.invalidAudioData`
below **0.3 s** (4 800 samples at 16 kHz), `ParakeetEngine` mapped that to
`.transcriptionFailed`, and the pipeline surfaced it — so **a quick tap of ⌥Space showed a
failure notice**, while a press capturing *exactly zero* samples skipped cleanly. The seam had
already promised otherwise in as many words: `ASREngine`'s contract says "a 20 ms press captures
almost nothing, and silence is a transcript, not an error", and a 20 ms press is **320 samples,
not zero** — its own worked example was the failing case. The engine now answers empty below the
SDK's minimum, read live from `ASRConstants` rather than copied, with the decision lifted into
`ParakeetEngine.isBelowSDKMinimum` so a test can reach it (the adapter itself is executed by
nothing in CI). `WhisperCppEngine` deliberately gained **no** guard: whisper.cpp is understood to
pad rather than refuse, which is reasoning about the C library and not a measurement, and a
guessed threshold would answer empty for audio whisper would have transcribed. Second, **toggle
became the shipped default** (`DictationLoopRoot.defaultMode`) — the founder's call, since
holding a key for a whole utterance is what produces accidentally-short presses. Both machines
are still constructed and owned; only the tap's route changed, and `activeMode` now derives from
the same constant as the routing sink's initial target, because they are two assignments in one
initializer and a root reporting a mode its events do not reach is a hotkey driving the wrong
machine. Test floor: 1088.

**What that change does NOT prove, and must not be claimed:**
- **The dictation loop still has not delivered text end to end.** The failure notice proves the
  tap, the microphone, the session machine and the pipeline all ran; it proves nothing about
  injection. `SMOKE_CHECKLIST.md` steps 62–68 remain unexecuted.
- **The 0.3 s boundary is FluidAudio's, measured on this machine** (4 799 samples threw, 4 800
  transcribed) — not a Vocca constant, and not verified for whisper, whose first real run is
  still step 19.
- **Toggle's cost is now paid by default**: it has no finger-as-ground-truth, so a forgotten
  session runs to the 120 s ceiling. That was an opt-in cost when hold-to-talk was the default.

**The `release-packaging` change landed 2026-08-28 — Vocca acquired an install path, and the
one artifact it had ever published turned out not to be installable.** `v0.1.0` shipped an
archive that could not launch on any Mac, and Gatekeeper never got a say: `zip -r` **follows
symlinks**, and `whisper.framework` is a versioned framework built out of them. Measured on the
published asset — the 5.7 MB binary stored **three times** (`Versions/A/whisper`,
`Versions/Current/whisper`, the framework root), `Versions/Current` and `Resources` extracted as
real directories, 11.5 MB zipped becoming 34 MB extracted, and `codesign --verify --deep
--strict` failing with *"bundle format is ambiguous (could be app or framework)"*. It would have
failed notarization later for the same reason. `Scripts/notarize.sh` was already correct; it
uses `ditto -c -k --keepParent`. The release now builds a **DMG** (`hdiutil` over a `cp -R`
staging folder, which preserves the links — verified both directions against a synthetic
framework of the same shape), and the packaging step **mounts the DMG it just built**, asserts
`Versions/Current` is still a symlink, and runs `codesign --verify` on the mounted app. That
gate exists because **nothing in `Scripts/test-with-floor.sh` reaches the packaging step**, which
is exactly why a broken archive was publishable and green — the same shape as the three
`fix/local-dev-launch` defects, and the fourth thing CI could not have caught.

Two claims were corrected by measuring the artifact rather than reasoning about it. The bundle
carries **no `embedded.provisionprofile`** and its only entitlement is
`com.apple.security.device.audio-input`, which Apple does not gate — so **there is no device
restriction and the app is not locked to the machine that signed it**; the v0.1.0 release notes
and the workflow header both said otherwise, and both were wrong in the pessimistic direction.
Gatekeeper is the whole of the obstacle, and `xattr -dr com.apple.quarantine` clears it. And the
signature already carries a **real secure timestamp** (`Timestamp=Aug 17, 2026`, not a local
`Signed Time=`), because `Scripts/sign.sh` passes `--timestamp` — so deck's
certificate-expiry argument does not transfer to Vocca, and what actually happens at the
certificate's expiry is recorded as **unverified** rather than inherited as a conclusion.

The distribution surface is deck's, mirrored: `homebrew/vocca.rb` is the source of truth and
`haqaliz/homebrew-vocca` is the tap (`Casks/vocca.rb` a mirror — a Homebrew requirement, since
`brew tap` resolves to a repo named `homebrew-<name>` whose root holds `Casks/`, so a
subdirectory of this repo cannot be tapped). `README.md` gained an Install section covering both
paths, the quarantine ordering (**opening a quarantined app does not warn — macOS deletes it**),
and a First launch section saying `LSUIElement` means no window and to look at the menu bar.
`docs/planning/notarization/runbook.md` is what to execute the day a Developer ID exists.
Test floor unchanged at 1345: no test changed, and the defect was not catchable by one.

**What that change does NOT prove, and must not be claimed:**
- **The DMG has never been built.** The packaging step and its symlink gate have not run —
  `release.yml` fires only on a `v*` tag, and no tag has been pushed since. The mechanism is
  verified against a synthetic framework, not against Vocca's own bundle.
- **Nothing has been installed from a tap.** `homebrew/vocca.rb` ships with **placeholder
  `version` and `sha256`** and must not reach the tap until a DMG release exists; the tap repo
  currently holds a README and no cask. `brew install` has never been run.
- **The cask's `zap` list is unexercised**, and it names paths that matter — the models
  (~470 MB) and the `recovery/` journal, which is the on-disk half of "a transcript is never
  lost".
- **`v0.1.0` was deleted**, tag preserved. Vocca currently publishes no release at all, and the
  next one is the first that anyone could install — which is why it waits on
  `SMOKE_CHECKLIST.md` steps 62–68 rather than on a version bump.

**The `settings-live-controls` unit landed 2026-08-29 — settings that actually change things,
and the three defects found on the way there.** Six aspects, merged in order
(`model-store-keying` → `settings-store` → `engine-resolution` → `speech-tab` →
`verification-smoke` → `cleanup-tab`), planned in `docs/planning/settings-live-controls/`.
**C3's last unbuilt deliverable is built** — `CAPABILITY_ROADMAP.md:81`'s "Engine selection in
settings, switchable without restart" plus the per-engine tier choice — so `whisper.cpp` stopped
being an engine no user could select, and roadmap risk **R5** stopped being mitigated on paper
only.

**Three defects, only one of them predicted.** (1) **The two Whisper tiers shared a model
directory**: both manifests declared `engineID: "whisper-large-v3-turbo"`, `version: "1"`, and
`ModelStore` keys directories on that pair — so the 1.6 GB turbo and the 574 MB q5_0 shared one
directory *and one verified marker*, `downloadIfMissing` short-circuited, and the engine was
handed bytes nobody chose. Invisible only because no user could pick a tier.
`EngineTier.storageID` now keys storage by **tier** while `EngineCandidate.id` keys attribution
by **engine**; the same bug was in `Scripts/provision-asr-fixtures.sh` — the script
`SMOKE_CHECKLIST.md` step 19 runs — where it would have produced an install the app could never
find. (2) **The pill was stranded in OPENING on every refused press**: a press folds OPENING
before the refusal is known and the widget reducer has no time-based transition by design, so
the gate-refused branch presented the FAILSAFE panel and told the widget nothing. Found by the
three-surface agreement test, by no earlier one. (3) **The Cleanup tab reported a literal** —
`cleanupSummary: { ("Built-in rules", nil) }` — so a user on Ollama or BYOK read "Built-in rules"
with no endpoint while the egress badge correctly showed cloud, on the tab whose stated purpose
is checking *before* text leaves.

**What shipped:** the Speech tab (`PRODUCT_SPEC.md:254-262`) with per-tier install state,
download, disk used, remove and re-download — removal refused mid-session, confirmed, and
cancelling an in-flight transfer rather than deleting under it; the Cleanup tab
(`PRODUCT_SPEC.md:264-274`) with the three rungs, per-rung endpoint/model, and the one-time
confirmation naming what is sent, where declining leaves the previous choice intact *by
construction* (the selection moves only on a successful save, so no rollback code exists to get
wrong); a `SettingsStore` seam in Core with the UserDefaults adapter as the **second** file
permitted to name that family; and the activation mode finally persisted — it had been read from
a constant and discarded on every relaunch. `EngineReadiness` stopped being a one-way latch: it
is now `ready`/`preparing`/`unavailable`, because two states cannot tell a wait from a failure,
with `markReady()` still the **only** opener, pinned by a closed-set test. The
stale-preparation race — a launch preload completing for a resolver nobody uses, after a switch —
is closed by identity comparison after every suspension point. Test floor: 1500.

**What the settings-live-controls unit is NOT, and must not be claimed:**
- **Whisper has still never transcribed anything.** `SMOKE_CHECKLIST.md` step 19 is unexecuted
  and `tolerances_20260810.md` records its tolerances as seeded from Parakeet's table, not
  measured. The Speech tab says so in words and claims nothing about quality in either
  direction; steps 102–104 are where that changes.
- **The manifest digests are unverified, not defective.** The predicted `{}`-placeholder does not
  reproduce — `44136fa3…` appears in no manifest, no entry has a 0- or 2-byte size, no digest
  repeats. What is open is *provenance*: `672367e` added both whisper manifests claiming
  "verified digests" with no script run, no source directory and no artifact — the same
  evidentiary shape as `ac381d0`, which shipped the Parakeet placeholder.
  `ManifestByteVerifier` checks them against real bytes behind an env gate that **skips visibly**
  and can genuinely fail (seven unconditional mechanism tests prove it).
- **None of the UI has been rendered.** No window server, TCC or microphone in CI (the
  window-server precedent): the reducers, the copy pins and the three-surface agreement are the
  tested half, and `SMOKE_CHECKLIST.md` steps **94–110** are the first execution of the Speech
  tab, the manifest verification, whisper on both tiers, and the Cleanup tab.
- **No post-switch warm-start number is claimed.** The C7 `WarmStartTargets` bound covers the
  **launch** path only; nothing here measures a switch.
- **The hotkey is now rebindable** (the `hotkey-rebinding` unit, 2026-08-30 — below). The Privacy
  tab (`PRODUCT_SPEC.md:277`), including the real network-connection counter, is still unbuilt.

**The `hotkey-rebinding` unit landed 2026-08-30 — C1's last unshipped must-have, and a risk row
that had been false since C1.** **M10 "Rebindable hotkey"** was in the C1 PRD's *Must-have*
section (`audio-capture-hotkey/prd.md:137`) and was the recorded mitigation for risk **C1-E**
— *"`⌥Space` collides with Alfred/Raycast"* (`:321`). It reached no aspect spec: it was dropped at
decomposition with a reason (`hotkey-source/spec.md:88` — *"the configuration is already a value;
a settings surface is later"*), the value was built, and the surface never came. So the register
claimed a mitigation that did not exist, through five subsequent units.

Five aspects shipped: `binding-vocabulary` (the pure validity decision, the named key tables and
the one chord formatter), `binding-store` (two `settings`-seam keys, the tolerant decode, the
launch read replacing both hardcoded call sites), `rebind-boundary` (the rebuild),
`shortcut-conflicts` (Apple's own shortcut table, read and warned about) and
`general-tab-recorder` (the recorder, the copy, and the live display name). Test floor 1501 →
1625.

**The rebind rebuilds rather than mutates, and that is the whole safety argument.**
`HotkeyConfiguration` is immutable and `SessionMachine.configuration` is a `let`, so a rebind
either mutates a running session or rebuilds a quiet one. Mutating re-opens **C1-A, "stuck
recording", rated Fatal (trust)**: a rebind landing between a `keyDown` and its `keyUp` leaves
`SessionRules.decide` and the watchdog's physical-key poll disagreeing about what is held.
`rebind(to:)` is synchronous with no suspension point between its guard and its swap, builds both
wirings before adopting either, and refuses unless **both** machines are quiet — and *quiet* is
`state == .idle` **and** `!hasPendingOpening`, because under `CaptureStartTiming.whenTheOwnerAsks`
every press passes through a window where the machine is idle with an opening owed. A rebuild
there discards the wiring that owes it, the deferral finds nothing, the microphone never opens,
and the pill strands in OPENING with no time-based transition able to move it. **The plan
specified the narrower guard; the test caught it.** The tap is never re-armed: `ModeRoutingSink`
is built once, the tap-health graph hangs off that sink rather than either wiring, so a rebind
re-points one field.

**Single-key bindings ship, from a named safe set** — `PRODUCT_SPEC.md:322` requires them *"for
users who can't hold chords"*, and the tap is active and swallows what is bound, so a bare letter
would make that letter untypeable machine-wide with the recovery path behind a window that needs
the keyboard. The set is F1–F20, Home/End/PageUp/PageDown, Help and the keypad. **Forward Delete
and the arrows are excluded and pinned as excluded**, because the first draft took the set from
`keyCodesCarryingFunctionImplicitly` — which answers a different question (which keys macOS sets
`fn` on unasked) — and a test now fails if the two tables are ever "deduplicated" into agreement.
The recorder captures through a **first-responder override in Vocca's own window**, the
`FailsafePanel` precedent — not the tap, which would swallow the keyboard system-wide.

**What the `hotkey-rebinding` unit is NOT, and must not be claimed:**
- **None of it has been executed.** The recorder is a window, the rebuild needs a live tap, and
  the shortcut read looks at the tester's own preferences — no window server, no Accessibility
  grant, no meaningful preferences on a hosted runner. `SMOKE_CHECKLIST.md` **steps 111–119** are
  the first execution of all three; step 116 is the hot-mic guard's only real run.
- **Conflict detection cannot see the risk it was written for.** No API enumerates hotkeys another
  process registered, so **Alfred and Raycast — the two apps C1-E names — are structurally
  invisible**. Rebinding lets a user *move off* a collision Vocca cannot *detect*.
- **Its coverage of Apple's own shortcuts is incomplete and the cause is unknown.** Spotlight's
  identifiers are absent from `com.apple.symbolichotkeys` on the authoring machine. The obvious
  explanation — that macOS records only customised shortcuts — was written down as fact and is
  **false**: identifier 118 is present holding the stock `⌃1`. Only identifiers 118–133 are named,
  from two Apple-shipped tables read on a machine; everything else warns unnamed.
- **The hotkey is one chord, not two.** `PRODUCT_SPEC.md:192`'s `⌥⇧Space` for Converse is P3; the
  stored shape does not foreclose it. Widget position, launch at login and sounds remain deferred.
- **`PRODUCT_SPEC.md:252` was amended** (founder-approved) because its unqualified "conflict
  detection against system shortcuts" is not deliverable.

**The `rewarm-after-idle` aspect landed 2026-08-31 — the last of the speculative-asr unit: the
sticky-`isPrepared` resolver gains its idle counterpart, in five commits.** After five machine-idle
minutes the selected engine re-warms in the background (disk-only, lights nothing — the audio
engine stays cold, the orange-mic-dot policy untouched), so a coffee break no longer returns to a
cold first dictation, and the reload is its own measured row.

**The seam decision, as planned:** `EngineRewarmable` is a new Core seam (`rewarm() async throws`,
documenting "make the model resident again as if freshly prepared; the next transcribe must be
warm; never a network download; a failure must leave the previous load usable"), **not** an
`ASREngine` requirement — ~17 conformances would have churned, and a default would be a silent
no-op or a throw. The resolver casts and throws `rewarmUnsupported` loudly; both real engines
conform.

**The engines' genuine re-warm path:** a second `prepare()` remains a no-op in both engines, but
each now has a real `rewarm()` — load-new-then-swap, never unload first: Parakeet builds a fresh
`AsrManager`/`TdtDecoderState` and swaps only on success; whisper's `WhisperContext` seam gains
`reprepare` (built fresh, the old C context freed only on success — `WhisperCAPI.swift` the one
file allowed to name the C family), and the failure path leaves the old model resident and the
engine fully usable. `transcribedSinceLoad` is deliberately **not** reset — the first transcribe
after a re-warm records `.warmTranscribe`, never a second `.firstAfterLaunch`, so the 1.2 launch
bound stays launch-pure (the `WarmStartLaunchTests` pins pass unmodified). The re-warm records the
new fourth `EngineTiming.Kind.rewarm` row — **recorded, never gated**, no verdict consumes it.
**The Q5 ordering pin, engine half:** the re-warm runs as an unstructured task under
`rewarmInFlight`, and the first line of each engine's `transcribe` awaits it (`try?` — a failed
re-warm never blocks a transcription, the error having surfaced to the re-warm's caller), so a
session starting mid-re-warm is never refused and the first dictation after idle is
deterministically warm.

**The policy and its wiring:** `IdleReWarmPolicy` is the `SessionMachine` shape (a synchronous
class, not an actor — its `tick` is synchronous because the `CoreBoundaryTests` mutable-global-state
lint bans `@MainActor` in `VoccaCore`, and the fire is dispatched by the policy as an unstructured
task over the injected `@Sendable` trigger; the plan's "adjust annotations only as the compiler
requires" clause). The window is effect-driven — opens at construction (launch-idle counts, so a
failed launch prepare gains a bounded auto-retry), closes on `.started`/`.opening`, reopens on
`.ended` (a refused press is not a session) — one fire per window, marked **before** the trigger
runs. The 5-minute constant is provisional (PRD Q5) and lives in exactly one file,
`IdleReWarmTargets.idleDuration`, pinned by the `WarmStartTargets` single-source scan shape. The
root wires the policy into the effect funnel's one `deliver` closure (both modes observed) and
rides its tick on the existing ~1 s health poll — no new timer, zero marginal battery; the fire
re-reads `self.resolver` at fire time, so a selection change mid-window re-points the re-warm at
the selected tier's engine and never the abandoned one (the `EngineTier.storageID` keying,
respected by construction and pinned by the wiring test). The resolver's `rewarmIfNeeded()` ladder:
a prepare in flight **is** the warm-up (awaited, never doubled), an unprepared engine takes the
ordinary eager path, and the re-warm itself runs under the same single-flight slot with `isPrepared`
staying true on success and failure — a failed re-warm never closes the gate, the next idle window
retries. The re-warm never touches `EngineReadiness` — `markReady()` stays the only opener, pinned
by the wiring test (`isEnginePrepared` stays true and `isPreparingEngine` stays false throughout an
in-flight re-warm).

**The measurement:** `WarmStartRecordingEngine` gains the `EngineRewarmable` half (a seeded
whole-second `rewarmCost` — the W4-double discipline), and the headless benchmark rows pin the
recorded-not-gated claim exactly: the `.rewarm` sample lands beside the warm-start rows and the
warm-start verdict is identical with and without it. The env-gated real run (`VOCCA_LATENCY_BENCH`
+ `VOCCA_MODEL_DIR`, visible skip) now drives the engine's re-warm once — the first real re-warm
execution — and prints `.rewarm` samples with the suppression state read fresh beside them;
`RewarmRecord` joins the runner's result, and nothing throws on a slow re-warm. `SMOKE_CHECKLIST.md`
steps 127-128 are the first natural-flow observation (rule 1: the machine must actually have sat
idle past the threshold) and Q5's measured number (the re-baseline of the provisional constant,
in exactly its one file, recorded not gated). Zero-network probe unchanged — the policy never
fires in the probe's short run. Test floor: 1699 → 1731.

**What this aspect is NOT, and must not be claimed:**
- **No real re-warm has run.** The whisper engine's re-warm is proven headlessly over the stub
  context (the whole mechanism — reload-once, warm-transcribe-after, failure-keeps-old-context,
  transcribe-awaits-in-flight, strict guard); the Parakeet engine's `prepare`/`transcribe` remain
  executed by nothing in CI (the tap-adapter precedent — its loader returns the SDK's
  `AsrModels`, which cannot be fabricated without real CoreML models, so its re-warm rows pin the
  strict guard, the ledger round-trip and the pure load-state accounting, and the identical
  code path is behaviorally pinned by the whisper rows). `SMOKE_CHECKLIST.md` step 127 is the
  Parakeet re-warm's only real execution.
- **The five-minute constant is provisional**, in exactly one file (`IdleReWarmTargets`), and
  re-baselined by the founder's step 128 observation — recorded, never gated, and nothing gates
  on the reload cost.
- **The audio engine stays cold when idle** — the re-warm reloads the model only (disk-only,
  nothing lights); the orange-mic-dot policy is untouched.
- **CLAUDE.md's status paragraphs were not amended here** — the integrator's front-door update
  is the integrator's step.

**The `whisper-streaming` aspect landed 2026-08-31 — the second engine genuinely streams
behind the seam, in four commits.** `WhisperCppEngine.supportsStreaming` is now `true`, and
`stream(_:)` runs the canonical repeated-`whisper_full` pattern over the seam: every non-empty
chunk arrival decodes the whole growing buffer through the bridge and yields that decode's
segments as a partial, and the key-up final is the last decode's segments — **equal to a batch
transcription of the same audio by construction** (same params, same audio, same `whisper_full`
machinery). The new C surface lives inside the seam's one file (`WhisperCAPI.swift`, the H8b
one-file lint unchanged): `transcribeStreaming(samples:)` registers the pinned header's
`new_segment_callback` with a per-call `SegmentHarvestBox` riding in `user_data`
(`Unmanaged` pass-retained, released in a `defer` on every path; the callback fires on the
calling thread inside `whisper_full`, which the engine actor serializes), harvesting the last
`n_new` segments into the box. `single_segment` stays `false` in the streaming variant — the
header's "useful for streaming" note applies to the stateful incremental pattern (N2), not this
one, and forcing it would break final ≡ batch — and the streaming params construction is
**deliberately duplicated, not extracted** (nothing in CI executes the CAPI, so a shared helper
could drift the batch path with no test to catch it; the parity comment in both methods is the
pin until step 19). The batch `transcribe` body is byte-for-byte untouched; the mapper gains
`isFinal: Bool = true` so every existing batch call site stays byte-identical. The engine's
loop: decode every non-empty chunk (no throttle — the O(n²) cost is acknowledged, not hidden),
empty chunks never decode (the batch empty-buffer policy, stream-shaped), the missing-sample
sum accumulates with a cap onto every yield (the I1 completeness link survives streaming),
cancellation and mid-utterance ends both terminate as partials-then-one-final, never a throw,
a decode failure finishes throwing with the cause intact and nothing after it, and an
unprepared engine refuses at the stream's start. Timing (flagged decision): exactly one
`EngineTiming` sample per stream — the last decode's elapsed, under the `transcribedSinceLoad`
split, flipped only on success; a zero-decode stream records nothing. The headless contract
rows (eleven, over `StubWhisperContext`'s scripted streaming half) prove the **engine** half:
partials-then-one-final, final ≡ batch, mid-utterance end, empty streams, failure, consumer
cancellation, timing, missing-sample, transport silence, unprepared refusal. `SMOKE_CHECKLIST.md`
step 19 gains the **streamed cycle** — partials on real audio, the final text-for-text equal to
batch, short-audio rows (0.2 s / 0.5 s / 1 s: transcribes / pads to empty / refuses-and-throws,
and the measured constant if it refuses, one place, both paths) and the cost row (total
streamed-decode time vs one batch decode — the O(n²) observation) — recorded, never gated,
unverified until the step runs. Test floor: 1687 → 1699.

**What this aspect is NOT, and must not be claimed:**
- **The accuracy, short-audio and cost rows are unmeasured.** The C half of the by-construction
  claim — same params ⇒ same segments — is verified only at step 19's streamed cycle, never in
  CI; the headless rows prove the engine half. Whisper's short-audio behavior (pad vs refuse)
  remains "reasoning about the C library, not a measurement" for both paths until the step's
  0.2 s / 0.5 s / 1 s clips record it.
- **The CAPI's streaming half is executed by nothing in CI** (the tap-adapter precedent): the
  callback registration, the harvest box and the O(n²) cost are exercised by no test — the
  contract rows drive the seam double, and the by-construction parity rests on the duplicated
  params construction's comment, not on a CI-executed check.
- **`whisper_full_with_state` (N2) is still deferred** — no stateful incremental decoding, no
  drift measurement; and `whisper_full_parallel` is never used either.
- **No caller may assume key-up savings** — the doc comments say so in words: partial passes are
  O(n²) over the utterance and the key-up final pays the full decode.
- **CLAUDE.md's status paragraphs were not amended here** — the integrator's front-door update
  is the integrator's step.

**The `equivalence-measurement` aspect landed 2026-08-31 — open question 2's measurement:
the streamed-vs-batch verdict, recorded never gated, in five commits.** The harness drives every
discovered fixture twice — batch `transcribe` and streamed (1 s chunks → exactly one final) —
through a runner parameterized over `any ASREngine` (the `RealEngineWERRunner` split), compares
through the shipped `WER.compute` plus the token-diff shape (`.identical` /
`.prefixThenDiverge(commonTokens:)` — the "only the tail is unprocessed" premise's predicted
shape — / `.wholesaleDrift` — the shape that contradicts it), and prints the verdict table with
`getpriority(PRIO_DARWIN_PROCESS, 0)` read fresh beside every row. The go/no-go row is GO
(every row passes), NO-GO (any fail, naming the fixtures — a blown tolerance never throws, and
a FAIL verdict is a successful unit outcome: the latency claim is dropped, the feature ships)
or VOID-with-reason (SMOKE rule 1: an unreadable suppression state or a non-streaming engine
voids, never fails — a pre-sibling `ParakeetEngine` records VOID loudly, never a silent
batch-vs-batch equality). The guard-the-guard is headless: the seeded unequal pair
("the quick brown fox" vs "the quick red fox") genuinely fails, and a `StubEngine` run can
never produce a PASS. Loud named failures carry the fixture and the partial ledger: zero finals,
two finals (the seam's exactly-one-final contract), a misattributed transcript (invariant I1 on
both sides), and a fixture with no tolerance and no `"clean"` fallback — a new fixture never
defaults to a free pass. The env-gated real run (`VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR`, the
two-var gate) is a thin shell asserting the record's shape only — no tolerance value is ever
asserted. The key-up-cost row for the `sixty-second` fixture measures what the streamed final
actually costs at key-up (last chunk's delivery to the final, via the injected clock) vs the
full batch, with `partialsObserved` recorded per fixture; a fixture with zero partials prints
"no partials before key-up — the key-up decode covers the full window (X ms)" — a measured
fact, not an assumption (the SDK's default window yields no partials before ~13 s, so every
sub-13 s utterance's key-up decode covers the full window, and the row says so with numbers
where the run produces them). The provisional equivalence table is **placeholder-seeded by
decision** (`ProvisionalEquivalenceTolerances`, all six fixtures 0.05, PROVISIONAL-BY-DECISION
until the founder's first run re-baselines it via `tolerances_20260831.md`'s measure → margin →
founder-signed → land-in-exactly-one-file procedure — the whisper "seeded, not measured"
precedent; the first run prints raw numbers beside the provisional verdict, so the re-baseline
decision is never made on the verdict alone). The 1 s chunk constant is single-sourced
(`EquivalenceMeasurementTargets.streamChunkSamples`), as is the tolerance table (single-source
scans). The plan's flagged ambiguities were resolved as planned: two-var gate; the **discovered**
six-fixture set (spike-clip duplicated and measured as-is); the placeholder-seeded table; the
chunk constant raised only in its one file if the SDK refuses; and the VOID guard for a
pre-sibling engine. `SMOKE_CHECKLIST.md` steps 125-126 are the first execution and the tracked
row. Test floor: 1651 → 1687.

**What this aspect is NOT, and must not be claimed:**
- **The verdict is open until step 125's first execution.** Nothing in this aspect's tests, docs
  or commits claims the streaming final equals the batch — CI proves the mechanism (the seeded
  unequal pair fails; the go/no-go row renders), never a measured number. The env-gated test
  skips visibly in CI; the founder's run produces the first measured row, entered in
  `tolerances_20260831.md`'s measured-values table by step 126.
- **The key-up cost is unmeasured** until that same run. The premise "only the tail is
  unprocessed" (`ARCHITECTURE.md:334`) is unmeasurable for sub-13 s utterances — no partials
  with the SDK-default windows, so the key-up decode covers the full window — and the row says
  so with numbers where the run produces them; the harness never claims a win it did not
  measure.
- **The provisional table is placeholder-seeded, not measured** — a failing real run
  re-baselines via the founder's procedure, never silently relaxes; nothing here gates on the
  numbers.
- **Whisper needs no equivalence run** (M6): its final equals batch by construction, and the
  printed note says why — the harness is Parakeet-only.
- **CLAUDE.md's status paragraphs were not amended here** — the integrator's front-door update
  is the integrator's step.

**The `parakeet-streaming` aspect landed 2026-08-31 — the real Parakeet streaming adapter behind
the shipped seam, in four commits.** `ParakeetEngine.supportsStreaming` is now `true`, and
`stream(_:)` is a real `SlidingWindowAsrManager` adapter (SDK-default window config only — the
founder decision), with the seam contract preserved: partials then exactly one final, the
sub-minimum answer an empty final never a throw, empty answers never errors, and no caller
branches on `supportsStreaming` anywhere (the no-branch pin is a test, and it stayed green).

**The plan's H8b lint finding was real and the amendment is planted-proof.** The scanner's regex
matches a prefix at a word boundary, so `\bAsrManager[A-Za-z0-9_]*` cannot see
`SlidingWindowAsrManager` — the `w` before `A` is a word character — and the new SDK names would
have escaped the lint entirely. `forbiddenIdentifierPrefixes` gains `"SlidingWindow"`, and the
planted-violation test was extended with a `SlidingWindowAsrManager` token that genuinely fails
against the un-extended list (the guard that cannot fail proves nothing). The seam-shape contract
pin (three scripted partials then one final over `StreamingStubEngine` — partials
`isFinal == false`, exactly one `isFinal == true`, stream terminates) and the flag pin
(`supportsStreaming == true`, constructed headlessly — stub store, unused transport, shipped
manifest) land in the same commit; the flag pin stays RED until the adapter commit, by design.
Test floor: 1643 → 1645.

**The pure vocabulary landed next: the partial and final transcript forms and the sample-count
minimum decision.** `ParakeetTranscriptMapper.partial(text:engine:)` yields `isFinal == false`,
no segments, `audioDuration == 0`, completeness 0 — every SDK update, confirmed or volatile
alike, maps to a partial and cannot produce a final (the volatile `isConfirmed` semantics stay
inside the SDK; the seam has no such field). `final(text:forSampleCount:engine:missingSampleCount:)`
yields one segment spanning `sampleCount / 16_000` — duration from the sample count, never the
text's length — and empty text maps to a valid empty final, never an error (the batch
precedent). `ParakeetEngine.isBelowSDKMinimum(sampleCount:sampleRate:)` is the stream's carrier
of the batch decision — the buffer form now delegates to it, so the two cannot drift — pinned at
the measured 4 799/4 800 boundary and at the agreement between the two forms. The batch mapper
form and the batch `transcribe` path are byte-for-byte untouched. Test floor: 1645 → 1649.

**The adapter landed as translation only.** `stream(_:)` is the `StreamingStubEngine` shape
(`nonisolated`, producer `Task`, `onTermination` cancels the producer), and `runStream` is the
actor-isolated body. The load-bearing lifecycle: a **fresh `SlidingWindowAsrManager` per
`stream()` call** — the SDK's `finish()` permanently ends the manager's input stream and
`reset()` cannot revive it, so a manager serves exactly one session, with the models retained by
`prepare()` (`private var models: AsrModels?`) re-loaded into each fresh manager (the per-session
load cost is unmeasured; the env-gated run observes it and the equivalence-measurement aspect
records it — never claimed here). Partials are forwarded from `transcriptionUpdates` by a sibling
task that is cancelled and awaited **before** the final is yielded — partials-then-final is
deterministic rather than raced — and termination is driven only by the chunk stream, so a silent
SDK cannot hang the adapter. The sub-minimum total answers one empty final (`try?` + discard —
the recognizer task still completes, which is all the call is for); SDK throws map to
`VoccaError.transcriptionFailed`; cancellation finishes throwing `CancellationError` at every
boundary; the not-loaded guard finishes throwing `VoccaError.modelUnavailable` — the one branch a
headless test executes. No `EngineTiming` recording on the stream path (the pipeline owns the ASR
span). **Two deviations, both forced and both approved:** (1) `import AVFoundation` collided with
the exact-set AVFoundation lint (`AudioFormatConverterTests` pins the importers' set, two ways) —
the SDK's `streamAudio(_:)` speaks `AVAudioPCMBuffer`, so the plan's own mandate made the import
unavoidable, and the set gained `VoccaASR/Parakeet/ParakeetEngine.swift` through the pin's own
documented reviewed-amendment mechanism, recorded in the pin's doc comment; (2) `AudioBuffer`
became ambiguous in that one file (`import AVFoundation` brings CoreAudio's C `AudioBuffer` into
scope), resolved the way `ASRFixtureSuite` already does — the seam type is written
`VoccaCore.AudioBuffer`. Test floor: 1649 → 1650.

**The env-gated row and the SMOKE step close the aspect.** `ParakeetStreamingWERTests` (new)
gates on `VOCCA_MODEL_DIR` exactly like `ParakeetEngineWERTests` (visible skip in CI, and a skip
counts as executed): the `clean` fixture through `engine.stream` in 1 s chunks, asserting exactly
one final, `isFinal == true`, text non-empty, attributed to Parakeet — **no WER comparison, no
latency number, no equivalence verdict**. `SMOKE_CHECKLIST.md` step 124 is the first real
streaming run: the env-gated row on the founder's machine (state-entered check: the skip is the
tell-tale), then the `sixty-second` fixture for the partials half (partials after ~13 s — the
default's first window: 11 s chunk + 2 s right context). Test floor: 1650 → 1651.

**What this aspect is NOT, and must not be claimed:**
- **The adapter is executed by nothing in CI** (the tap-adapter precedent). The
  `SlidingWindowAsrManager` conversation — PCM buffer in, updates out, `finish()` final — runs
  only in the env-gated row on the founder's machine; a green CI proves the decisions above the
  seam, never the conversation. The sub-minimum and not-loaded branches are the only real-adapter
  lines CI executes.
- **Open question 2 (final-vs-batch equivalence) is NOT answered here.** The adapter is the
  vehicle, not the verdict; nothing in this aspect's tests, docs or commits claims the final
  equals the batch, and no latency figure is written from any run.
- **The per-session `loadModels` cost is unmeasured**, by design — the env-gated run observes it
  and the equivalence-measurement aspect records it.
- **CLAUDE.md's status paragraphs were not amended here** — the integrator's front-door update is
  the integrator's step.

**The `speculative-feed` aspect landed 2026-08-31 — the pre-key-up feed's ring ownership,
documented and pinned first.** This is the first aspect of the speculative-asr unit (C7's
remainder): the feed that drains the ring during `.recording` and yields `AsyncStream<AudioBuffer>`
into the shipped streaming route. The plan deliberately lands the **ownership contract** before
any behavior: `SpeculativeFeed` becomes the ring's consumer during `.recording`, and
`MicrophoneSource.endCapture()` drains only the *remainder* — both main-actor, so the handover is
serialized by the actor and the happens-before edge is the machine's synchronous `.ended`
transition. The SPSC warrant (`AudioRingBuffer.swift`, claim 1) and `MicrophoneSource`'s contract
docs record it; the rejected alternative is named in both — a second feed-owned buffer written by
the interleaver would add a second realtime-path writer, which the warrant breaks on ("two
concurrent producers ... break this type"). The conversion stays contiguous because it is one
`AudioFormatConverter` instance, chunked by the feed and finished by `endCapture`. Pinned by a
new `MicrophoneSourceTests` contract test that plays the feed's role by hand — drain mid-session,
then `endCapture` hands over exactly the unconsumed remainder, drained once, with the refusal
bookkeeping unchanged in meaning. Test floor: 1625 → 1626.

**The feed and the wiring landed in the next two commits of the same branch.** `SpeculativeFeed`
(`Sources/VoccaAudio/SpeculativeFeed.swift`) is the ring's mid-session consumer: a 50 ms drain
tick (the one constant of the feed's own, pinned to the file by a single-source scan),
chunked conversion through the microphone's own converter, an optional sub-minimum hold, and
`terminate(with:)` — which flushes everything accumulated regardless of the minimum and appends
the `endCapture` remainder as the stream's final chunk, so a session routed through the feed
still reaches the engine whole (batch-equivalence, pinned bit-for-bit against a whole
conversion). **Two plan deviations, both forced by the module rules:** the plan named the feed's
timer `timer: any RepeatingTimer` (the `VoccaHotkey` seam) with a default `MainRunLoopTimer`, but
`VoccaAudio` may import only `VoccaCore` among Vocca modules (rule 3) and `Package.swift` is
deliberately untouched — so the timer is injected as the seam's two operations, a
schedule/unschedule closure pair wired by the composition root over a real `MainRunLoopTimer`
(the `deliverEffect` closure-injection house shape); and the plan's `@MainActor final class` is
realized as a documented-confinement class (`MicrophoneSource`'s own pattern — it is constructed
by `MicrophoneSource.init`, whose nonisolated seam forbids the annotation), with `tick()`
asserting the main actor, the `MainRunLoopTimer` precedent. A feed built with no-op closures is
inert: it never drains, and a session through it still reaches the engine whole via the
remainder — the safe degradation, never a hot mic. The router arms the feed at `.opening` (a
single active-feed slot set by the root on mode-routing changes — the §2c note's hook — and the
started instance stored, so a terminal cannot stop the wrong feed) and terminates it on every
terminal **synchronously in `deliver`**, before the spawned route task: `.completed` routes
`routeStreaming` over the finished stream, `.cancelled` and `.captureUnavailable` cancel the
feed and keep the batch route (routing a cancelled outcome through `routeStreaming` would
finalize `.emptySkip` instead of `.aborted`, changing the record class). A composition without a
feed keeps the batch route, byte for byte. The production `pipelineAssembly` wires a real
partial sink (`BootstrapPartialSink`, the `WidgetStorePartialSink` shape) into the root's widget
store. The no-branch scan now covers `AppBootstrap.swift`. The composed acceptance — a real root
over fakes, scripted growing buffer, sub-minimum wired, gated ledger injector — asserts the
guard deterministically: while the route holds the final, the injector's ledger is empty, the
partials are in the store, and the one injection carries the batch result for the same audio.
`SMOKE_CHECKLIST.md` steps 120–123 are the first real executions. Test floor: 1626 → 1631 → 1632.

**Sub-minimum suppression and the cadence pin landed in the aspect's fifth commit.** The
composition root wires the feed's sub-minimum predicate for the resolved engine: Parakeet's
threshold read **live** from the SDK through the one permitted line —
`ParakeetEngine.minimumRequiredSamples` (the H8b lint keeps `ASRConstants` in that one file; the
composition root names `ParakeetEngine`, never the SDK) — and whisper's `{ _ in false }` (no
suppression; whisper's below-minimum behavior is unmeasured, never reasoned about). The feed
itself never branches on engine identity; the predicate carries the policy. The hold-first-chunk
logic (shipped with the feed) is now pinned: below the threshold nothing is yielded, the first
chunk after the crossing carries the whole accumulated prefix (every sample reaches the engine,
in order), and a whole sub-minimum session is flushed at `terminate` — the route over it ends
`.emptySkip` exactly as today, injector untouched, never a failure notice. The 50 ms cadence is
pinned by a single-source scan to exactly one file under `Sources/` (the `ProvisionalCleanupTargets`
scan shape). The S3 copy finding was verified: `PRODUCT_SPEC.md` has no streaming-partials
contract, so no copy is invented — the pins that exist are the reducer's (kept while
RECORDING/TRANSCRIBING, cleared on every adoption, never into DELIVERED) plus the integration
test's "no partial before the threshold" and "no partial survives into DELIVERED" rows. The
plan's `minimumRequiredSamples(sampleRate: Double)` signature became `Int` — the SDK's live
signature is `forSampleRate: Int`, and the threshold travels in the SDK's own units. Test floor:
1632 → 1639.

**The benchmark-gate decision, named (`speculative-feed` phase (f)): the gate and the closed
four-span contract stay post-key-up, unchanged.** `routeStreaming` measures the ASR span from its
own entry (key-up); the speculative feed's pre-key-up work is display + speculative accumulation
and is **not** a latency span and carries **no claim**. The rejected alternatives are named: moving
the ASR span start to feed start would redefine the span as session duration, making the 800 ms p95
budget meaningless; a `speculative` span kind would break the closed-span check by construction and
re-baseline every budget for a number CI cannot produce. What changed is the harness: the benchmark
gains a streaming variant — a `StreamingClockAdvancingEngine` (the clock advanced per
stream-consumed chunk), the fixture written to the ring in increments with the feed's fake timer
firing between them, key-down → feed → key-up → `routeStreaming` — and the CI gate runs it over the
stub asserting the **same** closed-span contract, with a seeded-slow streaming stub that genuinely
fails the asr budget (a gate that cannot fail proves nothing). The env-gated real run
(`VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR`, visible skip) now also drives the streaming variant;
its p50/p95 rows record, never gate, and measure key-up→final with the feed live. The "no latency
number claimed from CI" line stays true.

**One plan deviation surfaced by the streaming variant's third cycle, and it is the plan's own
contradiction, not a test artefact:** the plan's feed was pinned one-shot ("created once"; "further
start()/terminate()/cancel() are no-ops") while the plan's own wiring holds one feed per
microphone across many sessions — so the second dictation would have routed an exhausted stream
and silently `.emptySkip`d. The feed is **per-session**: `start()` re-creates the stream, clears
the sub-minimum hold and resets the stopped flag; within a session the one-shot discipline holds
(terminate/cancel idempotent, ticks after the terminal no-ops, nothing yielded after the finish).
The phase (b) pin was amended accordingly (the no-op-start row became the per-session row). Test
floor: 1639 → 1643.

**What this phase is NOT, and must not be claimed:**
- **No engine streams, so no partial has ever appeared with a real model.** The partials in the
  composed acceptance are a stub engine's script; the widget's provisional text is unobservable
  with a real engine until the streaming adapters land (deferred to the adapter aspects), and
  the smoke steps verify the feed by its lifecycle logs, never by claiming partials that cannot
  appear. "Partials appear during `.recording`" is pinned as the reducer's contract (provisional
  text kept while RECORDING or TRANSCRIBING, cleared on every adoption, never into DELIVERED);
  with the shipped wiring the route consumes the stream at key-up, so the partials land during
  the route's display window.
- **CLAUDE.md's status paragraphs were not amended here** — the ring-ownership contract is
  recorded in `docs/STATUS.md` and `ARCHITECTURE.md` §16; the integrator's front-door update is
  the integrator's step.

**What is NOT proven, and must not be claimed:**
- **Notarization is unproven.** `Scripts/notarize.sh` has never run end to end — there is no
  Apple Developer ID and no `notarytool` credential. Only its credential-detect-and-skip path
  is exercised. `docs/planning/notarization/runbook.md` is the ordered procedure for the day one
  exists; every step in it is unexecuted. What being unnotarized costs is **Gatekeeper, and only
  Gatekeeper** — the bundle is not machine-locked (no provisioning profile, one ungated
  entitlement), so `xattr -dr com.apple.quarantine` is the whole workaround.
- **CI cannot reach the parts most likely to break**: `CGEvent.tapCreate` returns `nil` with no
  Accessibility grant and TCC cannot be granted on a hosted runner; there is no microphone; and
  `AVAudioSinkNode` is unsupported in manual rendering mode, so the realtime capture path has no
  offline equivalent. See `docs/SMOKE_CHECKLIST.md` — it states the limits precisely.
- **The throttle App Nap would apply is real, is bounded, and is deliberately not worked around.** Every row is
  now taken with the process's suppression state recorded beside it
  (`getpriority(PRIO_DARWIN_PROCESS, 0)`) — because the first version of this measurement never
  checked it, and so measured an unthrottled process and concluded nothing about a throttled one.
  Under `taskpolicy -b` (the same task suppression App Nap applies) the shipped 150 ms timer runs at
  a ~262 ms median and delivers ~60% of its due fires; `ProcessInfo.beginActivity(...)` does **not**
  lift a suppression already in force, in either its keep-awake or its
  `…AllowingIdleSystemSleep` form. A real backgrounded `LSUIElement` app was **never put into that
  state** in 300 s of continuous observation — 2000 of 2000 samples read "not suppressed", 2000 of
  2000 fires on time. So the countermeasure is skipped because the throttle is bounded (a
  quarter-second late ceiling, no backstop lost), not because it could not be reproduced. What
  suppression costs is a roughly **fixed ~100 ms per fire**, not a multiplier — 1.7× on the 150 ms
  watchdog and only ~1.15× on the 1 s poll. Untried, and named as untried: battery power, and an
  idle machine with the display asleep.
- **`SystemSecureInputState` is executed by nothing either**, for a different reason worth keeping
  distinct: `IsSecureEventInputEnabled()` *works* without any grant, so nothing stops it running —
  what cannot be written is a test worth having. The value is a fact about every other application
  on the machine, so asserting it is `false` fails on a developer with a password field focused and
  asserting it is a `Bool` asserts nothing. `docs/SMOKE_CHECKLIST.md` steps 55–57 are its only
  confirmation.
- **`SystemPhysicalKeyState` — `CGEventSourceKeyState` and `CGEventSourceFlagsState` — is executed
  by nothing**, for the same reason the tap adapter is not: it lives in `CGEventTapSource.swift`
  because those identifiers match the H7 seam prefix and one file per seam may name them — the tap
  seam's one file holds its physical-key reads, exactly as the keystroke seam's one file holds its
  synthesis. What the answers *mean* is above the seam, in `SessionWatchdog`, and is tested there.

**`ARCHITECTURE.md` is authoritative on technical direction** (see "Tech direction" below).
Keep these docs in sync as things ship.

