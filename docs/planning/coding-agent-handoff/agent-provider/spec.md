# Aspect spec: agent-provider

> Source: `docs/planning/coding-agent-handoff/prd.md` R2 (+ gap-1 pin from the PRD
> critique) · Date 2026-09-30.

## Problem slice and user outcome

`CodingAgentProvider`, the `ActionProvider` conformance that makes a registry row a
voice-reachable, gate-governed, auditable one-shot agent run — the `ShellProvider` shape
exactly: actor, injected engine closure (tests record without spawning), describe/invoke
sharing one argv-derived sentence, refusal never a trap, confirmation never minted.

User outcome: a confirmed handoff executes the row's fixed argv in the row's project
directory with the row's env and timeout; the sentence on the card shows verbatim what will
run; a planted argv cannot hide behind prose.

## In-scope requirements

- **Conformance** (`Sources/VoccaActions/Providers/CodingAgentProvider.swift`): `public
  actor`, `public static let providerID = "dev.vocca.agent"`, `toolIDs` nonisolated let
  fixed at construction from the registry (`load()` once — "a row edited after load is a
  new provider, never a silent re-list", the shell precedent), injected run closure
  `@Sendable (ShellExecutor.Configuration) async -> ShellExecutionResult`.
- **`describe`**: unknown row → refusal at `.readOnly`; invocation carrying `arguments`
  (non-nil) → refusal at `outwardFacing` (**the gap-1 pin**: an agent row declares no
  parameters, so any supplied arguments are refused — the shell undeclared-key rule);
  resolved → the shared sentence at **`outwardFacing`** (no `readOnly` field exists; the
  radius is outwardFacing for every row by construction).
- **`invoke`**: re-resolves the row on the invocation's own arguments (same object the
  gate described — argv that runs == argv the sentence showed); unknown → `.failed(
  "agent.unknownTool")`; unreadable → `.failed("agent.unexpectedArguments")`; resolved →
  `ShellExecutor.Configuration(executablePath:arguments:environment:timeout:)` with the
  row's values and runs. Never constructs a confirmation (Family B).
- **Sentence** (`CodingAgentSentences`): "Run the coding agent '<id>': <executable>
  <argv…> in <projectDirectory>" + sanitised clause last (control chars → space, the
  `MCPProvider` rule); describe and invoke share one render; refusal/unknown sentences
  constant.
- **Reason keys**: bounded, vocabulary-pinned (`agent.unknownTool`,
  `agent.unexpectedArguments`).
- **Lints**: Family A grows **five rows** naming the provider file (one reviewed widening
  in `ActionSeamBoundaryTests` — the "five rows per real provider" finding); the file
  must actually spell the five identifiers.

## Out-of-scope

- The registry store (own aspect), the engine (own aspect), wiring/surface (own aspect),
  the probe (own aspect).
- Parameters (`$N` slots) and `{{utterance}}` seeding (N1/N2 of the PRD).
- Any environment beyond the row's map (no host-env passthrough — the executor scrubs).

## Acceptance criteria (test-first)

1. A stub engine (counting closure) records describe/invoke without spawning.
2. A destructive agent invocation without approval is refused **by attempting the call**
   (the gate-level acceptance, `EscapeValveTests` extension: outwardFacing always
   confirms under every approval/policy/mode shape).
3. The sentence shows the fixed argv verbatim + the project directory; a planted argv
   appears verbatim; describe and invoke share one render.
4. An invocation with unexpected arguments is refused (describe) and `.failed(
   "agent.unexpectedArguments")` on invoke — the sentence and the outcome never drift.
5. Unknown row → refusal at `.readOnly`; invoke `.failed("agent.unknownTool")`.
6. The run closure receives the row's timeout and environment.
7. `toolIDs` is fixed at construction; a registry edited after load is a new provider.
8. Family A has exactly five new rows; Family B untouched; no transport-family spelling
   in the file.

## Dependencies / sequencing

After `agent-registry` (row source) and `agent-execution` (configuration shape). Before
`agent-wiring` (composition) and `agent-probe`.

## Open questions

- None — the gap-1 pin and the env/timeout flow are recorded decisions.