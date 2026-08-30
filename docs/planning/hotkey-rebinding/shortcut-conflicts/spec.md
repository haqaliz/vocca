# Aspect: `shortcut-conflicts`

**Unit:** `hotkey-rebinding` · **Depends on:** `binding-vocabulary`
**Modules:** `VoccaCore` (the decision), a new adapter file (the read)

> **This is the unit's weakest must-have, kept deliberately and marked as the first thing to cut.**
> Shipping the unit without it was offered and declined; the choice was "Apple's shortcuts plus
> honest copy".

## Problem slice

`PRODUCT_SPEC.md:252` promises "conflict detection against system shortcuts". Most of that promise
is undeliverable, and the PRD says so at §5.3:

- `com.apple.symbolichotkeys` covers **only Apple's own remappable shortcuts** — Spotlight, Mission
  Control, screenshots, input-source switching. Undocumented, but readable with no entitlement.
- There is **no API to enumerate hotkeys registered by other processes**, whether by Carbon
  `RegisterEventHotKey` or their own `CGEventTap`.
- **So Raycast and Alfred — the two apps risk C1-E actually names — are structurally invisible.**
  The detection cannot see the risk it was written for.

**User outcome:** picking ⌘Space says "Spotlight uses this". Picking ⌥Space says nothing, because
Vocca genuinely cannot see Raycast — and the copy says that rather than implying a clean check.

## In scope

- **M8** — a `SystemShortcutReader` seam in `VoccaCore` returning the occupied chords it knows
  about, with the pure decision above it: a candidate matching one yields
  `warned(.usedBySystemShortcut(name:))` from `binding-vocabulary`'s existing vocabulary.
- The adapter: read `com.apple.symbolichotkeys`, decode the `[characterCode, keyCode, modifierMask]`
  parameter triples, honour each entry's `enabled` flag, and map the IDs we can name to
  human-readable names. Unknown IDs are reported by chord with no name rather than dropped.
- **Warn, never refuse** — the user's Spotlight may be remapped or disabled, and their machine is
  the authority on that, not our table.
- **Tolerant to the point of silence:** absent, unreadable, or unparseable ⇒ **no warning**. A
  detection failure must never block a rebind.

## Out of scope

- **Third-party detection of any kind** (PRD N1, N2). The empirical arm-and-observe probe is
  deferred because it rests on an **UNVERIFIED** claim — whether another process's
  `RegisterEventHotKey` starves our tap has never been measured, and we do not build on an
  unmeasured assumption. A hand-maintained per-app preference table is deferred because it goes
  stale silently.
- The copy stating the limit — that is `general-tab-recorder`'s M9.

## Acceptance criteria (tests written first)

1. **A candidate matching an enabled system shortcut warns, and names it** — over a fixture plist.
2. **A candidate matching a *disabled* entry does not warn.** The `enabled` flag is honoured.
3. **An unknown ID warns without a name** rather than being dropped — an unnamed collision is
   still a collision.
4. **Absent / unreadable / malformed ⇒ no warning and no refusal**, driven over each shape,
   including a truncated parameter array and a non-integer modifier mask.
5. **A warning never blocks:** `warned` is accepted by the rebind path, pinned by test, so a
   detection change can never become a refusal by accident.
6. **The modifier mask maps to `ModifierSet` correctly**, over a table — the plist's mask is
   Carbon's, not `CGEventFlags`' and not ours, so this is a real translation with a real chance of
   being wrong.
7. **Seam lint:** whatever API family the reader names is confined to that one file, and the seam
   table's "exactly N" pin is updated with it.

## Dependencies & sequencing

Needs `binding-vocabulary` for the `warned` case. Independent of `binding-store` and
`rebind-boundary` — buildable in parallel with either. The decision is headless over fixtures; the
adapter reading the real user's plist is executed by nothing in CI.

## Open questions / risks

- The `symbolichotkeys` format is undocumented and could change (PRD R7). Mitigated by criterion 4:
  every failure mode is silence.
- Which shortcut IDs to name. Spotlight (32/33) is the one that matters; the rest can ship unnamed
  and be named as they are confirmed on a real machine.
