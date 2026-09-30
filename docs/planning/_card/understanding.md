# feat/coding-agent-handoff — understanding note

Source: `docs/planning/_card/issue.md` (inline brief, vocca-next handoff 2026-09-30).
Codebase maps: three parallel exploration passes over the worktree (ActionProvider
machinery, intent+converse+probe machinery, context+surface machinery).

## What this work is really asking

`ROADMAP.md:239`: "Coding-agent handoff | Voice → a coding agent session with the active
project as context" — the **last unshipped key deliverable of P4** (every other P4 row has
shipped machinery: context/consent, MCP client, confirmation, dry-run, audit). C13's own
record names it first among the remaining machinery
(`docs/technical/CAPABILITY_ROADMAP.md:551-557`). The wedge's final piece: the voice leg
reaching a coding agent that does real work in the active project.

## What exists to build on (verified in code, not prose)

- The `ActionProvider` seam is proven by four providers (`Null`, `Audit`, `MCP`, `Shell`);
  `ShellProvider` (`Sources/VoccaActions/Providers/ShellProvider.swift`) is the direct
  template: actor, `static let providerID`, injected engine closure (tests record without
  spawning), describe/invoke share one argv-derived sentence, refusal at `.readOnly` for
  unknown tools, never mints a confirmation.
- The safety spine is complete: `ActionGate` (enablement first, policy floor `.none`
  recorded, sentence binding, escalate-only radius), `ActionExecutor` (one caller of the
  gate; every decision recorded; `auditRecorded == false` never a success ack), the
  append-only audit store, the widget card (generation-tokened, re-render-after-record,
  no "don't ask again").
- The voice leg exists: `PhraseIntentResolver` is the composed default (per-turn provider,
  catalog from enablement), `.toolCall` → shared executor → card → confirm, acks derived
  from the decision. `IntentPhraseStore` refuses only `dev.vocca.shell` rows at load — any
  other providerID (including a new coding-agent one) is voice-reachable once enabled.
- The invariant machinery: zero-network interposer, `spawnsSubprocess` declared values at
  wiring level, transport-permit lint (permitted set exactly two files), G5 pin
  (`AppBootstrap.swift` digest, re-anchored deliberately, dictation digests unchanged),
  probe drive + guard-the-guard pattern in `ZeroNetworkTests.swift`.

## The three real design problems (these are the PRD's core)

**P1 — "Active project" does not exist in the context vocabulary.** `ContextSnapshot` is
exactly `(bundleID, windowTitle, selectedText)` (`Sources/VoccaCore/Context/ContextSnapshot.swift`);
nothing captures a working directory, document path, or project identity, and the window
title is explicitly never scored. Options: (a) a new context read (AX `kAXDocumentAttribute`
is unreliable; a process-cwd read via `proc_pidinfo` is a *new trust surface* with no consent
gate today), (b) an explicit project directory carried in the agent's config row (honest,
deterministic, no new privacy surface — the "active project" becomes "the configured
project"), (c) optional seeding with consented selected text through the existing
`ContextGrantGate` (≤4 KB, never-in-payload pins hold). **Recommend (b) + optional (c).**

**P2 — "Session" vs one-shot.** The one-shot `describe`/`invoke` shape and `ShellExecutor`
(30 s ceiling, stdin = /dev/null, bounded capture, no orphan) fit a **non-interactive agent
run** (e.g. `claude -p "…"`), not an interactive PTY session. An interactive session is new
machinery (persistent child, turn routing, session state) — a separate, larger unit. The
honest slice: **one-shot handoff ships; interactive session is deferred with the blocker
named** (the one-shot tool-call shape cannot host it; PTY/long-lived child ownership is
unbuilt machinery). Note the 30 s ceiling is a `ShellExecutor.Configuration` value — a
longer ceiling for agent runs is a reviewed config choice, and the no-orphan acceptance
transfers.

**P3 — How the task text reaches the provider.** The intent layer resolves to
`ActionInvocation`; `PhraseIntentResolver` produces **no arguments** (rows are three
strings), so a phrase hit carries no task text. Options: (a) agent rows carry a **fixed
argv** (shell-command precedent — the sentence shows the argv verbatim; a phrase arms the
row, the task is the configured argv), (b) a keyword-resolver seeded args row with
`{{utterance}}` (code-level seed, the MCP `post_message` precedent), (c) a resolver
signature change (a recorded, bigger step). Recommend (a) for the slice, (b) as a
follow-on.

## Affected areas (the checklist a new provider forces)

1. `VoccaActions/Providers/CodingAgentProvider.swift` — conformance, fixed-argv sentence,
   injected engine closure.
2. A config store (`coding-agents.json`, ShellCommandRegistry shape: definitions only,
   tolerant load / throwing save, caps refuse never clamp, absolute executable path).
3. An engine (ShellExecutor reuse or a thin agent variant; the third `Process`-naming file).
4. Family A lint: five rows in `ActionSeamBoundaryTests` (one reviewed widening).
5. Transport-permit lint: **third permitted entry** + D2 answer in writing (the child is
   the same blind hop; the default configuration cannot create an agent child).
6. `AppBootstrap` composition: wiring recipe, root slots, **card-routing branch** by
   providerID, `spawnsSubprocess` declared false for the composed default; **G5 re-anchor**
   (deliberate, computed, dictation digests unchanged).
7. Probe: `PROBE-CODING-AGENT` drive + witness + expected-lifecycle constant +
   guard-the-guard pair in `ZeroNetworkTests`; `agents=0 spawnsSubprocess=false`.
8. Arm leg: own-built Actions-tab section (the "arm surface is not generic" precedent —
   shell section's rows).
9. Voice reachability decision: the shell refusal is providerID-specific; an agent row is
   **not** refused today → voice-reachable by default once enabled + phrased. Blast radius
   must be `outwardFacing` (an agent runs commands / may touch the world) → the §8 floor
   always confirms, under every approval/policy/mode shape (`EscapeValveTests`).
10. SMOKE rows (~157+): recorded, never gated; "no rate may be quoted" until a real run.

## Guardrail check

In scope: macOS-only, local-first (agent binary is user-configured, like MCP servers —
BYOK-shaped, never Vocca's own endpoint), no cloud in the OSS core (Vocca makes no network
call; an agent's own egress is the D2-identical honest limit: *an enabled agent's egress is
never provable from inside Vocca* — copy on the surface), dictation path untouched
(digest-pinned), transcript invariant untouched (the failsafe/card terminate every path).
The default configuration must still spawn nothing (nothing configured → zero rows →
`spawnsSubprocess=false`).

## Open questions for the founder (Phase 3)

- Q1 (P2): one-shot handoff this slice, interactive session deferred? (recommend yes)
- Q2 (P1): "active project" = configured project root in the config row (+ optionally
  consented selected text)? (recommend yes)
- Q3 (P3): task text = fixed argv in the config row, phrases arm rows? (recommend yes;
  `{{utterance}}` seeding is the follow-on)
- Q4: voice-reachable or arm-surface-only? (roadmap says "Voice → …" — recommend
  voice-reachable, always-confirming)
- Q5: agent timeout ceiling — reuse 30 s or a longer reviewed ceiling for agent runs?
- Q6: agent binary/binary-set — user-configured absolute paths (MCP precedent), default
  none; any shipped default engine? (recommend none)