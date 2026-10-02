# Aspect spec: executor-baseline

> Source: `docs/planning/agent-auth-baseline/prd.md` R1, S1, gap-1 pin · Date 2026-10-01.

## Problem slice and user outcome

The reviewed executor change: `ShellExecutor.Configuration.baselineEnvironment`
(default `[:]` — byte-identical when not wired), the merge rule (baseline ∪ configured,
configured wins — even an empty configured value, pinned), and the updated env
acceptance. User outcome: one rule for every child; the scrub's N2 record refined in
writing.

## In-scope requirements

- **The field**: `baselineEnvironment: [String: String]` on `Configuration` (default
  `[:]`); `run()` sets `process.environment = configuration.baselineEnvironment
  .merging(configuration.environment) { _, new in new }`.
- **The merge edge pinned** (critique gap 1): an explicit configured entry wins even
  when empty (`"HOME": ""` in the row beats a real baseline `HOME`) — the row's intent,
  tested.
- **The env acceptance updates**: an empty default is byte-identical to today (the
  existing scrub rows unchanged); baseline + configured union; configured-wins; the
  caller's session never leaks (the existing scrubbed-env rows still pass — the
  baseline is declared, not inherited).
- **N2 record**: the doc comment's "never the caller's environment" line is rewritten
  honestly in the same commit ("never beyond the declared baseline and the row's own
  entries").

## Out-of-scope

- The providers and the composition (own aspects); anything but the executor.

## Acceptance criteria (test-first)

1. Default `[:]` → byte-identical to today (the existing env rows pass unchanged).
2. Baseline + configured → the union; configured wins over baseline.
3. An explicitly empty configured entry (`"HOME": ""`) beats a real baseline HOME (the
   intent rule).
4. Nothing beyond baseline ∪ configured reaches the child (the child prints env — the
   existing `env`-printing row extended).
5. The doc comment's N2 line is the honest rewrite (a comment pin or a reviewer's
   line — decide).

## Dependencies / sequencing

First. Before `provider-baseline` (which passes the field through).

## Open questions

- None — the merge edge is the recorded decision.