# Aspect: `binding-vocabulary`

**Unit:** `hotkey-rebinding` · **Depends on:** — · **Module:** `VoccaCore` (pure, stdlib-only)

## Problem slice

Before anything can be rebound, Vocca needs to be able to say *what a legal binding is*. Today it
cannot: `HotkeyConfiguration` (`VoccaCore/HotkeyConfiguration.swift:20`) accepts any `UInt16` with
any `ModifierSet`, because the only two it ever sees are compiled in. The moment a user picks the
chord, "any `UInt16`" includes the key that makes their keyboard unusable.

**User outcome:** none directly — this aspect ships no surface. It is the decision table every
other aspect asks.

## In scope

- **M6 — the validity decision**, a pure function over a candidate `keyCode` + `ModifierSet`
  answering a closed enum: `accepted` / `refused(Reason)` / `warned(Reason)`. `warned` exists so
  `shortcut-conflicts` has somewhere to put an answer without a second vocabulary.
- The **closed refusal set**, as named cases:
  - `modifierOnly` — no non-modifier key. `HotkeyConfiguration` pairs a `keyCode` with a
    `ModifierSet`; modifiers alone have no representation.
  - `reservedByVocca` — Escape (`SessionKeyPolicy.escapeKeyCode = 53`), Vocca's own cancel key and
    the recorder's abort gesture.
  - `unmodifiedTextEntryKey` — an unmodified letter, digit, punctuation, Space, Return, Tab or
    Delete. Binding one makes that key untypeable system-wide, because the tap is active and
    swallows what is bound (`ARCHITECTURE.md` §13).
- **M7 — the safe single-key set**, one named table: F1–F20, Home, End, Page Up, Page Down, Help,
  and the keypad keys. Unmodified bindings from this set are `accepted`.
  **Corrected 2026-08-30 (`plan_20260830.md` §0.1): Forward Delete was removed** — it is an editing
  key, and swallowing it globally breaks deleting text in a tool whose job is putting text into
  fields. The arrow keys are named here as permanently excluded for the same reason, so nobody adds
  them later by pattern-matching `keyCodesCarryingFunctionImplicitly`, which is a different
  question with a different answer.
  This is what satisfies `PRODUCT_SPEC.md:322`.
- **M11 — the chord formatter**, one pure function `(keyCode, ModifierSet) -> String` rendering
  `⌃⌥⇧⌘` in the platform's canonical order plus a key name. Every surface uses it; no second
  dialect exists.
- `.capsLock` is masked before every decision, matching `ModifierSet.locking`'s existing treatment.

## Out of scope

- Persistence (`binding-store`), applying a binding (`rebind-boundary`), reading Apple's
  shortcuts (`shortcut-conflicts`), any view or copy (`general-tab-recorder`).
- Deciding *whether a chord is already taken by another app* — that is `shortcut-conflicts`, and
  §5.3 of the PRD says most of it is undecidable.

## Acceptance criteria (tests written first)

1. **The refusal set is closed and exhaustive.** Driven over every case of the reason enum, each
   with a candidate that produces it — so a new reason cannot be added without a test.
2. **Every unmodified text-entry key is refused**, driven over the full letter/digit/punctuation
   set rather than a sample — this is the bricking guard and a sampled test would miss a gap.
3. **Every member of the safe single-key set is accepted unmodified**, driven over the whole table.
4. **Escape is refused in every modifier combination**, including modified — Vocca's cancel must
   not become conditional on which modifiers are down.
5. **Modifier-only is refused** for each modifier and every combination of them.
6. **A modified text-entry key is accepted** — `⌃⌥D` is legal; the refusal is about *unmodified*.
7. **The formatter round-trips against a table** of known chords, byte-for-byte, including the
   shipped `⌥Space` — which must render exactly as `AppBootstrap.shippedHotkeyDisplayName` does
   today, so the menu bar's string does not change on the day it starts coming from here.
8. **Caps Lock never changes an answer**, asserted by driving each case with and without the bit.
9. **Single-source scan:** the safe-key table and the refusal table each appear in exactly one
   file (the `StrategyMemoryTargets` shape).

## Dependencies & sequencing

None. Build first — every other aspect asks this one. Buildable and fully testable headlessly;
no hardware, no window server, no TCC.

## Open questions / risks

- **The safe-key set is judgement, not measurement** (PRD R3). No user has asked for a key it
  refuses; equally none has been asked. It is one named table so widening it is a one-line change.
- Keypad key codes differ from their main-row equivalents; the table must use the keypad codes,
  and the test should assert a keypad `5` is accepted while a main-row `5` is refused.
