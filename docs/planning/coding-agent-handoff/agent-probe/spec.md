# Aspect spec: agent-probe

> Source: `docs/planning/coding-agent-handoff/prd.md` R7 · Date 2026-09-30.

## Problem slice and user outcome

The evidence line: `PROBE-CODING-AGENT` inside the zero-network interposer proves the
composed **default** cannot create an agent child and that a seeded configuration's round
trip works end to end through real stores — with every asserted fact an effect of the run,
never a constant. User outcome: the permanent release blocker ("the default configuration
makes zero network calls and spawns no child process") stays provable with the agent arm
composed.

## In-scope requirements

- **Drive** (`Sources/VoccaNetworkProbe/CodingAgentDrive.swift`): the `ShellDrive` shape
  — composed default facts read off a wiring over an **absent** registry (`agents=0`,
  `spawnsSubprocess=false` from the declared fact), then a seeded registry (`/bin/echo`
  fixture, `outwardFacing` by construction), enablement row in the shared config store, a
  second composition over the seeded file, the round trip arm → outwardFacing card
  sentence → `confirm()` → the **real `ShellExecutor`** runs the child (a real child of
  the probe process — `/bin/echo` makes no network; permitted), plus the dry-run `preview`
  row that records but never invokes. Stub-free except the provider's injected engine is
  the shipped executor (the `ShellDrive` pattern).
- **Report** (`PROBE-CODING-AGENT`): `store=real store.location=temporary
  store.isDefaultLocation=false agents=0 spawnsSubprocess=false seeded=1 card=yes
  invoked=1 decisions=refused,confirmed,dryRun ordinals=1-3 binding=matched` (field set
  finalized in the RED commit, the `ShellDrive` vocabulary).
- **Wiring into the probe**: `exerciseDefaultConfiguration()` calls the drive; the
  module-coverage cross-check gains the drive's witness in the placeholders list — the
  anticipated RED the registry aspect recorded is closed here.
- **Guards**: the expected-lifecycle constant + verbatim assertion + the guard-the-guard
  property test in `ZeroNetworkTests` (the `expectedShellLifecycle` shape).
- **D2 honesty paragraph** in the drive's doc comment: the agent child is the same blind
  hop; the probe proves the default cannot spawn, never that an enabled agent cannot
  egress.

## Out-of-scope

- Anything but the drive + its guards (no surface, no wiring, no store changes).

## Acceptance criteria (test-first)

1. The probe line's post-condition holds verbatim inside the interposer (zero NETWORK,
   zero RESOLUTION, `LOADED` present, exit 0).
2. The guard-the-guard property test refuses a weakened constant.
3. The module-coverage cross-check is green with the drive's witness (every module
   driven).
4. No probe run writes to `~/Library/Application Support/Vocca/` (`store.location=temporary
   store.isDefaultLocation=false`).

## Dependencies / sequencing

After `agent-wiring` (drives the composed wiring). Before `agent-record`.

## Open questions

- None — the field vocabulary is the ShellDrive precedent's, read back by the guards.