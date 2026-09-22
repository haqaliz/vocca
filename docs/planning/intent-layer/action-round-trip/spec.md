# Aspect spec: action-round-trip

> Source: `docs/planning/intent-layer/prd.md` R3, R5, R6 · Branch `feat/intent-layer/aliz`
> · Date 2026-09-22.

## Problem slice and user outcome

The wiring that makes a resolved utterance an *action*: only enabled tools are ever
resolved to, the voice action runs the existing executor → card → confirm/decline round
trip, every decision is recorded, and the never-silenceable blast-radius floor is pinned
by a test. The user's spoken "clear the audit log" lands in the audit log with the same
safety properties as the tab's click.

## In-scope requirements

- `Sources/VoccaBootstrap/IntentWiring.swift` — the additive recipe (the
  `ActionWiring.swift` shape):
  - catalog-from-enablement: only `ActionConfigStore.loadEnablement()`'s rows reach the
    resolver (never-read at the intent level — a disabled tool is never resolved to);
  - the executor leg: `root.actionExecutor.submit(…, approval: .withheld, approvedSentence:
    nil, mode: .live)` → on `.confirmationRequired`, re-render after the record
    (`provider.describe` again) and `widgetStore.presentActionConfirmation` with a fresh
    generation token; then the **existing** `root.actionConfirm`/`root.actionDecline`
    closures complete the human leg (generation guard, `.granted` with `approvedSentence`
    verbatim, mismatch re-prompt);
  - the card-up guard: while the store's confirmation is non-nil, a second voice action
    refuses to present (the replacement-card hazard);
  - spoken acks per terminal decision (confirmed → "Done." / the outcome sentence;
    declined → "Cancelled."; `auditRecorded == false` → "Something went wrong — the
    action was not recorded."; refused/notInvoked → silent or a bounded notice);
  - policy floor `.none` (inherited, recorded in `ActionWiring.swift:203`'s decision).
- `Tests/HarnessTests/IntentRoundTripTests.swift` — the round trip over probe doubles
  (the `ProbeActionProvider`/`InMemoryMCPTransport` shape): utterance → resolve → gate →
  confirmationRequired → present → confirm → audit row reconstructs; decline path
  recorded; dry-run never touches `invoke`; the card-up guard refuses a second
  presentation.
- `Tests/HarnessTests/EscapeValveTests.swift` — the §8 floor: an outward-facing
  invocation always confirms — no approval value, policy floor, or mode auto-runs it
  (the `BlastRadius.requiresConfirmation` single branch point pinned by name).

## Out-of-scope boundaries

- No new UI (card reuse only). No `ShellProvider`, no MCP discovery wiring (D2:
  `discovery.unwired`), no argument-building UI, no time-boxed trust (decided and
  deferred, R6). No change to `ActionGate`, `ActionExecutor`, the audit store, or the
  config store. No `Process` anywhere in the wiring.

## Acceptance criteria (test-first)

1. A matched utterance → invocation → `.confirmationRequired` → card presented with the
   gate's sentence verbatim (generation token fresh).
2. Confirm (via the existing confirm closure) → the audit row reconstructs
   (provider/tool/decision/sentence); `approvedSentence` matched.
3. Decline → the refused decision is recorded; no `invoke` call.
4. Disabled tool: the resolver never receives it (never-read); a direct attempt to
   resolve to it yields `.none`/`.ask`, never a call.
5. Card-up guard: a second voice action while a card is up refuses to present.
6. §8 floor: an outward-facing tool always confirms under every approval/policy/mode
   shape the test enumerates.

## Dependencies and sequencing

Depends on `intent-seam` (vocabulary) and `converse-step` (the handler slot). The wiring
is composed into `AppBootstrap.configure` by the `probe` aspect's composition work — this
aspect builds the recipe and its tests over probe doubles; the composition root wiring is
the `probe` aspect's (R7).

## Open questions / risks

The composed executor is `ActionExecutor<AuditActionProvider>`; the recipe is generic over
`Provider` (the `ActionWiring<Provider>` shape) so the probe can compose a stub provider.
The spoken-ack copy is provisional until the founder's real run (SMOKE 148-149); the
record aspect owns the final copy.