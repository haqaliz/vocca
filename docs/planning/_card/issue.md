# Brief (no GitHub issue; inline brief from the vocca-next handoff, 2026-10-03)

Source: `docs/technical/CAPABILITY_ROADMAP.md:861` — "a phrase-then-keyword composite resolver" (C13, P4).

Build a `CompositeIntentResolver` (`VoccaCore/Intent/`, Foundation-free) that chains
`PhraseIntentResolver` then `KeywordIntentResolver` behind the existing `IntentResolver` seam,
and make it the composed default in `composeIntentWiring` (per-turn `resolverProvider`, no relaunch).

- A phrase exact-match wins and short-circuits.
- Otherwise the keyword resolver runs; a low-confidence result may only `.ask`. Never execute below
  the 0.75 threshold; never resolve to `dev.vocca.shell`.

Caveats: no gate has passed (eighteenth unit ahead of uncleared gates); resolver accuracy is
unmeasurable in CI (record counts, never a rate); F-C (`KeywordIntentResolver.jsonEscaped` emits
invalid JSON for control characters) is open — decide explicitly whether to fix it here; expect one
deliberate G5 re-anchor.

Acceptances (written first):
1. A phrase hit short-circuits; the keyword resolver is provably never consulted.
2. A phrase miss with a confident keyword hit yields a `.toolCall` that still goes through the card
   with approval `.withheld` and gets an audit record.
3. A below-threshold keyword hit yields `.ask` naming at most 3 candidates, engine count 0.
4. A shell tool is never resolved, even when its command is enabled.
5. PROBE-INTENT-DEFAULT reports `resolver=CompositeIntentResolver` with `spawnsSubprocess=false`
   inside the zero-network interposer.
6. Test floor rises from 3083; dictation digests unchanged.
