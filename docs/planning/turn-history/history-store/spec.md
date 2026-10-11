# history-store — aspect spec

Aspect 1 of `turn-history`. Source: `../prd.md` (approved 2026-10-11). Planning decisions:
the store is its **own adapter module** (`VoccaConversation`) — the `ModuleBoundaryTests.swift:106-113`
recorded rule ("a UI module owning persistence inverts the layering, and rooting the seam in
`VoccaBootstrap` would have forced permitting `AppBootstrap.swift`, which already names
`FileManager`") — and a **9th FileManager seam** in the per-seam lint table.

## Problem slice / outcome

The bounded, local, purged store of completed CONVERSING turns: an actor over a versioned JSON
file behind an injected filesystem seam, oldest-first eviction at 50 turns, 2000-character text
caps, load-on-launch, clear-deletes-the-file. No UI, no driver, no composition changes.

## In scope

- New module `VoccaConversation`: `Package.swift` product + target (dependencies exactly
  `["VoccaCore"]`), `ModuleBoundaryTests` expectedModules/adapterModules rows, a
  `VoccaConversationTargetTests` suite (the `VoccaContextTargetTests` pattern).
- The seam in `VoccaCore/Conversation/ConversationRecording.swift` (Foundation-free):
  `recordTurn(utterance:reply:)`, `markLastTurnInterrupted()` — `async`, never `async throws`
  (the `local-data-provider` lesson).
- `Sources/VoccaConversation/ConversationHistoryStore.swift`: `ConversationFileSystem` seam +
  `DefaultConversationFileSystem` (atomic temp→replaceItemAt), `ConversationTurn`
  (utterance, reply, interrupted), caps `maximumTurns = 50` / `maximumTextCharacters = 2000`,
  the actor store conforming to `ConversationRecording`; `load()` (never throws, never writes),
  `currentTurns()`, `clear()`; injected `onChange: @Sendable (Int) -> Void` (new count, after
  every mutation **and** after the launch load); default directory
  `~/Library/Application Support/Vocca/conversation.json`.
- The 9th seam row in `InjectionSeamBoundaryTests` (`"conversation":
  ["ConversationHistoryStore.swift"]`, root `VoccaConversation`) + both exact-set pins widened
  (+ the mirror pin in `ReplyRenderingInvariantTests:227-247`).

## Out of scope

The driver hook (aspect 2); UI/menu/wiring (aspect 3); docs/floor/SMOKE (aspect 4);
timestamps, per-session grouping, search, export, migration (version 1 is new).

## Acceptance criteria (the failing tests, written first)

H1 **Module**: `VoccaConversationTargetTests` passes (Package.swift declares product + target;
dependencies exactly `["VoccaCore"]`; `VoccaBootstrap`'s dependency set includes it;
`Sources/VoccaConversation` exists with a `.swift` file); `ModuleBoundaryTests` includes it in
expectedModules + adapterModules; no other boundary rule moves (VoccaUI still imports only
VoccaCore among Vocca modules).
H2 **Seam table**: the FileManager lint permits exactly one file for the `"conversation"` seam
with root `VoccaConversation`; a second FileManager-naming file there fails (the existing
detector, exercised by its planted control).
H3 **Record & round-trip**: `recordTurn` appends `(utterance, reply, interrupted: false)`
preserving order; a fresh store over the same file returns the identical list (relaunch);
texts survive byte-for-byte within the cap.
H4 **Bounds**: with 50 turns stored, the 51st **evicts the oldest** (deliberate divergence from
the settings stores' refuse-never-clamp — recorded); texts longer than 2000 are truncated at
the bound (one documented bound, mirroring `WidgetTiming.maxReplyCharacters`); no other field
exists in a record.
H5 **Mark & clear**: `markLastTurnInterrupted` marks the most recent turn only; with no turns it
is a no-op; `clear()` deletes the file (bytes off disk — asserted through the seam) and empties
state; `load()` over a missing file answers empty and never writes.
H6 **Shape & pins**: atomic temp→replace asserted through the injected seam (spy); version 1;
tolerant decode skips invalid rows; the encoded bytes carry exactly `version` + `turns` with two
strings + a bool per turn — no timestamps, no extra keys; `onChange` fires with the new count
after record/clear and after the launch load.

## Risks

The first text-carrying store other than the recovery journal: every bound, every truncation and
the clear must be acceptance tests, not promises (PRD gap 1). No egress: the seam is
FileManager-only, and the zero-network suite must stay green when the store is later composed.
