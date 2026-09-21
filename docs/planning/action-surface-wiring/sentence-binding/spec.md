# Spec: sentence-binding (N2 tightening)

> Aspect of `action-surface-wiring` (C13 slice 5). Source: PRD R3 + the card caveat
> (`docs/planning/_card/issue.md:29-31`) + `action-safety-spine/prd.md:290-293`.

## Problem slice

N2's tightening was reserved "when a surface exists": bind the approval to the exact
sentence the person was shown, so an approval cannot be replayed against a different action.
The gate re-describes at every `submit`; between the UI showing sentence S and the user
confirming, S can change (e.g. an audit count moved), and the user would approve a sentence
they never saw. This aspect makes that refusal structural, in `ActionGate` itself.

## In scope

- `ActionGate.submit` gains an additive parameter `approvedSentence: String? = nil`.
- With `approval == .granted` and a non-nil `approvedSentence`, the gate compares it to its
  own freshly-rendered sentence and, on mismatch, returns
  `.declined(.approvedSentenceMismatch)` — **by attempting the call**, never by observing a
  UI.
- New bounded decline key `gate.approvedSentenceMismatch` (the `ActionDeclineReason`
  vocabulary).
- `nil` keeps every existing call site compiling with byte-identical behaviour (the F2
  precedent: the test is "does the default grant anything the caller did not ask for" —
  `nil` grants nothing).
- The mismatch refusal carries no summary (provider not invoked); it is recorded by the
  executor like any declined decision.

## Out of scope

- The confirmation-card UX of the mismatch (re-prompt vs dead end) — the wiring/confirmation
  aspects own that; the default decided in the PRD review: a mismatch renders a fresh card.
- Any change to `ActionApproval` (stays payload-free — per-invocation semantics).
- Any change to `ActionConfirmation` or its construction confinement lint.

## Acceptance (tests written first)

1. RED: a granted approval whose `approvedSentence` differs from what the gate renders is
   refused — asserted by attempting the call and receiving `.declined` with
   `approvedSentenceMismatch`; the provider's `invoke` is called zero times (stub call log).
2. A granted approval with the exact matching sentence proceeds to invoke (no false
   refusal).
3. A granted approval with `approvedSentence == nil` behaves byte-identically to today
   (proceeds), so the 42 existing call sites' semantics are untouched.
4. The new key is bounded (no free text) and stable (spelled `gate.approvedSentenceMismatch`).
5. A withheld approval with a mismatch sentence is refused by the existing confirmation
   path (withheld beats mismatch; the decision is still `confirmationRequired`-free —
   withheld → declined with `approvalWithheld`? — check the gate's actual withheld
   behaviour and pin whichever already holds, without changing it).

## Dependencies & sequencing

- No new dependencies. First aspect in the slice: the executor and wiring build on the
  parameter.
- VoccaCore remains Foundation-free (stdlib-only compare).

## Open questions

- None blocking. (Whether the gate's decline for withheld-with-mismatch reports
  `toolNotEnabled`-style or a separate key is decided by pinning existing behaviour in
  acceptance 5.)