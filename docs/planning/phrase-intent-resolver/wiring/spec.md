# Aspect: wiring

## Problem slice

Compose the phrase resolver as the shipped default, reading the user's file per turn
without breaking the recipe's probe-safety or the safety spine (PRD R5, R6, R7).

## In scope

- `composeIntentWiring(configStore:provider:executor:resolverProvider:root:)`, where
  `resolverProvider: @Sendable @MainActor () async -> any IntentResolver` is called once per
  `resolve`. The existing `resolver:` overload forwards `{ resolver }`, so existing call sites
  compile unchanged.
- `AppBootstrap.swift:701`: `NullIntentResolver()` → a provider over the real
  `IntentPhraseStore` that builds `PhraseIntentResolver(rows: await store.load().phrases)`.
  The root's `intentResolver` fact slot carries a value the probe can read the type from
  (decided in the plan against the existing slot shape).
- The G5 re-anchor in REFACTOR: recompute with `shasum -a 256` and update
  `TurnTakingComposedAcceptanceTests` `e9aa45bb…` in the same commit. The dictation digests
  must not move.

## Out of scope

The converse driver (no signature change), the card, the executor, the gate, and the keyword
resolver's composition.

## Acceptance criteria (failing tests first)

1. **Probe-safe:** composing the recipe performs **zero** phrase-store reads. A counting
   store double reads 0 after composition and 1 after one `resolve`.
2. **No relaunch:** write a phrase file, resolve (→ `.toolCall`), rewrite it without the row,
   resolve again (→ `.none`), all on one composed wiring.
3. **The load-bearing refusal:** a phrase resolving to an enabled **destructive** tool →
   `performAction` yields `.confirmationRequired`, a card is presented, and the provider's
   invoke log is **empty**. Asserted by attempting the call.
4. **§8 floor:** `EscapeValveTests` gains a row where an outward-facing tool reached through
   `PhraseIntentResolver` confirms under every approval, policy and mode shape.
5. **Disabled / unknown:** a phrase naming a tool with no enablement row → `.none` from
   resolve, and the provider's describe and invoke logs are empty.
6. **Shell never reachable by voice:** a phrase file containing a `dev.vocca.shell` row, with
   that shell command *enabled*, resolves `.none`.
7. The existing `IntentRoundTripTests` / `IntentDriverIntegrationTests` pass unchanged (via
   the forwarding overload).
8. The G5 pin passes with the new digest, and the dictation digests are unchanged.

## Dependencies & sequencing

After phrase-resolver and phrase-table-store GREEN.

## Risks

- The root's fact slot type: if it is typed `any IntentResolver`, a provider closure can't
  report "PhraseIntentResolver". The plan must pick either a constructed-empty resolver
  carried for the fact or a small declared-type string. It must be read off the run, never a
  literal (the probe's "every field an effect of the run" rule).
