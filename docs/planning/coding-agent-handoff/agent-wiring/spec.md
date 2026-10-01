# Aspect spec: agent-wiring

> Source: `docs/planning/coding-agent-handoff/prd.md` R4, R5, R6 (+ gap-3 pin from the PRD
> critique) · Date 2026-09-30.

## Problem slice and user outcome

The additive composition that makes `CodingAgentProvider` reachable — from the Actions-tab
arm surface **and** from the voice leg — while the composed **default** stays unwired:
nothing configured, nothing spawned, the D2 promise intact. User outcome: an agent row can
be armed, confirmed on the existing card, executed, audited; a phrase row can arm it by
voice; the copy states where the claim stops.

## In-scope requirements

- **Unwired default posture**: `AppBootstrap.configure` composes the agent wiring **only
  behind configuration + enablement**; with no `coding-agents.json` and no enablement
  rows, the fact carriers stay `agents=0`, `spawnsSubprocess=false`. Additive
  `CodingAgentWiring.swift` in the `ShellWiring` shape (`ShellWiring.swift:71` mirror).
- **`spawnsSubprocess` truthfulness**: declared for the configuration, not the capability
  (the shell precedent, `ShellWiring.swift:63-70`) — the provider can spawn; an absent
  registry is zero rows; the composed default pins `false`.
- **Arm leg** (the F-A precedent — the arm surface is not generic, rows exist only from
  `discoverySucceeded`): an **Agents section** on the Actions tab rendering the registry's
  rows as `ActionsToolRow`s (providerID `dev.vocca.agent`, radius `outwardFacing` always,
  `isEnabled` folded from the persisted enablement, default off — M7), reusing the shared
  toggle/Preview/Invoke row rendering and the generic bindings; a second row array +
  load action in `ActionsTabState` (the `shellRows`/`.shellConfigLoaded` pattern).
- **The D2 copy on the surface**: "Configuring a coding agent runs it on your machine with
  your configured project; Vocca cannot see inside a program it starts on your behalf —
  an enabled agent's egress is never provable." (drafted to match the shell copy's
  exact-in-spirit discipline).
- **Card routing**: `AppBootstrap`'s routed confirm/decline/arm/preview gain an
  `agent` branch by providerID (the `ShellProvider.providerID` routing precedent,
  `AppBootstrap.swift:756-774`).
- **Voice reach** (founder decision Q4): **no refusal** — `IntentPhraseStore` refuses only
  `dev.vocca.shell`, and a phrase row naming `dev.vocca.agent` resolves once the tool is
  enabled; the intent catalog (enablement) carries it automatically; `IntentWiring` is
  untouched. A test pins the reachability (phrases may name the agent provider) and that
  the disabled row resolves nothing.
- **Stale-row reconcile** (gap-3 pin): a row edited after provider construction shows on
  the tab (the surface reads the registry per call) but does not resolve in the provider
  (fixed toolIDs) — the surface's enablement tolerates stale rows (MCP precedent, never
  pruned), and `describe` answers the refusal at `.readOnly` for the stale id. A test
  pins the reconcile.
- **G5**: the composition change to `AppBootstrap.swift` re-anchors the pin deliberately —
  computed with `shasum -a 256`, never edit-to-match, in the `wiring: REFACTOR` commit;
  the dictation digests (`SessionMachine`, `DictationPipeline`) stay unchanged.
- **Inherited spine**: shared `ActionExecutor<Provider>` + the card + dry-run + sentence
  binding + re-render-after-record + in-flight refusal + policy floor `.none` recorded.

## Out-of-scope

- The registry store, provider, engine, probe (own aspects).
- Generic arm-surface row sources (the F-A finding is recorded, not fixed here).
- The interactive session, `{{utterance}}`, parameters (PRD deferrals).

## Acceptance criteria (test-first)

1. The composed default reads `agents=0 spawnsSubprocess=false` from the wiring's fact
   carriers with an absent registry.
2. A seeded registry + enablement row arms → card → confirm → the engine closure runs
   (counting), and every decision lands in the audit store.
3. The in-flight refusal holds (no arm while a session is active).
4. Sentence binding: a drift between the shown sentence and the granted approval is
   refused and re-prompts with a fresh render.
5. The voice leg: a phrase row naming `dev.vocca.agent` resolves `.toolCall` only for an
   enabled tool; a disabled tool resolves `.none` and never reaches the provider; the
   intent store refuses only `dev.vocca.shell` (the agent id is not refused).
6. A stale registry row (edited after load) shows on the tab and resolves to the
   `.readOnly` refusal, never a trap.
7. The Actions-tab Agents section renders rows with the D2 copy and default-off
   enablement; the row-toggle searches both row arrays.
8. G5: `AppBootstrap.swift`'s digest re-anchored deliberately; the two dictation digests
   unchanged; the re-anchor commit is separate and honest.

## Dependencies / sequencing

After `agent-registry` + `agent-provider`. Before `agent-probe` (which drives the composed
wiring).

## Open questions

- None — the PRD's approved posture resolves the mayEgress question as "copy is enough";
  no declared egress field on the row (recorded in the unit record).