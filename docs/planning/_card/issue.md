# Brief (no GitHub issue; inline brief, 2026-10-08)

Source: the recorded follow-up of `converse-intent-wiring` (PR #58; docs/STATUS.md "Known limitations",
CAPABILITY_ROADMAP slice amendment) and the Task 3 / final-review findings.

**The gap (verified in the final review):** in the shipped app the intent wiring is composed over
`AuditActionProvider` only (`AppBootstrap.swift` ~749-755: `composeIntentWiring(... provider: actionProvider ...)`),
while the card CONFIRM/DECLINE closures already route by `providerID` (`AppBootstrap.swift` ~852-876: shell /
agent / otherwise `actionWiring`). Consequences:
1. **A phrase naming an enabled coding agent (`vocca.agent`) fails closed but uselessly:** `AuditActionProvider.describe`
   answers "does not serve the tool … Nothing will happen." and claims `.readOnly`, so the call auto-runs and FAILS —
   spoken "Something went wrong." + an audited `autoRanReadOnly` failed entry. No card, nothing spawns. The slice-11
   claim "voice → coding agent" is therefore untrue in the shipped build (tests compose the wiring over
   `CodingAgentProvider`, a composition `configure` does not have).
2. **`AuditActionProvider` selects its tool by `toolID` alone and ignores `providerID`**
   (`AuditActionProvider.swift:121-139`, `:165-179`): an enabled agent/MCP row whose tool id is `audit.clear`/`audit.count`
   gets the audit tool's behavior (a foreign `audit.count` row can speak "Done."). Not a bypass (click-gated; the card
   shows the true sentence) but wrong.
3. Unserved providers are described as `.readOnly`, so a stray enabled row for any unserved provider auto-runs and fails
   instead of being refused/confirmed.

**Goal:** route the intent leg's describe/invoke by `providerID` to the provider that serves it, so (a) a phrase naming
an enabled coding agent reaches `CodingAgentProvider`: describe → the argv-derived sentence → the outward-facing CARD →
click Confirm → the reviewed `ShellExecutor` child (never before the click); (b) every intent dispatch checks `providerID`
against the provider that serves it (the named acceptance test), (c) an unserved provider is refused loudly, never
auto-run as read-only.

**Why it needs care:** the first slice where a spoken phrase can lead to a CHILD PROCESS in a shipped build. Trust
invariants: the card always precedes the spawn (outward-facing → confirm), approval `.withheld` on the voice leg, every
decision audited, the sentence binding intact, shell still never voice-reachable (phrase store refuses at load; keyword
leg excludes shell + agents), default (no file / no enabled tool) byte-identical echo, zero network / no child by default
(`agents=0 spawnsSubprocess=false` for the composed default), dictation untouched. G5 re-anchors (AppBootstrap.swift edit).
The shipped-default posture "the default configuration spawns no child process" must stay TRUE: spawning is reachable only
after a hand-authored phrase + an enabled agent row + a click.

Known context to verify in the dig: `composeIntentWiring`'s generic parameter (`IntentWiring<AuditActionProvider>`),
`root.intentWiring` typing, `composeCodingAgentWiring` / `composeShellWiring` (their executors, cards, `spawnsSubprocess`),
how `actionConfirm`/`actionDecline` route (~852-876) and whether the intent leg can reuse that routing, the placeholder
`<task>` flow (`ActionInvocation.taskText`, the pre-card refusal, `WidgetConfirmationSignal.taskText/resolvedDirectory`),
the tests that compose over `CodingAgentProvider` (AgentWiringCwdTests:311, UtteranceThreadingTests:486), PROBE-INTENT-*,
PROBE-CODING-AGENT, SMOKE 158/162 (known-failing until this ships).
