# PRD: Coding-Agent Handoff

> Source: `docs/planning/_card/issue.md` (inline brief, vocca-next handoff 2026-09-30) +
> `docs/planning/_card/understanding.md` (deep dig, 2026-09-30). Founder decisions
> Q1–Q6 recorded in the requirements below. C13 slice 9.

## Problem Statement

`ROADMAP.md:239` — "Coding-agent handoff | Voice → a coding agent session with the active
project as context" — is the **last unshipped key deliverable of P4** and the last named
piece of the wedge ("great dictation + a voice-agent loop that can also act"). Every other
P4 row has shipped machinery: context/consent (C12), MCP client + confirmation + dry-run +
audit (C13 slices 1–8). The capability's own record names coding-agent handoff first among
the remaining machinery (`docs/technical/CAPABILITY_ROADMAP.md:551-557`).

What happens if we don't build this: the wedge stops at MCP tools and shell commands — a
voice front-end that cannot hand real work to the tool the founder (and the target user)
does real work in. P4's table stays one row short and "voice that *does things*" remains a
half-truth. The blast radius is real — an agent runs commands, reads files, and may touch
the world — which is why this unit ships on the proven spine (gate, audit, card) rather
than beside it, exactly as the C13 PRD sequenced ("gated on safety rather than on
capability", `CAPABILITY_ROADMAP.md:384`).

## Goals & Success Metrics

- **G1 — A handoff runs.** A configured agent row, armed and confirmed, executes a
  non-interactive agent run (fixed argv) end to end, with the run's decision recorded in
  the audit log. Success: the `PROBE-CODING-AGENT` round trip inside the zero-network
  interposer asserts `agents=0 spawnsSubprocess=false` for the composed default **and** a
  counted, recorded round trip for a seeded configuration.
- **G2 — The default cannot spawn.** Nothing is configured out of the box; an absent
  registry is zero rows; the composed default declares `spawnsSubprocess=false` and the
  probe proves it. This is the D2-identical honesty posture, in writing on the surface.
- **G3 — No unintended action.** An agent invocation without approval is refused **by
  attempting the call**; the radius is `outwardFacing` under every shape, so the §8 floor
  always confirms (`EscapeValveTests`). Every decision — confirmed, refused, dry-run —
  appears in the audit log and reconstructs the action.
- **G4 — Context stays gated.** The optional selected-text seed flows only through the
  existing `ContextGrantGate` (≤ 4 KB, AND-gated, never-in-payload pins hold). Without the
  grant, the seed is absent — never read-then-discarded.
- **G5 — No drift between sentence and argv.** Describe and invoke share one render; a
  planted argv appears verbatim in the sentence (shell precedent, `ShellProviderSentences`).
- **G6 — Bounded execution.** A run is bounded by a per-row timeout (default 30 s, hard
  cap 10 min, caps refuse never clamp), the reaping is terminate→poll→SIGKILL→poll, and
  the no-orphan acceptance asserts `ESRCH` on a real child.

Measurement: all probe assertions are CI-gated. Real-world rows (a real agent binary on the
founder's machine) are SMOKE rows ~157+, **recorded, never gated**; no "agent success rate"
may be quoted until a real run exists.

## User Personas & Scenarios

- **The founder (primary).** Working in a repo, holding the converse chord: "ask the agent
  to summarize the open PRs" → a confirmed one-shot agent run seeded with the configured
  project directory; the reply comes back through the voice loop. The agent is
  user-configured (BYOK-shaped, like MCP servers).
- **The power user.** Arms an agent row from the Actions tab (default off), previews the
  sentence, enables it, and can voice-arm it with a phrase row in `intent-phrases.json`.
- **The skeptical user.** Configures nothing; the Actions tab shows an empty agent section
  with the D2 copy; the default configuration provably spawns nothing.

## Requirements

### Must-have

- **R1 — Registry** (`coding-agents.json`, `ShellCommandRegistry` shape conventions:
  definitions only, tolerant load / throwing save, caps refuse never clamp, strict shape
  refusing unknown keys, atomic tmp+rename, byte pins). Row: `id`,
  `executablePath` (**absolute, no PATH** — MCP precedent), `arguments` (fixed argv),
  `projectDirectory` (absolute — **the "active project"**, founder decision Q2),
  `timeoutSeconds` (default 30, hard cap 600 — founder decision Q5), `clause` (optional,
  sanitised). **No readOnly field** — an agent is never read-only; the radius is
  `outwardFacing` for every row (founder decision Q4; the §8 floor pins it).
- **R2 — Provider** (`CodingAgentProvider`, `ActionProvider` conformance, `ShellProvider`
  template): `static let providerID` (reverse-DNS, e.g. `dev.vocca.agent`), toolIDs fixed
  at construction, describe/invoke share one argv-derived sentence (fixed argv verbatim +
  project directory + clause), unknown row → refusal at `.readOnly`, unreadable row →
  `.failed` with a bounded reason key, injected engine closure (tests record without
  spawning), never constructs a confirmation.
- **R3 — Execution** (reuse `ShellExecutor` or a thin agent variant): fixed argv, never a
  shell; per-row timeout over the injected clock with the counted wait; reaping
  terminate→poll→SIGKILL→poll; no-orphan asserted `ESRCH`; bounded capture; scrubbed
  environment; stdin `/dev/null`. This is the **third** `Process`-naming file — the
  transport-permit lint grows a reviewed entry with its own D2 answer.
- **R4 — Wiring** (`composeCodingAgentWiring`, `ShellWiring` shape): policy floor `.none`
  recorded, session-in-flight refusal, re-render-after-record card, `approvedSentence`
  binding on confirm, mismatch re-prompt, every decision recorded, `spawnsSubprocess`
  declared **for the configuration** (false: an absent registry is zero rows). Root slots +
  a **card-routing branch** by providerID in `AppBootstrap.swift` — the G5 re-anchor is
  deliberate, computed, never edit-to-match; the dictation digests unchanged.
- **R5 — Arm leg** (Actions-tab agent section, own-built rows — the "arm surface is not
  generic" precedent): enablement from the shared `ActionConfigStore`, default off, absent
  is off; the D2 copy on the surface ("an enabled agent's egress is never provable from
  inside Vocca"); preview/arm/confirm/decline through the same card.
- **R6 — Voice reach** (founder decision Q4): **voice-reachable** — `IntentPhraseStore`
  refuses only `dev.vocca.shell`, so a phrase row naming the agent provider resolves once
  the tool is enabled; the catalog (enablement) carries it automatically; the intent step
  is untouched (fixed argv, founder decision Q3 — phrases arm rows, they do not carry
  task text).
- **R7 — Probe** (`PROBE-CODING-AGENT`): composed default facts (`agents=0
  spawnsSubprocess=false`) + a seeded round trip (stub engine via injected closure) with
  counted effects (`card=yes invoked=1 decisions=… ordinals=… binding=matched`), the
  expected-lifecycle constant, and the guard-the-guard property test in
  `ZeroNetworkTests`. Module-coverage witness.
- **R8 — Lints**: Family A grows five rows (one reviewed widening); the transport-permit
  permitted set grows to **exactly three** files with the pin test updated; the
  `policy:` no-default call sites stay explicit.
- **R9 — SMOKE rows (~157+)**: real-binary handoff (arm → card → confirm → agent runs →
  audit reconstructs), the voice phrase row, the D2 copy, the timeout path — recorded,
  never gated; "no rate may be quoted."

### Should-have

- **S1 — Consented selection seed.** A per-row opt-in to seed the run with the current
  selection via `ContextGrantGate` (≤ 4 KB, AND-gated, never in the BYOK payload without
  the separate grant). G4's acceptance is written against this.
- **S2 — Dry-run preview** of the agent sentence (the existing `preview` path).

### Nice-to-have

- **N1 — `{{utterance}}` seeding** (keyword-resolver args row; code-level seeds; a later
  founder call — the fixed-argv decision is the record this slice).
- **N2 — Parameter slots (`$N`)** in agent argv (shell-command precedent); deferred — the
  phrase resolver carries no arguments anyway.

## Technical Considerations

- **Phase:** P4 (C13 slice 9). Prerequisites all shipped: C10/C11 (converse loop/driver),
  C12 (context), C13 slices 1–8 (spine, protocol, transport, surface, intent, shell,
  phrase). The repo's recorded posture: units ship ahead of the uncleared gates, recorded
  honestly.
- **Seam:** `ActionProvider` — this is a **fifth implementation** (Null, Audit, MCP,
  Shell), so no new seam and no guardrail-7 question.
- **Blast radius:** `outwardFacing` for every row, by construction — the provider's own
  claim is never de-escalatable and local policy may only escalate. The §8 floor
  (`BlastRadius.requiresConfirmation`) always confirms under every approval/policy/mode
  shape.
- **D2 honesty language (must land in the record and the surface copy):** a restricted
  child ignores/purges `DYLD_INSERT_LIBRARIES`, so the interposer is blind to the agent's
  whole descendant tree; an *enabled* agent's egress is never provable from inside Vocca.
  What is provable: the default configuration cannot create an agent child.
- **Privacy:** the project directory is a config-row fact, never read from another
  process (founder decision Q2 — no new trust surface, no new consent gate). The selection
  seed flows only through the existing grant.
- **Latency/injection:** untouched — the dictation path is digest-pinned (G5); this unit
  touches the converse/action layers only.
- **Local-first:** Vocca makes no network call; the agent binary is user-configured
  (BYOK-shaped). A hosted agent endpoint would be a later addition to the seam, never a
  replacement.
- **Module layout:** everything in `VoccaActions` (depends exactly on `VoccaCore`),
  plus the additive composition in `VoccaBootstrap`.

## Risks & Open Questions

- **R-A — An enabled agent egresses and the interposer is blind** (D2, the roadmap's R8
  family). Mitigation: outwardFacing always-confirms, audit-every-decision, the default
  cannot spawn, and the honest copy. Never provable, never claimed provable. This is the
  same limit the shell slice recorded; the agent's radius is simply the roadmap's largest.
- **R-B — A real agent run outlives the ceiling.** Mitigation: per-row timeout, hard cap,
  loud failure as a returned value, no orphan. An agent that needs minutes must be
  configured for it (founder decision Q5).
- **R-C — The "session" word.** The roadmap says session; this unit ships one-shot runs.
  Interactive sessions are deferred with the blocker named (persistent-child/PTY
  machinery is unbuilt and does not fit the one-shot tool-call shape) — the record must
  say this plainly rather than imply a session shipped.
- **R-D — Selection seed misleads.** A stale selection could seed the wrong project
  context. Mitigation: the seed is gated, bounded, and visible in the sentence
  ("with the selection: …"); the config row's project directory is the primary carrier.
- **Open:** which agent binary does the founder actually arm first (the SMOKE rows need
  one — likely the `claude` CLI); whether `clause` is needed this slice; whether the seed
  is per-row or global (per-row recommended, M7-shaped).

## Out of Scope

- **Interactive agent sessions** (PTY, persistent child, turn routing) — deferred with
  the blocker named (R-C).
- **A shipped default agent engine** — none; user-configured absolute paths only
  (founder decision Q6).
- **`{{utterance}}` task seeding and `$N` parameter slots** (N1/N2).
- **Reply-text rendering** and the **phrase-then-keyword composite resolver** — other
  remaining C13 items, separate units.
- **Anything cloud in the OSS core** — a hosted agent endpoint is a later addition to the
  seam, never built now.
- **Any change to the dictation path** — digest-pinned; the intent seam's signatures are
  untouched this slice (fixed argv needs no resolver change).