# Aspect spec: intent-seam

> Source: `docs/planning/intent-layer/prd.md` R1, R2, R8, R10 · Branch `feat/intent-layer/aliz`
> · Date 2026-09-22.

## Problem slice and user outcome

The first utterance-meaning component in the repo: a Foundation-free seam in `VoccaCore`
that maps a cleaned transcript to a tool call, a spoken question, or nothing. Without it,
the converse pipeline has no way to reach the action machinery.

## In-scope requirements

- `Sources/VoccaCore/Intent/`: `IntentResolver` protocol + `IntentResolution` vocabulary
  (`.toolCall(ActionInvocation)` / `.ask(question: String)` / `.none`).
- `KeywordIntentResolver`: token-scored matching over a provided tool catalog, seeded
  synonym table (code-level constant, test-pinned), stop-word handling, not-confident
  threshold below which resolution is `.ask` (top-N candidates from the resolver's own
  ranking, bounded 2-3, deterministic order).
- `NullIntentResolver`: resolves `.none` for every utterance; the composed default.
- The seam family lint (`IntentSeamBoundaryTests`): intent families confined to the Core
  seam files; planted-violation and comment-strip controls; non-vacuous guards.
- Foundation-free: the empty import allow-list (`CoreBoundaryTests.swift:116`) holds.

## Out-of-scope boundaries

- No argument *validation* (the provider validates; Core admits it cannot, the
  `ActionInvocation` precedent). No enablement knowledge (the catalog is supplied by the
  caller). No user-editable tables (that is `PhraseIntentResolver`, S1). No LLM, no
  network, no new module.

## Acceptance criteria (test-first)

1. A matched utterance (seeded synonyms) resolves to `.toolCall` with the correct
   provider/tool and arguments text.
2. An utterance below the threshold resolves to `.ask` naming the top candidates from the
   resolver's own ranking (bounded 2-3, deterministic order).
3. An utterance matching nothing resolves `.none`.
4. The resolver never invents a tool outside the provided catalog.
5. `NullIntentResolver` resolves `.none` for every utterance.
6. The family lint refuses a planted violation and survives comment stripping.

## Dependencies and sequencing

First aspect (no dependencies). Everything else imports the vocabulary.

## Open questions / risks

The D3-shaped guardrail-7 caveat is recorded in the PRD (R8): keyword + null default is
one real implementation plus a default unless S1 lands. The unit record states the honest
claim.