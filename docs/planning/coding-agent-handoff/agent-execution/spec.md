# Aspect spec: agent-execution

> Source: `docs/planning/coding-agent-handoff/prd.md` R3 · Date 2026-09-30.

## Problem slice and user outcome

The bounded run of a coding agent row. **Planning decision: no new engine ships** — the
shipped `ShellExecutor` (`Sources/VoccaActions/Execution/ShellExecutor.swift`) is the
engine, reused behind an injected closure; its `Configuration` already carries
`timeout`, environment, bounded capture, the terminate→poll→SIGKILL→poll reaping and the
no-orphan acceptance. The transport-permit lint therefore **stays at exactly two files** —
the agent child is a `ShellExecutor` child, covered by the existing reviewed entry, and the
D2 answer is inherited ("a shell child" → "a coding-agent child", same blind hop, same
wording). The per-row timeout (default 30 s, cap 600 s) flows into `Configuration.timeout`.

User outcome: an agent run is bounded, reaped, orphan-free, and its failure is a returned
value — the exact guarantees the shell executor already provides, pinned for the agent's
configuration shape.

## In-scope requirements

- **Reuse pin**: the agent engine is `ShellExecutor` — the aspect's tests drive the **real**
  executor with agent-shaped configurations (absolute executable, fixed argv, injected
  env, per-row timeout) and assert the contract holds: counted wait over the injected
  clock, terminate→poll→SIGKILL→poll, no orphan (`kill(pid,0) == -1 && errno == ESRCH`).
- **Timeout semantics**: a row's `timeoutSeconds` is the configuration's timeout; the
  counted wait cannot be extended by a frozen clock.
- **Output bound**: 4 KB per-stream capture, truncated and reported, never fatal — the
  agent's stdout beyond the bound is lost *loudly* (a recorded limit: an agent's long
  output is not a result channel this slice).
- **Environment**: exactly the row's `environment` entries are set, nothing else (N2 —
  scrubbed env stays the rule); stdin is `/dev/null` (one-shot runs are non-interactive).
- **No new `Process` spelling anywhere** — the provider names `ShellExecutor`, never the
  family (the lint's leg (a) must stay green for every new file).

## Out-of-scope

- Interactive/PTY sessions (deferred with the blocker named — R-C of the PRD).
- Output streaming or a result channel beyond bounded capture.
- Any change to `ShellExecutor` itself.

## Acceptance criteria (test-first)

1. An agent-shaped configuration (executable, argv, env, 30 s default timeout) runs to
   completion through the real executor.
2. A row's raised timeout (e.g. 120 s over the injected clock) is honored — the executor
   does not die at the 30 s default when configured otherwise.
3. A hung child is terminated, then SIGKILLed, and the no-orphan acceptance asserts
   `ESRCH` on the real child.
4. The child receives exactly the configured environment (a test child prints `env`).
5. No file added by this unit names any transport family (`ActionTransportProhibitionTests`
   stays green with the permitted set still exactly two).

## Dependencies / sequencing

Before or with `agent-registry` (defines the timeout/env shape the tests use). Before
`agent-provider` (which injects the engine closure).

## Open questions

- None beyond the recorded 4 KB output limit (a follow-on result channel is a later call).