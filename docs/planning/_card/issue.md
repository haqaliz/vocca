# Card: feat/mcp-protocol

> Inline brief — no GitHub issue (`gh issue list` is empty). Source: the founder's "go ahead"
> on 2026-09-19 delegating the **Q3 transport decision**, plus the `action-safety-spine` and
> `local-data-provider` unit records.

## Q3, decided — **no transport in this slice** (implementer's call, delegated)

The options were *stdio-only with the D2 blindness recorded* versus *no transport at all*.
**No transport**, and the reasoning changed once slice 2 shipped:

"No transport" no longer means "nothing useful". The substance of MCP is not the pipe — it is
JSON-RPC framing, `initialize` negotiation, `tools/list` discovery, schema → invocation mapping,
and whether a server's self-declared annotations may be trusted. **All of it is buildable and
fully testable behind an `MCPTransport` seam with an in-memory implementation**, which makes
zero syscalls and therefore runs honestly inside the zero-network interposer.

That leaves the stdio transport as its own small slice where **D2 is the entire conversation**
rather than a footnote beneath a half-built protocol layer — and it sets `MCPTransport` up to
satisfy guardrail 7 properly when the second (stdio) implementation lands.

Same shape as slice 1: machinery before the risky part.

## ⚠️ The central risk — the vocabulary may not survive contact, again

`ActionInvocation` is **deliberately just two identifiers** (`providerID`, `toolID`). Its own doc
comment says so:

> *"Arguments, a payload and a schema all belong to the intent layer that is explicitly out of
> this unit's scope."*

**MCP's `tools/call` takes a name *and* an `arguments` object.** So an MCP tool call cannot be
expressed by the current vocabulary.

This is the same class of discovery as slice 2's async finding, and it must be **surfaced, not
pre-decided**. The candidate resolutions, none chosen here:

1. **Extend `ActionInvocation` with arguments.** Honest, but it changes the seam a third time and
   pushes content into a type the audit log and the gate both read — which interacts with the
   PRD §5 decision that raw arguments are *not* persisted.
2. **Keep arguments inside the MCP provider**, keyed to a pending invocation. The gate never sees
   them; `describe` renders them into the concrete sentence (the provider holds them, so it can).
   Cost: the provider becomes stateful, with a keying and lifetime problem that smells racy.
3. **A distinct argument-carrying type** that the intent layer owns and the provider consumes,
   leaving `ActionInvocation` untouched.

**Whichever is chosen must not quietly undo two shipped properties:** raw arguments are not
persisted (PRD §5), and the confirmation sentence must stay concrete (C13).

## What ships

- **`MCPTransport` seam** — send/receive JSON-RPC frames. No process, no socket.
- **`InMemoryMCPTransport`** — a real, scriptable implementation for tests and the probe.
- **The protocol layer** — JSON-RPC 2.0 framing, `initialize`, `tools/list`, `tools/call`,
  error mapping.
- **`MCPProvider`** conforming to `ActionProvider` (now `async`, which is why slice 2 had to
  happen first).

## The `readOnlyHint` question — slice 1 already answered it

MCP servers declare their own tool annotations (`readOnlyHint` and friends). `action-safety-spine`
recorded, before MCP existed, that **the blast radius is the provider's own claim and nothing
verifies it**, so local policy may only ever *escalate*, never de-escalate.

MCP makes that concrete: a server's `readOnlyHint` is **untrusted input to a safety decision**.
It may raise our floor, never lower it. The rule was written in anticipation of exactly this;
this slice is where it earns its keep — and where it must be exercised against a *lying* server
in tests, not merely a well-behaved one.

## Out of scope

**Any transport that touches the OS** — no stdio, no subprocess, no socket (that is the next
slice, where D2 is confronted directly). The intent layer. Any user-visible surface.
`AppBootstrap` wiring, so the G5 pin stays untouched. `ShellProvider`.

## Constraints carried in

- `VoccaActions` declares exactly `["VoccaCore"]` — asserted by equality. Foundation **is**
  available here (unlike `VoccaCore`), which is how the audit store uses `Data`/`URL`.
- **The transport prohibition lint forbids `URLSession`, `NW*`, `Network`, `Process`,
  `posix_spawn`, `NSTask`, `system` inside `VoccaActions`.** An in-memory transport names none of
  them; if this slice trips that lint, that is a **genuine finding**, not a reason to widen it.
- The action-family lint costs **five permitted rows per real provider** — expected, recorded.
- No gate passes. This will be the seventh unit built ahead of the uncleared gates.
