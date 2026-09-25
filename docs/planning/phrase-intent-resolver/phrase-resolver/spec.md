# Aspect: phrase-resolver

## Problem slice

The second real `IntentResolver`: deterministic, exact, and Foundation-free. It retires the
D3-shaped guardrail-7 caveat (PRD R1, R2).

## In scope

- `Sources/VoccaCore/Intent/PhraseIntentResolver.swift`: `PhraseIntentRow` (`phrase`,
  `providerID`, `toolID`; `Sendable, Equatable`) and `PhraseIntentResolver: IntentResolver`
  with `init(rows:)` and `public static func normalized(_:) -> String`.
- Normalization: lowercase; every run of non-letter/non-digit characters collapses to one
  space; leading and trailing spaces trimmed. It is a private implementation, not the keyword
  resolver's tokenizer (that one is pinned code).
- `IntentResolverContractTests` widened so its shared rows (Sendable seam, determinism, never
  invents a tool, empty/whitespace → `.none`) run over `PhraseIntentResolver`.
- `IntentSeamBoundaryTests` widened (the reviewed REFACTOR) to permit the new type names in
  exactly the files that need them.

## Out of scope

The store, the wiring, arguments, `.ask`, fuzzy matching, and any change to `KeywordIntentResolver`.

## Acceptance criteria (failing tests first)

1. An exact phrase for a catalog tool → `.toolCall(ActionInvocation(providerID:toolID:
   arguments: nil))`.
2. Normalization equivalences resolve: `"Clear the audit log."`, `"  clear   THE audit-log "`
   → the row `"clear the audit log"`. A near miss (`"clear audit log"`) → `.none`.
3. A row targeting a tool **not in the catalog** → `.none` (inert; never invents).
4. An empty catalog → `.none` for every utterance.
5. Two rows with the same normalized phrase and both targets enabled → the **first** in table
   order wins (deterministic).
6. It never returns `.ask`: a property row over a mixed utterance set asserts no `.ask` result.
7. Empty/whitespace/punctuation-only utterances → `.none`.
8. Deterministic: 100 repeated resolutions are equal.
9. `CoreBoundaryTests` stays green: no import.

## Dependencies & sequencing

None. This is the first aspect.

## Risks

- Unicode case folding: `lowercased()` is stdlib and locale-independent, which is good
  enough. Diacritics are *not* folded ("café" ≠ "cafe"). That's recorded, not solved.
