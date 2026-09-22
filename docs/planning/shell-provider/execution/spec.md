# Aspect spec: execution

> Source: `docs/planning/shell-provider/prd.md` R4 · Date 2026-09-22.

## Problem slice and user outcome

The subprocess engine — the safety-critical core that actually runs a configured argv on the
user's machine. This is where the D2-shaped concerns are concrete: a child that never dies,
or that outlives the call, is the failure this engine exists to make impossible. The user's
trust in "the card said what runs" is only as good as this engine's discipline.

## In-scope requirements

- **Fixed argv, no shell**: the engine executes the configured argv directly (`Process` with
  `executableURL` + `arguments`), never `/bin/sh -c`. No shell expansion, no metacharacters,
  nothing typed at call time.
- **Bounded timeout, injected clock, wait-count**: a hard ceiling of **30 s** enforced over
  an injected clock; the wait uses a **counted** loop so a spin loop cannot pass (the
  stdio-transport contract, `StdioMCPTransport.swift`). A timed-out child is terminated and
  the outcome is a bounded `ActionOutcome.failed`.
- **No orphan**: after termination, asserted `kill(pid, 0) == -1 && errno == ESRCH` —
  ESRCH specifically, because a **zombie answers `kill(pid, 0)` successfully** (the
  stdio-transport acceptance). The engine terminates the child and reaps it.
- **Bounded output capture**: stdout/stderr captured to a bounded buffer (e.g. 4 KB);
  overflow is truncated, never fatal.
- **Exit-code mapping**: 0 → success; non-zero → `failed` with a bounded reason key
  (`shell.exitCode`); termination by timeout/signal → distinct bounded reason keys.
- **Failure stays a returned value**: the engine returns an `ActionOutcome`-shaped result,
  never throws — the `async, never async throws` seam discipline
  (`ActionProvider.swift:52-57`).
- **No environment leakage** (nice-to-have N2): the child receives a scrubbed environment
  (the configured vars or none), never the full caller environment.

## Out-of-scope boundaries

- No `describe`/`invoke` — this is the engine `provider` calls, not the seam conformance.
- No stdin; no interactive commands; no sudo/privilege escalation.
- No network guarantee beyond what the engine's caller (the zero-network probe) asserts.

## Acceptance criteria

1. A benign argv (`/bin/echo`) runs to completion; the outcome is success and the exit code
   is read back.
2. A non-zero exit (`/bin/false`) yields `failed` with the bounded `shell.exitCode` key.
3. A sleeping argv under the injected clock reaches the 30 s ceiling and is terminated —
   a seeded hung child cannot pass; the timeout is `failed`, never a hang.
4. After termination the child is gone: `kill(pid, 0) == -1 && errno == ESRCH` — asserted on
   a real child, the no-orphan acceptance (zombie-answering-ESRCH means this is exact).
5. A flood child (writes unbounded output) is capped at the buffer bound and still
   terminates normally.
6. The engine's failure paths are returned values, never throws.

## Dependencies and sequencing

Second aspect (after `command-registry` — the engine is agnostic to the registry but the
provider needs both). Runs real `Process` in CI on macOS runners — the stdio-transport
precedent. Lives in `VoccaActions/Execution/` (names `Process` → subject to the
transport-permit widening landed in the `provider` aspect's REFACTOR; sequence the widening
commit first so this aspect is never red for lint).

## Open questions / risks

- The 30 s ceiling and 4 KB output cap are seeds, recorded as such.
- Reaping: `Process` termination + wait in Swift 6 strict-concurrency — the no-orphan
  acceptance is the guard that catches a half-reap.