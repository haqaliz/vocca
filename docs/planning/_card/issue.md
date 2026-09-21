# Card: feat/action-surface-wiring

> Inline brief — no GitHub issue. Source: the `vocca-next` recommendation (2026-09-21),
> itself grounded in the four C13 slice records (`action-safety-spine`, `local-data-provider`,
> `mcp-protocol`, `stdio-transport`).

## The unit

**C13 slice 5 of N: the action layer's user-visible surface and composition-root wiring** —
the slice every C13 record since slice 1 has ended by naming ("nothing is wired").

- Per-tool enablement gets its **persisted store** (deferred at
  `docs/planning/action-safety-spine/prd.md:295` — "the persisted store belongs with the slice
  that introduces real tools to enable"; that condition, real tools existing, is now met:
  `MCPProvider` + `InMemoryMCPTransport` + `StdioMCPTransport` are shipped).
- The **confirmation prompt** renders the provider's `describe` sentence as the only route to
  `invoke` in a shipped configuration.
- A **minimal server-configuration surface** ships with copy honoring the D2 answer
  (configuring a server is trust extended to its author, not a guarantee).
- The **additive wiring** re-anchors G5 with the dictation digests unchanged.

**Acceptances, written first per repo test-first doctrine:**
1. A destructive invocation without the user's confirmation is refused *by attempting the call*.
2. Enable → invoke → disable refuses the next invocation (no carry-over).
3. The default configuration still spawns no child process.
4. Dry-run produces zero provider side effects.
5. The first action-path SMOKE rows land (arm → confirm → invoke → audit row reconstructs).

**Caveat (record in the unit):** R8 is the risk being mitigated, not retired — the prompt is
the first human-in-the-loop safety surface, and the gate's N2 limit (an approval asserts a
human said yes, it cannot verify it) must be stated in the unit's record.