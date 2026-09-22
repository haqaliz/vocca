# Aspect spec: wiring

> Source: `docs/planning/shell-provider/prd.md` R6, S3 · Date 2026-09-22.

## Problem slice and user outcome

The additive composition that makes `ShellProvider` reachable from the existing arm surface
while keeping the composed **default** unwired — nothing configured, nothing spawned, the D2
promise intact. The user outcome is a command that can be armed, confirmed on the existing
card, executed, and audited — with the copy stating where the claim stops.

## In-scope requirements

- **Unwired default posture** (the `NullIntentResolver` precedent): `AppBootstrap.configure`
  composes ShellProvider **only behind explicit configuration + enablement**; with no
  `shell-commands.json` and no enablement rows, the composed default's fact carriers stay
  `false`. Additive `ShellWiring.swift`-shaped composition, probe-safe
  (the `ContextWiring.swift` / `ActionWiring.swift` precedent).
- **`spawnsSubprocess` truthfulness**: any wiring that carries ShellProvider declares its
  value truthfully (the `StdioMCPTransport.swift:152` analogue); the composed **default**
  still pins `false` because nothing is configured.
- **Enablement reuse**: shell command enablement is `ActionConfigStore` rows (providerID
  `dev.vocca.shell` + command id), surfaced through the existing Actions-tab arm surface —
  **decide first** whether the generic enablement rows already render shell commands or a
  small shell leg is needed (PRD open question 1; the generic recipe suggests the former).
- **Arm-surface only** (founder decision): shell commands are reachable from the arm
  surface; the intent catalog is NOT composed over ShellProvider this slice — no `IntentWiring`
  change, no resolver catalog rows for `dev.vocca.shell`.
- **Inherited spine**: the shared `ActionExecutor<Provider>` + the confirmation card +
  dry-run + sentence binding + re-render-after-record + in-flight refusal all apply
  unchanged (they are generic over the provider).
- **Copy**: the D2 limit stated on the surface (the "Configuring a server is trust extended
  to its author" precedent, exact-in-spirit): configuring a shell command runs that command
  on your machine; Vocca cannot see inside a program it starts on your behalf.

## Out-of-scope boundaries

- No voice reachability (founder decision). No intent-catalog rows.
- No command-editing UI (JSON hand-edit).
- No changes to the MCP transport, the dictation path, or the existing action surface
  behavior (byte-for-byte where the pin demands).

## Acceptance criteria

1. `AppBootstrap.configure` composes ShellProvider additively; the composed default reads
   `commands=0` / `spawnsSubprocess=false` (see `probe`).
2. With a seeded registry + enablement, arming a shell command presents the existing card
   with the argv-derived sentence; confirm → execute → audit reconstruct; decline records the
   refused decision; dry-run records but never invokes.
3. A disabled command is declined before any `describe` (the enablement-first gate order).
4. No `IntentWiring`/resolver change — the intent catalog never names `dev.vocca.shell`
   (a probe/lint fact, see `probe`).
5. The dictation digests are unchanged (the G5 pin holds; re-anchored only if `AppBootstrap`
   must grow, computed never edited-to-match).
6. The D2 copy appears on the surface.

## Dependencies and sequencing

Fourth aspect — depends on `command-registry`, `execution`, `provider`. The open question
(arm-surface generic vs shell leg) is decided **here**, first, before composition work.

## Open questions / risks

- Whether the arm surface's generic rows already render `dev.vocca.shell` tools is a fact
  to check first — if yes, the wiring aspect is mostly the composition + copy + probe; if
  no, a small leg is in scope. The check is the aspect's first step.
- The `spawnsSubprocess` fact carrier is read by the probe; the wiring must declare it
  without lying (capability vs configuration — pin: the composed default is configuration,
  so `false`).