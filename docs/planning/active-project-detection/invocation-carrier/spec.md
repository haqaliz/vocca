# Aspect spec: invocation-carrier

> Source: `docs/planning/active-project-detection/prd.md` R2 · Date 2026-10-01.

## Problem slice and user outcome

The additive carrier that makes one arm-time resolution survive the whole confirmation
path: `ActionInvocation.resolvedDirectory: String?` (default nil — 59 construction sites
compile unchanged), the `WidgetConfirmationSignal` counterpart, the agent provider's
consumption (`invocation.resolvedDirectory ?? agent.projectDirectory`), and the
nil-tolerant sentence (no directory → no `in` clause). User outcome: the directory shown
on the card is byte-identical to the directory the child runs in, under the binding.

## In-scope requirements

- **`ActionInvocation.resolvedDirectory: String?`** — additive, default nil, the
  `arguments`-additive precedent (`ActionInvocation.swift:100-105`); Foundation-free;
  **never an `arguments` payload** (the gap-1 pin stays: an invocation carrying
  `arguments` is still refused by the agent provider).
- **Exact-shape check first** (the critique gap): verify no vocabulary test pins the
  invocation's exact member set (grep `ActionInvocation(` in Tests for equality/reflection
  pins; the Family A lint is file-membership, safe — but the plan must not assume).
- **The provider**: `describe` renders the sentence with
  `invocation.resolvedDirectory ?? agent.projectDirectory`; `invoke` sets
  `currentDirectoryURL` from the same resolution — the argv-that-runs doctrine extended
  to the directory (one resolution source, both halves).
- **The sentence**: `CodingAgentSentences` becomes nil-tolerant — directory absent → no
  `in <dir>` clause (the existing render + its pins update; the clause-less shape is a
  recorded decision, S1 of the PRD).
- **The signal**: `WidgetConfirmationSignal` gains the additive field (the card carries
  what the confirm path needs to rebuild the same invocation).
- **Audit honesty**: the audit stores the rendered sentence — a resolved directory is
  visible in the record, never the raw path outside the sentence (the summary-bound
  doctrine).

## Out-of-scope

- The resolution itself (own aspects); `ContextSnapshot`; the intent seam's signatures.

## Acceptance criteria (test-first)

1. An invocation without `resolvedDirectory` behaves byte-identically to today (all 59
   existing construction sites compile unchanged; the sentence renders the row's
   directory).
2. An invocation WITH `resolvedDirectory` renders it in the sentence (verbatim) and
   invoke runs in it (`currentDirectoryURL`) — describe and invoke share one resolution.
3. `nil` row directory + nil invocation directory → the clause-less sentence; invoke
   falls back to the pre-fix behavior (Vocca's cwd) — visible in the sentence, never
   hidden.
4. The gap-1 pin holds: `arguments` on an agent invocation is still refused.
5. The signal carries the field; the confirm path can rebuild the identical invocation.
6. No exact-shape pin broke (the critique gap's check passes; if one exists, the aspect
   stops and reports).

## Dependencies / sequencing

Independent of `working-directory-source`; before `agent-wiring-cwd` (which threads the
resolution into the carrier).

## Open questions

- None beyond the exact-shape check.