# Aspect 2: `settings-store`

**Merge order: 2nd.** No dependencies. Pure persistence, no UI.

## Problem slice

Nothing the user chooses in Settings survives a relaunch, and one thing they choose is discarded
immediately: `activeMode` initializes from the constant `DictationLoopRoot.defaultMode`
(`AppBootstrap.swift:888`) and is read from no store.

The house constraint is hard: `CompletionFlagStore.swift:17-20` is *"the one file in `Sources/`
permitted to name `UserDefaults`"*, pinned by the seam table at
`Tests/HarnessTests/InjectionSeamBoundaryTests.swift:1540`; the FileManager table at `:1294-1304`
is pinned at **exactly four** seams. A new persistence file is therefore a lint event, not a free
choice.

**Decision (interview):** one general UserDefaults-backed settings store, with the seam-table
amendment shipping **in the same commit** — the process `CompletionFlagStore` itself followed
("the lint table amendment ships in the same commit", its own doc comment).

**User outcome:** a setting, once chosen, stays chosen.

## In scope

- **R1** A settings seam (protocol + real implementation + test double) holding: engine selection
  (engine + tier) and activation mode.
- **R2** **Tolerant decode with a loud fallback.** An absent, malformed or unknown-case value
  yields the shipped default and logs at error — the `cleanup-config.json` precedent, never a
  silent reset.
- **R3** Synchronous reads, matching the existing store's rationale (the `main()` show decision
  already needs one; window-server rule).
- **R4** The seam-table amendment in the same commit, keeping every seam lint green.
- **R5** A stable on-disk representation for each persisted value, so a future rename of a Swift
  case does not silently reset a user's choice.

## Out of scope

- Reading the store from the composition root (aspect 3) or any UI (aspects 4, 5).
- Migrating the onboarding completion flag — decide and record, but changing it is optional and
  must not regress the `main()` show decision.
- The cleanup provider choice: that stays in `cleanup-config.json` (aspect 5), which is
  hand-editable by design.

## Acceptance criteria (tests first)

1. A written value reads back — over an injected `UserDefaults` suite, never `.standard`, so the
   user's real defaults are untouchable (the `CompletionFlagStore` test precedent).
2. Absent value ⇒ shipped default (Parakeet v3; the shipped `defaultMode`).
3. **Malformed/unknown value ⇒ shipped default AND an error log** — the loud half asserted, not
   just the fallback.
4. R5: the stored representation is pinned byte-for-byte by test, so a Swift rename that would
   change it fails CI.
5. Every seam lint stays green, and a planted second `UserDefaults`-naming file fails the seam
   table (the lint still bites after the amendment).
6. The test floor is raised in the same commit.

## Risks

- Widening the seam table is the kind of amendment that quietly becomes a licence to add more.
  The amendment should name the family and its one file, exactly as the existing rows do.
