# Card: feat/shell-provider

> Inline brief — no GitHub issue. Source: the `vocca-next` recommendation (2026-09-22),
> itself grounded in the C13 slice records (`action-safety-spine`, `local-data-provider`,
> `mcp-protocol`, `stdio-transport`, `action-surface-wiring`, `intent-layer`).

## The unit

**C13 slice 7 of N: `ShellProvider`** — the P4 "run commands" leg of the wedge, and the
highest-blast-radius `ActionProvider` the safety spine was built for. Named remaining C13
machinery (`CAPABILITY_ROADMAP.md:483-488`); deferred for sequencing, not blocked
(`action-surface-wiring/prd.md:219`, `intent-layer/prd.md:253`).

The unit builds a shell-command provider behind the existing `ActionProvider` seam:

- **`describe` renders the concrete sentence** — never a bare command echo. What the
  user is shown is what will happen, in the C13 `describe`/`invoke` split
  (`action-safety-spine`).
- **`invoke` runs the configured command set on the user's machine**, through the
  **shared** executor and gate — `approval` withheld, sentence binding, every decision
  recorded, dry-run with zero side effects (the `AuditActionProvider` precedent).
- **Composed unwired and off by default**, so the default configuration still spawns no
  child (the D2/stdio precedent: `stdio-transport`). A probe (`PROBE-SHELL`) drives the
  composed default inside the zero-network interposer asserting `spawnsSubprocess=false`.
- The **blast radius is the provider's own claim**; the gate's `requiresConfirmation`
  floor (the §8 `EscapeValveTests` pin) must still hold for shell actions — the floor can
  only escalate, never de-escalate.

**Acceptances, written first per repo test-first doctrine:**
1. A destructive/outward-facing shell action without confirmation is **refused by
   attempting the call** — the C13 load-bearing structural test
   (`CAPABILITY_ROADMAP.md:394`).
2. Dry-run produces zero side effects — asserted by a stub that fails if invoked.
3. Every executed action reconstructs from the append-only audit log.
4. The composed default spawns no child even with ShellProvider present (enablement off);
   `PROBE-SHELL` drives it inside the zero-network interposer.
5. `describe` renders the concrete sentence (never a bare command echo).

**Caveats (record in the unit, don't hide):**
- **R8 is amplified here** — shell is unboundedly destructive, and the intent
  classifier's accuracy is unmeasured (code-level seeds, `intent-layer`).
- **N2 is inherited**: an approval asserts a human said yes and cannot verify it; the
  sentence binding narrows what an approval can be replayed against.
- **D2**: a spawned child is not observable, and a restricted child purges the interposer
  env — the zero-network guard cannot see a shell child's egress. The copy must say where
  the claim stops (the `stdio-transport` README precedent).