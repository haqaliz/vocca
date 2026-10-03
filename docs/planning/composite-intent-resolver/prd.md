# composite-intent-resolver — PRD

> Slice 13 of C13 (P4), `docs/technical/CAPABILITY_ROADMAP.md:861`. Source: inline brief
> (`docs/planning/_card/issue.md`) + Phase 2 note (`understanding.md`). Q1–Q3 were decided by the
> founder delegating to the recommendations (2026-10-03): **Q1** keyword leg behind its own switch,
> default off; **Q2** fix F-C here; **Q3** shell filter inside the composite.
> No code exists for this unit yet. No gate has passed (eighteenth unit ahead of uncleared gates).

## Problem Statement

The composed intent default is `PhraseIntentResolver` only (`AppBootstrap.swift:736`): an exact
phrase hits, anything else resolves to nothing. `KeywordIntentResolver` — token-scored, with a
not-confident → spoken-ask path — is built and tested but reachable by nothing in the shipped
configuration, so the "ask, don't guess" behavior can never run. A user who has enabled a tool must
write a phrase row for every way they might say it.

## Goals & Success Metrics

- Voice can fall back from an exact phrase to the keyword resolver, **opt-in**, without weakening any
  safety row (card, audit, outward-facing floor, shell closed).
- With the switch off (the default), behavior is byte-identical to today's phrase-only default.
- Measured in CI by acceptance tests only. **No resolution rate is claimed**; SMOKE records utterance
  counts, never a percentage (accuracy unmeasurable in CI — unchanged).

## Persona & scenario

A Mac user who already enabled `audit.count` and wrote one phrase. They turn the keyword fallback on and
say "how many entries are in the action log" — no phrase row matches; the keyword resolver resolves it
(confident) or asks "Did you mean …" (not confident); an outward-facing result still shows the card.

## Requirements

Must-have
1. `CompositeIntentResolver` (`VoccaCore/Intent/`, Foundation-free, `IntentResolver`-conforming): resolve
   via the phrase resolver; on `.toolCall` return it; on `.none` fall through to the keyword resolver.
   A phrase hit never consults the keyword resolver (spy-proven).
2. **Switch** `keywordFallback`: additive field in `intent-phrases.json` (absent → `false`; the F1
   no-coercion rule — `1`/`"true"` are not `true`; tolerant decode, never a rewrite of the file). Read
   per turn through the existing `resolverProvider` (no relaunch). Off → the provider returns the
   phrase resolver exactly as today (composite not on the path). On → composite.
3. **Shell closed (Q3):** the composite removes every `dev.vocca.shell` row from the catalog before the
   keyword leg sees it, and also discards any keyword `.toolCall` naming the shell provider
   (belt and braces). Holds when the shell command is enabled.
4. **Never execute below 0.75:** a below-threshold keyword hit yields `.ask` (≤3 candidates) only;
   engine count 0. (Behavior already in `KeywordIntentResolver`; pinned through the composite.)
5. **F-C fix (Q2):** `jsonEscaped` emits valid JSON for every control character (`\u00XX`, four hex
   digits, zero-padded). Test-first with a round-trip through `JSONSerialization` for all of U+0000–U+001F.
6. The composite's `.toolCall` goes through the shared executor with approval `.withheld`, the card for
   outward-facing tools, and an audit record (unchanged path; asserted end to end).
7. **Probe:** `PROBE-INTENT-DEFAULT` still reports the shipped default honestly. With the switch off the
   default resolver is still `PhraseIntentResolver`; add a second probe line/variant for the switch-on
   composition (`resolver=CompositeIntentResolver`, `intentShellRows=0`, `spawnsSubprocess=false`) inside
   the zero-network interposer, with its guard-the-guard counterfactual. `IntentDrive`'s name check and
   `as? PhraseIntentResolver` cast must not silently degrade to `other`/0.
8. Lints get reviewed row edits (IntentSeamBoundaryTests, ActionSeamBoundaryTests,
   ConverseWiringSeamBoundaryTests); one deliberate G5 re-anchor (`bc2ce1fd…` → recomputed with
   `shasum -a 256`, seven pin sites + floor-script comment); floor rises from 3083; dictation digests
   unchanged.

Should-have
- Docs sync: CAPABILITY_ROADMAP (`:861` moves to shipped), ARCHITECTURE (`:296`, `:412`), STATUS entry,
  CLAUDE.md status block, SMOKE row (written, runnable, recorded never gated).

Nice-to-have (deferred, named)
- A settings-UI toggle. The file field is hand-edited this unit (the F-A shape, recorded) — a UI
  row is a follow-on, not claimed.

## Technical Considerations

- Phase P4 / layer: actions, the intent seam. Local-only; no network, no child process
  (`spawnsSubprocess=false` declared). No cloud, no dictation-path change (dictation digests pinned).
- Posture note: because the switch defaults off, the shipped opt-in stays **two steps** (phrase + enabled
  tool). Switch on makes it one step (enabled tool + switch) by the user's explicit choice.
- Keyword path can fill `arguments` (the `mcp.chat post_message` template with `{{utterance}}`) — F-C
  sits on that path, hence the fix is in scope.
- Per-turn read of one more field of an already-read file; no new file, no new store.

## Risks & Open Questions

- R8 (destructive action, Med/Fatal): mitigated, not retired. A keyword hit is a classifier guess; the
  card and `.withheld` approval are the backstop, and the N2 limit stands (an approval asserts a human
  said yes, cannot verify it).
- Keyword mis-route: confident-but-wrong at ≥0.75 is possible; accuracy is unmeasured. Mitigation is the
  default-off switch and the card; no rate may be quoted.
- G5 re-anchor shifts `AppBootstrap.swift`; verify only that file moves.
- Open: should the switch also live in the Actions tab now? Recommendation: no (deferred above).
- Open: does `IntentPhraseFile` need a `version` bump for the new field? Recommendation: stay at 1 —
  additive, absent → off, old files unchanged; confirm against the store's version check in planning.

## Out of Scope

- A shell voice leg (founder call, stays refused). Time-boxed/decaying trust. The audit-tools arm
  section. Settings-UI toggle. Any accuracy/threshold retune, new synonyms, or measured resolution rate.
- Any change to dictation, injection or ASR.

## Self-critique (prd-generator, Phase 4)

| Dimension | Rating | Note |
|---|---|---|
| Problem definition | 🟡 | The pain (one phrase row per wording) is asserted, not observed; no user has asked. Demand-pull is absent. |
| User understanding | 🟡 | One persona, founder-shaped. |
| Success metrics | 🟡 | Acceptance tests only; by design no resolution rate. Honest, but "voice reaches more tools" is unmeasured. |
| Scope clarity | 🟢 | Out-of-scope explicit; shell stays closed; UI deferred. |
| Edge cases & risks | 🟡 | See gaps 1–3. |
| Feasibility | 🟢 | Composition of two shipped resolvers; one more field in an already-read file. |
| Scope & layer fit | 🟢 | Local-only, no network/child, dictation untouched, seam stays pluggable. |

### Top gaps to strengthen
1. 🟡 **The spoken ask names raw IDs.** The production catalog is built with `displayName: ""`
   (`IntentWiring.swift:236`), and `KeywordIntentResolver.name(of:)` falls back to
   `provider/tool` (`:213`). Once the keyword leg is live, the ask reads out
   `dev.vocca.audit/audit.clear` through TTS. Safe, but poor. Fix options: (a) accept and record;
   (b) a small id→spoken-name map. Recommendation: (a) — copy polish is out of scope; record it.
   It also means keyword scoring runs on `toolID` tokens + seeded synonyms only, never display names.
2. 🟡 **Switch loss on rewrite.** `IntentPhraseFile` is `(version, phrases)`; if any code path saves the
   file without carrying the new field it silently turns the keyword leg off (fail-safe direction, but a
   silent loss). Planning must grep every `IntentPhraseStore.save` caller and pin round-trip.
3. 🟡 **Confident-but-wrong at ≥0.75 is unmeasured** and the only backstop is the card (outward-facing)
   — a read-only tool resolved by keyword auto-runs with no card (`autoRanReadOnly`, audited). Decide in
   planning whether read-only keyword hits should still be recorded distinctly in the audit summary.

### The hard question
The question I'd want answered before greenlighting this: with the switch defaulting off and no settings
UI, who flips it? If the only answer is the founder hand-editing JSON, this unit ships a capability
nobody but the founder can reach — is that worth an eighteenth unit ahead of uncleared gates, versus
spending the slot on gate evidence (the external-users leg)?
