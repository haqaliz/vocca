# resolver-chain — aspect spec

Single aspect of `composite-intent-resolver` (the unit is one concern; no further decomposition).
Source: `../prd.md` (approved 2026-10-03).

## Problem slice / outcome
A user can opt in (one field in `intent-phrases.json`) to a keyword fallback behind the phrase
resolver, with every safety row intact and the off state byte-identical to today.

## In scope
PRD must-haves 1–8: `CompositeIntentResolver`; `keywordFallback` field; shell filter; sub-threshold
ask-only; F-C fix; end-to-end card/audit path; probe variant; lint rows + G5 re-anchor + floor.

## Out of scope
Per PRD: shell voice leg, settings UI, threshold/synonym retune, display-name copy fix, dictation.

## Acceptance criteria (become the failing tests)
A1 phrase hit short-circuits; keyword spy count 0 (`CompositeIntentResolverTests`).
A2 phrase `.none` + confident keyword → `.toolCall`; through `IntentRoundTripHarness` it renders the card
   (outward-facing) with approval `.withheld`, and an audit record exists.
A3 sub-threshold keyword → `.ask`, ≤3 names; engine/provider invoke count 0.
A4 enabled `dev.vocca.shell` row never resolves: catalog filtered AND a keyword `.toolCall` naming the
   excluded provider is discarded (test each half independently with a stub keyword resolver).
A5 `keywordFallback` absent/false/`1`/`"true"` → off (loud log for non-Bool); `true` → on; unknown keys
   ignored; round-trip `encode`→`decode` preserves it; phrase rows unchanged.
A6 switch off → provider returns a `PhraseIntentResolver` (type-pinned); on → `CompositeIntentResolver`;
   re-read per turn (flip file between two resolves, no recompose).
A7 F-C: every scalar U+0000–U+001F round-trips through `JSONSerialization` as the same string.
A8 probe: composed default (switch off) still `resolver=PhraseIntentResolver … intentShellRows=0`;
   new `PROBE-INTENT-COMPOSITE` (`resolver=CompositeIntentResolver intentShellRows=0 resolved=1
   spawnsSubprocess=false`) green inside the interposer; guard-the-guard counterfactual fails when the
   shell filter is removed.
A9 G5: only `AppBootstrap.swift` digest moves; dictation digests `1baeb2de…`/`ce70ca10…` unchanged; floor > 3083.

## Risks
Switch loss on rewrite (no prod save caller today — pin round-trip anyway); raw-ID spoken ask (recorded,
not fixed); read-only keyword hit auto-runs (audited; see plan decision D1).
