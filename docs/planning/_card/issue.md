# feat/phrase-intent-resolver — inline brief

No GitHub issue filed; the source is the `vocca-next` handoff (2026-09-25).

## Brief

Build C13's S1 slice: `PhraseIntentResolver`, the second real `IntentResolver` implementation
(`docs/planning/intent-layer/prd.md:188`), backed by a user-editable phrase table persisted as
JSON following the C5 dictionary store conventions (tolerant decode, caps refuse never clamp,
atomic writes, shape-only). Tests first: an exact phrase resolves `.toolCall` only for an enabled
tool; a phrase naming a disabled/unknown tool resolves `.none` and never reaches the provider; a
corrupt/absent file loads as the empty table with one loud log; a phrase hit still flows through
`ActionGate` withheld and still confirms outward-facing tools (the §8 floor — extend
`EscapeValveTests`); a probe row inside the zero-network interposer shows the default still
resolves nothing and `intentShellRows=0`.

Caveat: letting phrases target shell commands would reverse the arm-surface-only decision
(founder call). Composing the resolver into the shipped default is a reviewed edit; any G5
re-anchor is deliberate, never edit-to-match.
