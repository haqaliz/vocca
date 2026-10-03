# Aspect spec: provider-baseline

> Source: `docs/planning/agent-auth-baseline/prd.md` R2, gap-2 pin · Date 2026-10-01.

## Problem slice and user outcome

Both providers carry the baseline into every configuration they build:
`CodingAgentProvider` and `ShellProvider` gain an injected `baselineEnvironment:
[String: String]` (additive init parameter, default `[:]` — the doctrine), and their
`ShellExecutor.Configuration` builds pass it. User outcome: the composition wires one
value; every child the providers spawn receives it.

## In-scope requirements

- **`CodingAgentProvider`**: the init's additive `baselineEnvironment` parameter
  (default `[:]`); `invoke`'s configuration carries it alongside the row's `environment`
  (the existing `environment: agent.environment ?? [:]` line gains the baseline — the
  executor's merge rule does the union).
- **`ShellProvider`**: the same additive parameter; its configurations (which today
  carry no environment — shell rows have none) gain the baseline.
- **The named consequence** (critique gap 2): once the composition wires HOME, SHELL
  rows' children receive it too — the shell provider's tests record this deliberately
  (a shell row's child sees the baseline when wired; the default stays byte-identical).
- **The default posture**: every existing construction site (the probe's drives, the
  tests) compiles unchanged with the default `[:]`.

## Out-of-scope

- The composition wiring (own aspect); the executor (own aspect).

## Acceptance criteria (test-first)

1. Both providers' configurations carry the injected baseline (a counting engine
   asserts the `Configuration.baselineEnvironment` value).
2. The default `[:]` is byte-identical to today (the existing provider suites pass
   unchanged).
3. The shell consequence is pinned: a wired baseline reaches a shell child; the unwired
   default reaches nothing.
4. The providers name no forbidden family (the transport lint green untouched — init
   parameters, not files).

## Dependencies / sequencing

After `executor-baseline`. Before `wiring-baseline`.

## Open questions

- None — the consequence is the recorded decision.