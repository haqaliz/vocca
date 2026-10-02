# Aspect spec: task-carrier

> Source: `docs/planning/spoken-task-seeding/prd.md` R1, R2, S1 · Date 2026-10-01.

## Problem slice and user outcome

The additive carrier and the provider's one-render substitution: `ActionInvocation
.taskText: String?`, the pure substitute helper (every `<task>` occurrence → the text),
the refusal paths, and the sentence's substituted render. User outcome: the argv that
runs is the argv the sentence showed, with the spoken words in place.

## In-scope requirements

- **`ActionInvocation.taskText: String?`** — additive, default nil (the
  `resolvedDirectory` precedent; 40+ construction sites compile unchanged);
  Foundation-free; **never `arguments`** (the gap-1 pin intact).
- **The substitution** (a pure helper beside `CodingAgentSentences`): every literal
  `taskPlaceholder` occurrence in the row's argv replaced with `taskText` — the
  deterministic rule pinned by a two-placeholder test (critique gap 1). describe and
  invoke share the one render.
- **The refusal paths** (all loud, all recorded, never a card, never a run):
  `taskText` present with no placeholder in the argv (the task has nowhere to go);
  placeholder present with no `taskText` (reachable only by a hand-built invocation —
  the surface refuses earlier); `taskText` over the 4096-UTF-8-byte bound (refuse,
  never truncate — the arguments precedent).
- **The sentence**: the substituted argv rendered verbatim (the existing sanitised
  clause + the `in <dir>` machinery untouched); the audit summary bound applies
  naturally (S1 — verified, never changed).
- **The exact-shape check**: re-run the carrier precedent's check (no test pins
  ActionInvocation's exact member set — verified once for `resolvedDirectory`, re-check
  for the second field).

## Out-of-scope

- The threading and the surface refusal (own aspects); the editor; the driver.

## Acceptance criteria (test-first)

1. An invocation without `taskText` behaves byte-identically to today (the existing
   argv renders; the `resolvedDirectory` machinery untouched).
2. With `taskText` and a single placeholder: the sentence shows the substituted argv
   verbatim; invoke's configuration runs the substituted argv (a counting engine
   asserts the exact arguments).
3. Two placeholders → both substituted (the deterministic rule).
4. `taskText` without a placeholder → the loud refusal, invoke never reached.
5. Placeholder without `taskText` → the loud refusal.
6. Over-bound `taskText` → refused, never truncated.
7. The gap-1 pin holds (arguments still refused).
8. The exact-shape check passes.

## Dependencies / sequencing

First. Before `utterance-threading` (which fills the field).

## Open questions

- None — the critique resolutions are recorded decisions.