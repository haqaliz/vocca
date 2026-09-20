# Card: feat/stdio-transport

> Inline brief — no GitHub issue. Source: the founder's "continue until done" on 2026-09-21,
> and the `mcp-protocol` unit record (Q3, deviation **D2**).

## The unit

Ship `StdioMCPTransport` — the second `MCPTransport` implementation, closing **guardrail 7**
for that seam — and, in doing so, answer **D2**.

## ⚠️ This unit must answer D2 before it may exist

The transport prohibition lint forbids `Process` (and `URLSession`, `NW*`, `Network`,
`posix_spawn`, `NSTask`, `system`) inside `VoccaActions`, with an **empty** permitted set. Its
doc comment states the price of an entry:

> *"An entry added here is the reviewed edit this lint exists to force. Whoever adds one owes
> the review an answer to D2: how the spawned transport stays observable when
> `DYLD_INSERT_LIBRARIES` does not survive the hop."*

**The honest answer is that it does not stay observable.** Measured in the C13 slice-1 dig:
a restricted child ignores `DYLD_INSERT_LIBRARIES` *and purges `DYLD_*` from the environment it
passes on*, so `/usr/bin/env node server.js`, any shell wrapper, and any Apple platform binary
are **blind** to the interposer. One hop launders the insertion for the whole descendant tree.
No mitigation makes an arbitrary child observable.

So the answer cannot be "we observe it". It has to be a different claim.

## The answer — the BYOK precedent, applied (implementer's call)

Vocca already has a component that egresses and yet leaves the invariant honest:
`BYOKCleanupProvider`. It is not an *exception* to the zero-network test — it is **unreachable**
in the default configuration. It is constructed at exactly one site behind a `case .byok:`
requiring a persisted config block and a dialable endpoint that do not exist by default, so
`PROBE-*` never reaches it; it declares `requiresNetwork = true` rather than inheriting the
offline default; and that flag folds once at launch into a **structurally non-dismissable**
egress badge.

`StdioMCPTransport` takes the same shape:

1. **Unreachable by default.** No server is configured out of the box, so the default
   configuration **spawns nothing**. The probe never reaches a spawn, and the zero-network
   assertion stays true *and verifiable* — because there is no child to be blind to.
2. **Declares what it is.** The transport declares `spawnsSubprocess = true`, the analogue of
   `requiresNetwork`, so the fact is a value the composition root can fold rather than a comment
   someone has to remember.
3. **Badged at the point of use.** A configured stdio server is visible, on the same footing as
   the egress badge. *(The badge's surface is a later wiring slice — this unit ships the
   declaration and the fold-ready value, not the pixels.)*
4. **The claim is narrowed, in writing, everywhere it appears.** Today: *"the default
   configuration makes zero network calls."* After this unit it must also say: **and spawns no
   child process** — and, where a child *is* configured, that **Vocca cannot observe what that
   child does on the network.** That sentence is the deliverable. A user enabling an MCP server
   is extending trust to that server's author, and the docs must say so plainly rather than
   implying our interposer still covers them.

## The lint entry, and what it costs

`StdioMCPTransport.swift` becomes the **single** permitted file naming `Process`. The permitted
set goes from empty to exactly one, with the D2 answer above written into the entry's comment.

**If more than one file needs to name `Process`, stop** — the spawn must be confined to one file
or the confinement is meaningless.

## Acceptance (test-first)

1. `StdioMCPTransport` conforms to `MCPTransport` — the second implementation; **guardrail 7 met
   for that seam**.
2. **The default configuration spawns nothing** — asserted, not assumed. No server configured ⇒
   no process created.
3. Framing over a pipe: a JSON-RPC frame written and read back across a real child process.
4. **A child that dies mid-exchange yields a typed failure**, never a hang and never a trap.
5. **A child that never responds hits a bounded timeout** — an unresponsive server must not wedge
   the caller forever.
6. **A child that floods output is bounded** — no unbounded read from a hostile peer.
7. The process is terminated on teardown; **no orphan survives the transport.**
8. `spawnsSubprocess == true` on stdio, `false` on the in-memory transport.

## Out of scope

The wiring slice (composition root, the badge's pixels, server configuration UI). The intent
layer. `ShellProvider`. Any change to the gate or the seam.

## Honest posture

- **This is the seventh-plus unit ahead of the uncleared gates; no gate passes.**
- **Guardrail 7 becomes met for `MCPTransport`** — two real implementations.
- **D2 is answered, not solved.** The blindness is real and permanent; what changes is that the
  default configuration cannot create a blind child, and the documentation stops implying
  coverage it does not have.
