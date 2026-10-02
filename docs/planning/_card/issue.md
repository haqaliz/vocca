# feat/spoken-task-seeding — inline brief

No GitHub issue filed; the source is the founder's workflow feedback (2026-10-01) and the
recorded N1 deferral of `coding-agent-handoff` + `agent-presets` ("phrases arm rows, never
task text"; the blocker: the phrase resolver produces no arguments and the agent's gap-1
pin refuses them).

## Brief

The founder's real workflow is "arm it and ask whatever I want" — the fixed-argv row
(one task per row) does not fit it. **N1 ships: the spoken utterance becomes the agent's
task.** A phrase row names an agent whose argv carries the `<task>` placeholder; in
conversation, the spoken utterance fills the slot; the confirmation card shows the
substituted argv verbatim; the run executes it; the audit records the sentence. One row,
any task.

Design (settled with the founder 2026-10-01 — the carrier precedent):
- `ActionInvocation` gains an additive `taskText: String?` (the `resolvedDirectory`
  precedent — default nil, 40+ construction sites compile unchanged; never `arguments` —
  the gap-1 pin stays).
- The provider substitutes the literal `<task>` in the row's argv with `taskText` —
  describe and invoke share one render, so the sentence and the executed argv cannot
  drift (the argv-derived doctrine).
- The utterance reaches the intent leg: `ConverseLoopDriver`'s intent step already has
  the utterance; the handler signature widens to carry it (the deliberate-widening
  precedent — fourteen params); the wiring fills `taskText` when the resolved agent
  row's argv carries the placeholder.
- The surface stays honest: arming a placeholder row from the ACTIONS TAB (no utterance
  exists) is refused loudly — the editor's `<task>`-Save refusal stays; the file may
  carry placeholder rows (hand-edited or a later editor affordance).
- Bounds: `taskText` over a bound is refused, never truncated (the 4096-arguments
  precedent). The sentence shows the substituted argv verbatim; the binding applies;
  the audit shows the sentence.
- Invariants: composed default still `agents=0 spawnsSubprocess=false`; zero network;
  dictation path digest-untouched; lints untouched.

Out of scope: surface-side task entry (a follow-on), `$N` parameters, interactive
sessions, anything cloud.

## Labels (proposed)

feat, C13 follow-on, P4