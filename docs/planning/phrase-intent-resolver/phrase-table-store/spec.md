# Aspect: phrase-table-store

## Problem slice

The user's phrase table has to live on disk in a hand-editable file that a typo can never
make fatal and a hostile edit can never turn into a voice path to a shell command (PRD R3, R4).

## In scope

- `IntentPhraseStore` in `Sources/VoccaActions/Config/` (+ `IntentPhraseFile`, the decoded
  value: `version`, `phrases: [PhraseIntentRow]`, `static let empty`).
- File: `<applicationSupport>/Vocca/intent-phrases.json`, `{"version": 1, "phrases": [{"phrase",
  "providerID", "toolID"}]}`; `defaultDirectory(applicationSupport:home:)` in the
  `ShellCommandRegistry` shape; an injectable directory and log closure.
- `load() async -> IntentPhraseFile`: never throws, never writes.
- `save(_:) async throws`: directory create, sorted-keys encode, `.tmp` write, rename over.
- `static encode` / `static decode(_:onInvalid:)` for byte-level tests.
- Caps (seeds; a retune is a reviewed edit): `maximumPhrases = 256`, `maximumFileBytes = 64 * 1024`,
  `maximumPhraseLength = 256`, `maximumIDLength = 128`.

Depends on `PhraseIntentRow` (phrase-resolver aspect). If the store's RED lands first it
may reference the type and fail to compile. That is an acceptable RED, but the sequencing
note prefers landing the row type first (see Dependencies).

## Out of scope

Enablement, arguments, a Settings editor, file watching (the wiring reads per call), and
migration of any other file.

## Acceptance criteria (failing tests first)

1. An absent file → `IntentPhraseFile.empty`, **zero** log calls.
2. An unreadable file, a non-object top level, `version != 1`, or a file over
   `maximumFileBytes` → empty with **exactly one** log call each. The file bytes are unchanged
   afterwards (load never writes).
3. Row-level skips, one log call each and the other rows kept: a missing or empty field; a
   non-string field (`"toolID": 1`, the F1 lesson: refused, never coerced); a phrase or id over
   its cap; a phrase whose normalization is empty (`"!!!"`); a duplicate normalized phrase (the
   **first** wins, and table order is preserved).
4. **The shell refusal:** a row with `providerID == "dev.vocca.shell"` is skipped with one log
   line naming the refusal, and it never appears in the loaded table.
5. More than `maximumPhrases` valid rows in a file → empty plus one log (**refuse, never
   clamp**: a truncated table is a different table).
6. `save` over `maximumPhrases` or `maximumFileBytes` throws a typed error and writes nothing
   (no `.tmp` left behind).
7. Round trip: save → load is equal; `encode` is byte-stable (sorted keys) across two calls;
   a stray `.tmp` is never read by `load`.
8. The byte-level pin: the encoded file for a fixed two-row table matches a literal. It
   contains no field beyond the three, and no timestamp, enablement or argument.

The normalization used for the empty/duplicate checks must be **the resolver's own**
(`PhraseIntentResolver.normalized(_:)`, public static), never a second copy. A test
asserts that the store's duplicate check and the resolver's match agree on one sample.

## Dependencies & sequencing

Needs `PhraseIntentRow` and `PhraseIntentResolver.normalized` from phrase-resolver. Land
phrase-resolver's GREEN first, then this aspect. Planning may still run the two in parallel
by agreeing the row's signature up front (PRD R1).

## Risks

- The shell id literal `"dev.vocca.shell"` duplicates `ShellProvider.providerID`. Reference
  the constant (same module) rather than a literal, so the two cannot drift.
