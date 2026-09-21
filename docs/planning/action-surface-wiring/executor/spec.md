# Spec: executor (gate → audit recorder)

> Aspect of `action-surface-wiring` (C13 slice 5). Source: PRD R8, the slice-1 acceptance
> ("every executed action must appear in the audit log, asserted by reconstruction"), the
> "approved sentence is what reaches disk" property (`STATUS.md:126-131`).

## Problem slice

`ActionGate` cannot write the audit store (VoccaCore is Foundation-free). Today the probe
builds audit decisions directly (`ActionAuditDrive`), so no shipped code path connects
"submitted through the gate" with "recorded in the store". The surface needs exactly one
complete round trip both it and the probe share.

## In scope

- **`ActionExecutor`** (actor, `VoccaActions/`): the one caller of `ActionGate.submit` in
  the shipped configuration.
  - `submit(_ invocation, enablement, policy, approval, approvedSentence, mode) async ->
    ExecutedDecision` where `ExecutedDecision` carries the `ActionDecision` plus
    `auditRecorded: Bool`.
  - Records **every** decision to the injected `FileSystemActionAuditStore` via the existing
    `ActionAuditEntry.init(id:instant:invocation:decision:)` mapping —
    `autoRanReadOnly` / `confirmed` / `refused` (incl. `toolNotEnabled`,
    `approvedSentenceMismatch`) / `dryRun` — the full `ActionAuditDecision` vocabulary.
  - Recording failure never throws through: the decision stands, the failure is logged
    loudly, `auditRecorded == false` (the no-dropped-audit-record rule is about the
    *surface* being honest about a failed record, not about failing the action).
  - **Always supplies `approvedSentence`** when it surfaces a sentence to a human: the
    executor accepts the sentence the caller showed and passes it to the gate (the N2
    binding's caller-side obligation, pinned by a test that a mismatched sentence is
    refused).
  - Post-invoke record ordering for `AuditActionProvider`'s clear tool stays the provider's
    own (record written after the clear) — the executor records the *decision*; the
    provider's own clear-record is its own business (counterfactual-pinned already).
- The executor takes the store + a loud-log closure; no new module, no boundary changes.

## Out of scope

- Any UI; the confirmation card; discovery; server config. The wiring aspect wires the
  executor to the surface.
- Changing the audit vocabulary or the summary overload (declined summaries keep carrying
  bounded keys; two producers stay two).

## Acceptance (tests written first)

1. For each decision class the gate can produce (autoRanReadOnly, confirmed, refused —
  toolNotEnabled and approvedSentenceMismatch, dryRun), an executor round trip records
  exactly one entry reconstructing the decision, the provider/tool ids, and the summary.
2. Reconstruction: a second store instance reads back the recorded entries and each
  `ActionDecision` is recoverable from the entry fields.
3. Recording failure: a store whose commit throws (injected via the file-system seam)
  yields `auditRecorded == false` and the decision still returns; nothing throws through.
4. The executor's submitted `approvedSentence` reaches the gate: a sentence that differs
  from the gate's render is refused (the binding is live in the executor's path, asserted
  by attempting the call).
5. Dry-run via the executor: `mode: .dryRun` records `dryRun` and calls `invoke` zero times
  (stub call log).
6. The probe drive moves from hand-built decisions to the executor round trip (wiring
  aspect owns the probe line; this aspect owns the drive body change).
7. The executor names no network family and no `Process` — the module lints stay green.

## Dependencies & sequencing

- `sentence-binding` first (the `approvedSentence` parameter must exist).
- Consumed by `wiring` and the probe.