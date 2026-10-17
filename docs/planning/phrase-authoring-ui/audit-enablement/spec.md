# Aspect spec — `audit-enablement`

**Parent PRD:** `docs/planning/phrase-authoring-ui/prd.md` · **Modules:** `VoccaUI` + `VoccaBootstrap`
· **Independent of:** `phrase-store-validation`, `phrase-authoring` (may land first or in parallel).

## Problem slice

**F-A** (`CAPABILITY_ROADMAP.md:979`, `:1058`): the audit tools (`audit.count`, `audit.clear`)
have no Actions-tab enablement row, so enabling them is a hand-edit of `action-config.json`. The
recorded finding is that "the arm surface is not generic — an enablement row alone renders
nothing": rows appear only from MCP `discoverySucceeded` or a registry read (`ShellWiring.listCommands`,
`CodingAgentWiring.listAgents`). The audit provider surfaces no row source (`AuditActionProvider.swift:106`
has `toolIDs`, but no wiring exposes it). This aspect adds that row source and the section.

## In-scope requirements

1. A **row source** for the audit tools: a wiring list closure (mirroring
   `ShellWiring.listCommands` `ShellWiring.swift:218-231`) returning `audit.count` (read-only) and
   `audit.clear` (destructive) as UI rows, radius from `AuditActionProvider.describe`
   (`AuditActionProvider.swift:125-146`).
2. An **Audit tools** section in `ActionsTabPage`, reusing `toolRow(_:)` (`:267-301`), default off,
   with the section's D2 copy and an explicit **destructive warning** on the `audit.clear` row
   (it permanently deletes the audit log).
3. **Reducer** wiring: `auditToolsLoaded` (+ `isAuditToolsLoaded`), folded default-off with
   enablement reapplied from `ActionConfigStore`, exactly the shell pattern
   (`ActionsTabState.swift:270-292`, `:34-37`).
4. **Bindings** — `SettingsBindings.loadAuditTools` (+ a "claims nothing" default) and reuse of the
   existing `setToolEnabled` (`SettingsView.swift:261`) for toggles, wired at the root; the row
   source reads `AuditActionProvider.toolIDs` (no spawn, no discovery).
5. Enablement writes the `(providerID: "dev.vocca.audit", toolID)` pair the resolver's catalog
   reads (`ActionConfig.swift:89-99`, `IntentWiring.swift:230-240`) — so a phrase naming an
   enabled audit tool resolves.
6. No run/invoke affordance beyond what `toolRow` already provides for other providers (arm /
   preview reuse) — **or** deliberately omit arm/preview for audit rows if the shared `toolRow`
   can't be reused safely; decide in tech plan.

## Out of scope

- The phrase authoring surface (`phrase-authoring`).
- Any change to `AuditActionProvider` behavior, the gate, the card, or the audit store.
- MCP/shell/agent row sourcing (shipped).

## Acceptance criteria (written first — RED)

- `A1` — **M4:** on load, `audit.count` and `audit.clear` render as rows, default **off**
  (absent-is-off), radii read from the provider.
- `A2` — toggling `audit.count` writes `{providerID: "dev.vocca.audit", toolID: "audit.count"}` to
  `action-config.json`; the row flips; `ActionConfigStore.loadEnablement` reflects it.
- `A3` — with the audit tool enabled, a phrase naming it resolves through the composed provider
  (integration with the resolver's catalog gate).
- `A4` — the composed **default** (no audit rows enabled) is unchanged: `PROBE-CODING-AGENT` /
  the audit default still reads `agents=0 spawnsSubprocess=false`; enablement empty.
- `A5` — the section carries the D2 copy and the `audit.clear` destructive warning (copy + source
  scans, the `ActionsTabTests` D2-placement precedent `:430-451`).
- `A6` — the row source names no new network/`Process` symbol; the transport lint stays two files;
  the Actions-tab family scans stay green.
- `A7` — `loadAuditTools` default claims nothing (the bindings-defaults test).

## Dependencies / sequencing

Independent of the phrase aspects; shares the Actions-tab reducer/page and the `AppBootstrap`
construction site. Sequence with `phrase-authoring` so `AppBootstrap` is edited once where
possible (one G5 re-anchor), or accept two.

## Open questions

- Should audit rows expose arm/preview (shared `toolRow`) or a toggle-only row? `audit.clear` is
  destructive — a preview is honest ("Permanently delete N …"); an arm on a toggle-only section
  may be undesirable. Recommend toggle-only rows with the destructive warning; decide in tech plan.
- Whether `dev.vocca.audit` should gain a display name in the section copy (`AuditActionProvider`
  has none).
