# composite-intent-resolver — Phase 2 understanding (2026-10-03)

Layer: actions / intent seam (C13, P4). Local-only, no cloud, no new process. No gate has passed.

## What the work is
`CompositeIntentResolver` (VoccaCore/Intent/, Foundation-free): phrase first (exact match wins,
short-circuits), else keyword. Becomes the composed default at `AppBootstrap.swift:736`.

## Findings that change the brief
1. **Acceptance 4 is not free.** Neither resolver names shell; `PhraseIntentResolver` is safe only
   because `IntentPhraseStore.swift:202` refuses shell rows at load. `KeywordIntentResolver` matches on
   `toolID` tokens over a catalog built at `IntentWiring.swift:226-240` with **no shell filter**, so an
   enabled shell command can score >= 0.75 and return `.toolCall`. Today that is unreachable only because
   the keyword resolver is not the default. Making the composite the default opens a voice path to shell
   unless the composite (or catalog) filters `dev.vocca.shell` explicitly. Shell voice leg is a recorded
   founder call — this unit must keep it closed.
2. **Posture change: the N1 opt-in drops from two steps to one.** Phrase default needs a phrase row AND an
   enabled tool. With a keyword leg, an enabled tool alone is voice-reachable. Confirmation, audit and the
   outward-facing floor still hold (card always shown for outward-facing), but it is a visible change to
   what the shipped config can do. Needs a founder decision, not an implementation default.
3. **Keyword path can fill arguments** (`mcp.chat post_message` template, `{{utterance}}`), and F-C
   (`jsonEscaped` emits `\u{1f}`, invalid JSON, `KeywordIntentResolver.swift:281`; `hexString` unpadded)
   sits exactly on that path. Once keyword is default, F-C is reachable from speech.
4. **Probe silently degrades:** `IntentDrive.swift:255-257` name check and the `as? PhraseIntentResolver`
   cast at `:275-281` would report `other` and `intentShellRows=0` (vacuous) for a composite.
5. **G5:** only `AppBootstrap.swift` is hashed; edit forces one re-anchor across seven pin sites
   (WiringBaselineTests, AuthBaselineInvariantTests, TurnTakingComposedAcceptanceTests,
   AgentPresetsInvariantTests, ActiveProjectInvariantTests, SpokenTaskInvariantTests,
   ReplyRenderingInvariantTests) + floor-script comment + CLAUDE.md/STATUS/CAPABILITY_ROADMAP prose.
6. **Lints need reviewed row edits:** IntentSeamBoundaryTests `families`, ActionSeamBoundaryTests:277-286,
   ConverseWiringSeamBoundaryTests:116-122. Floor `Scripts/test-with-floor.sh:2381` = 3083.
7. Test scaffolding exists: `CallCounter` spy (PhraseIntentWiringTests:217), `RecordingIntentResolver`,
   `IntentRoundTripHarness`, shell template `testAShellPhraseResolvesNoneEvenWithTheShellCommandEnabled`.

## Open questions (for the PRD interview)
- Q1 (founder): accept the one-step opt-in for keyword-routed calls, or gate the keyword leg behind its own
  switch (default off)?
- Q2: fix F-C in this unit (small, test-first) or record and refuse control characters in arguments?
- Q3: filter shell in the composite (defense in depth, my recommendation) vs catalog-level.
