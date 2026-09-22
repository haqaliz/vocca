# Aspect spec: provider

> Source: `docs/planning/shell-provider/prd.md` R2, R3, R5, S1 · Date 2026-09-22.

## Problem slice and user outcome

The `ShellProvider` conformance itself — the third real `ActionProvider` — plus the two
structural obligations that make it legal: the **reviewed transport-permit widening**
(ShellProvider names `Process`, so the lint's permitted set grows from exactly one file to
two, with the D2 answer recorded in the widening) and the **Family-A lint rows** the
conformance forces. The user-facing outcome is a command that can be described concretely
and invoked only through the gate.

## In-scope requirements

- **`ShellProvider: ActionProvider`** (`ActionProvider.swift:65-95`), an actor over the
  registry + the execution engine: `toolIDs` from the registry (nonisolated, fixed at
  construction — the `MCPProvider.swift:132` shape).
- **`describe` derives the concrete sentence from the argv** (founder decision): the
  command name + the rendered argv (`key = value` for supplied parameter values, sanitised,
  sorted — the `MCPProvider.swift:294-327` discipline) + the optional authored `clause`,
  sanitised. Never a bare command echo; never trusted authored prose. Unknown command →
  refusal summary, never a trap.
- **Blast radius destructive by default** (founder decision): absent `readOnly` →
  `BlastRadius.destructive`. `readOnly: true` → `.readOnly`. The gate's escalate-only
  policy can only raise this (the `ActionGate.swift:152-168` fold).
- **Unreadable/missing arguments** render a refusal sentence **without de-escalating the
  radius** (the `MCPProvider.swift:202-207` discipline): the command still claims its
  destructive radius; the sentence says the call will be refused.
- **`invoke`** async, never throws, returns `ActionOutcome` from the execution engine
  (`succeeded` / `failed` with bounded reason keys / `notInvoked`); never constructs an
  `ActionConfirmation` (Family-B confinement is global).
- **The transport-permit widening** (`ActionTransportProhibitionTests.swift:200-202`): the
  permitted set grows from exactly one file to exactly two (`StdioMCPTransport.swift` +
  the provider's execution file), **with the D2 answer recorded in the widening**: a shell
  child is not observable, a restricted child purges the interposer env, so the zero-network
  guard cannot see a shell child's egress — the claim narrowed in writing is that the
  *default configuration* cannot create one. (The widening lands as a reviewed REFACTOR
  commit before the execution engine is written, so no aspect is ever red for lint.)
- **Family-A rows** (`ActionSeamBoundaryTests.swift:84-97`): the five per-family permitted
  rows the conformance forces, delivered in the same commit as the provider (S1).
- **Module discipline**: `VoccaActions` imports exactly `["VoccaCore"]` (the module-boundary
  rule 3 precedent).

## Out-of-scope boundaries

- No wiring/composition (the `wiring` aspect). No probe (the `probe` aspect). No
  command-definition editing UI.
- No voice reachability (founder decision — arm-surface only, later intent leg).

## Acceptance criteria

1. `ShellProvider.toolIDs` equals the registry's command ids.
2. `describe` renders the argv-derived sentence: command name + `key = value` parameter
   values (sorted, sanitised) + the optional clause. A planted argv appears verbatim; an
   authored clause cannot hide it.
3. An unknown command id describes as a refusal value, never a trap/throw.
4. A destructive command's `describe` returns `BlastRadius.destructive` when `readOnly` is
   absent; `.readOnly` only when declared `true`.
5. Unreadable/missing parameter values → the refusal sentence **keeping the destructive
   radius**.
6. `invoke` through a call-logged engine returns the engine's outcome; a refusal path is
   `notInvoked`/`failed` — never a throw; no `ActionConfirmation` construction anywhere in
   the provider (Family-B lint green).
7. The transport-permit widening carries exactly the D2 answer in its doc comment; the lint
   passes with the execution file permitted and no other file naming `Process`.

## Dependencies and sequencing

Third aspect — depends on `command-registry` (definitions) and `execution` (the engine).
The transport-permit widening REFACTOR lands **first**, before the execution engine's file
exists, so the suite is never red for lint. The Family-A rows land with the provider file.

## Open questions / risks

- The argv-derived sentence is new surface copy — the record aspect pins its exact shape;
  provisional copy is fine, the derived-from-argv property is what is pinned.
- `readOnly` claims are the author's claim (provider-claimed radius); local policy may only
  escalate. Recorded, not hidden.