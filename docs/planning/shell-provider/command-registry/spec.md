# Aspect spec: command-registry

> Source: `docs/planning/shell-provider/prd.md` R1 + Data Model · Date 2026-09-22.

## Problem slice and user outcome

The persisted command definitions that `ShellProvider` describes and invokes. The user
configures named commands in a version-controllable JSON file, and the registry is the
single source of truth for what commands exist, what they run, and what radius they claim.
No command exists unless it is configured here, and nothing is configured out of the box.

## In-scope requirements

- **The `shell-commands.json` shape** (PRD Data Model): `version`, `commands[]` of
  `{ id, command: [String], readOnly: Bool?, parameters: [NamedParameter], clause: String? }`.
  Named parameters declare fixed slots (`$1`, …) with a display name.
- **Tolerant decode, absent is off**: load never throws; missing/corrupt file → empty
  registry with one loud log (the `ActionConfigStore.load()` precedent,
  `ActionConfigStore.swift:125-133`). Unknown keys rejected at every level (the
  wildcard-key refusal precedent, `ActionConfig.swift:57-71`).
- **Caps**: bounded command count (e.g. 64) and bounded total byte size (e.g. 64 KB),
  save throws on violation (the `ActionConfigStore` cap precedent, `:76-81`, `:169-193`).
- **Atomic writes** (temp-write-then-rename, the store precedent `:187-192`).
- **Destructive-by-default**: an absent `readOnly` is `false` — the command claims
  `BlastRadius.destructive`. `readOnly: true` is the only way to claim a read-only radius.
  (Founder decision; MCP "absent means unsafe" precedent.)
- **Validation at decode**: command id non-empty and bounded, argv non-empty and bounded,
  parameter names non-empty, no duplicate ids — a row that fails validation is skipped
  loudly, never fatal (the enablement-row skip precedent).
- **No arguments ever persisted here or in enablement**: enablement is membership in
  `ActionConfigStore` (providerID `dev.vocca.shell` + command id); the registry itself
  holds only definitions.

## Out-of-scope boundaries

- No execution, no `Process`, no `describe`/`invoke`. This aspect is storage shape only.
- No UI for editing commands (JSON hand-edit + the C5 user-dictionary precedent: plain
  readable JSON the user can version-control).
- No argument values at rest — definitions only.

## Acceptance criteria

1. A well-formed `shell-commands.json` decodes to a registry with the declared commands,
   including the `readOnly` default: absent → `false` (destructive).
2. Absent file, corrupt file, and an unknown-key file all load as the empty registry
   (never a throw), with one loud log each.
3. Save round-trips atomically (bytes survive); a cap violation throws and leaves the
   prior file intact.
4. A row with a duplicate id / empty argv / over-long id is skipped loudly; the rest load.
5. The registry never carries enablement or argument values — shape-only, pinned by a
   test reading the raw file bytes for a forbidden key (the config-store unknown-key
   refusal precedent).

## Dependencies and sequencing

First aspect. Nothing else consumes it until `provider`. Lives in `VoccaActions/Config/`
alongside `ActionConfigStore` (same module import rules: `["VoccaCore"]` only).

## Open questions / risks

- The cap values (64 commands / 64 KB) are starting numbers, seeded like the C2 store's —
  a retune is a reviewed edit. Record them as seeds, not gospel.