# Understanding — phrase-intent-resolver (Phase 2 dig)

## What the work actually asks

The second *real* `IntentResolver` (C13 S1, `intent-layer/prd.md:188`). Today the seam has
`KeywordIntentResolver` (token-scored, seeded in code) and `NullIntentResolver` (the composed
default). The intent-layer record calls that the **D3-shaped guardrail-7 caveat**: one real
classifier plus a default. S1 retires it and is also the **user-editable tuning path**: today a
wrong seed means a reviewed code edit (`KeywordIntentResolver.shippedSynonyms`, pinned verbatim
by `IntentSeamBoundaryTests`).

Phase: **P4, C13**. No gate passes. This is the twelfth unit built ahead of the uncleared
gates under the recorded posture.

## Code it touches (read, not assumed)

- `Sources/VoccaCore/Intent/` — `IntentResolver` (sync, deterministic, `resolve(_:against:)`,
  the catalog is the enablement and is never read), `IntentResolution`
  (`.toolCall/.ask/.none`), `ToolReference`, `KeywordIntentResolver` (Foundation-free
  tokenizer, stop words, `utterancePlaceholder`), `NullIntentResolver`. Core imports nothing
  (`CoreBoundaryTests.swift:116`), so the resolver must be stdlib-only. The **store** cannot
  live in Core.
- `Sources/VoccaBootstrap/IntentWiring.swift` — `composeIntentWiring(configStore:provider:
  executor:resolver:root:)`. It builds the catalog from `config.enablement` per call, and
  `performAction` submits `approval: .withheld`. The resolver is a parameter, so a new
  resolver needs **no** wiring change beyond its construction.
- `Sources/VoccaBootstrap/AppBootstrap.swift:701` — `let intentResolver = NullIntentResolver()`.
  Any change here moves the G5 pin.
- The persistence precedents: `VoccaText/Dictionary/FileSystemDictionaryStore.swift` (the C5
  shape: element-wise tolerant decode, one loud log per skipped element, atomic tmp+rename,
  sorted keys, load never writes) and `VoccaActions/Config/ShellCommandRegistry.swift` (caps
  that refuse, never clamp; invalid rows skipped loudly; `defaultDirectory(applicationSupport:
  home:)`).
- Tests: `IntentResolverContractTests` (the per-implementation contract), `IntentSeamBoundaryTests`
  (the per-seam lint: which files may name `IntentResolver`, `KeywordIntentResolver`, …, so a
  new resolver type is a **reviewed widening** of that lint), `EscapeValveTests` (the §8 floor),
  `IntentRoundTripTests`, and the probe `VoccaNetworkProbe/IntentDrive.swift`
  (`PROBE-INTENT-DEFAULT resolver=NullIntentResolver … intentShellRows=0`).

## Ambiguities / contradictions surfaced

1. **The shipped default.** If the default stays `NullIntentResolver`, a user-editable phrase
   file does nothing in the shipped app, and "user tuning path" is only true after a reviewed
   flip (N1). If the default becomes `PhraseIntentResolver` over the user's file, an
   absent file resolves nothing, which is behaviourally identical to Null. But
   `resolver=NullIntentResolver` in PROBE-INTENT-DEFAULT and the G5 digest both move. This is
   a founder call.
2. **Shell targets.** `intentShellRows=0` pins the arm-surface-only decision
   (shell-provider PRD, Out of Scope, founder decision). A user phrase naming
   `dev.vocca.shell/<id>` would reverse it.
3. **Arguments.** `action-config.json` carries "no arguments ever"; the keyword table carries a
   `{{utterance}}` template. An exact-phrase row's utterance *is* the phrase, so templating is
   meaningless. The open choice is static argument text or none.
4. **`.ask` has no meaning for an exact matcher.** There is no confidence gradient. A miss is
   `.none`, and the brief's acceptance list agrees.
5. **Composition with the keyword resolver** (phrase first, keyword fallback) would be a third
   type, a composite. It isn't in the brief, so it's out of scope unless asked.
6. **Editing UI.** C5's dictionary started file-only. The brief says "user-editable JSON", so
   there's no Settings editor unless asked.
7. Side observation, not this unit: `KeywordIntentResolver.jsonEscaped` emits `\u{XX}` for
   control characters, which is not valid JSON (JSON wants `\u00XX`). Record it; don't fix it
   here.

## Local-first / scope check

Local, deterministic, zero network, no child process; no cloud, no LLM. It doesn't touch
capture/ASR/cleanup/injection/TTS, so the dictation digests must stay unchanged. It fits the
guardrails.

## Process note

This session has no subagent tool, so the gather/dig fan-out ran in the main thread. Recorded
honestly rather than implied.
