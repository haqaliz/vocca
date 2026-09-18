# Aspect spec — `action-seam`

**Boundary:** `VoccaCore/Actions/` — the protocol, the plain-data vocabulary, `BlastRadius`,
and `NullActionProvider`. Nothing that touches the system. No module is created here.

**Sequencing:** FIRST. Aspects `confirmation-gate` and `audit-log` both depend on this
vocabulary and can then proceed in parallel.

---

## Problem slice

C13's seam does not exist (`grep` for `ActionProvider` in `Sources/` returns zero). Every
other aspect needs a vocabulary to speak. This aspect establishes it and nothing else.

## In scope

- `ActionProvider` protocol with the **`describe` / `invoke` split** (PRD M5a):
  - `describe(_:) -> ActionSummary` — pure, side-effect-free, renders the concrete sentence
  - `invoke(_:confirmation:) -> ActionOutcome` — the only operation that acts; it cannot be
    called without a confirmation token
- The plain-data vocabulary: an invocation descriptor (provider id, tool id), `BlastRadius`
  (`readOnly` / `destructive` / `outwardFacing`), `ActionSummary`, `ActionOutcome`
- `NullActionProvider` — the shipped default: zero tools, refuses everything
- The seam-family lint (`ContextSeamBoundaryTests.swift:81-100` shape)

## Out of scope

The gate, dry-run, enablement, the audit log, the `VoccaActions` module, `Package.swift`
changes, any adapter, any UI, any wiring.

## Hard constraints

- **`VoccaCore` imports NOTHING — not even Foundation** (`CoreBoundaryTests.swift:116`
  enforces an empty allow-list). No `Data`, no `URL`, no `Date`, no `UUID`. Identifiers are
  `String`; instants are `Duration` components.
- Strict concurrency; every type `Sendable`. CI fails on any warning.
- The `ContextProvider` D1 precedent: if the contract must be synchronous and non-throwing,
  say so in the type and record the deviation rather than drifting.

## Acceptance criteria (written RED first)

1. `ActionProvider` exists with both operations; `describe` is not `async throws` if the
   contract says it cannot fail — pinned by the signature test.
2. `NullActionProvider` exposes zero tools and refuses every invocation, including a
   `readOnly` one.
3. **`invoke` is unreachable without a confirmation token** — the token type's initializer
   is inaccessible outside the gate's module. Asserted as the type-level fact it is.
4. `BlastRadius` is a closed enum; a `readOnly` value is distinguishable from the two
   confirming values by a single documented predicate (so the gate has one place to branch).
5. The seam-family lint: the action vocabulary's identifiers appear only in the permitted
   `VoccaCore/Actions/` files — **both directions**, plus a planted control asserting the
   detector fires on a deliberately violating sample, plus a comment-strip control.
6. A vacuity guard on the lint: the permitted file list is asserted non-empty and each file
   asserted to exist, so a rename cannot make the lint pass by scanning nothing.

## Open questions

- Does the confirmation token live in `VoccaCore` (so `invoke`'s signature can name it) while
  its initializer stays private to the gate? Resolve in the plan — it decides whether the
  gate is a separate module or a separate file.
- Whether `ActionOutcome.failed` carries a reason **key** rather than a message, so the audit
  entry stays Foundation-free and bounded.
