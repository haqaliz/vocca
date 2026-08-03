---
name: vocca-next
description: Use when deciding what to build next in Vocca and you want the single highest-leverage capability picked from the repo's own roadmap and planning files (not invented), grounded in the scope guardrails and in what has already shipped or been deferred, ending with a ready-to-run handoff. Triggers on "vocca-next", "vn", "what's next", "next feature", "pick next".
arguments: ""
---

# Vocca Next (pick the most important capability)

## Overview

Read the repo's own roadmap and planning files, rank the real candidate capabilities
against the scope guardrails and against what has shipped or been deferred, and recommend
the single highest-leverage one to build next. End with a ready-to-paste
`vocca-begin-fast` invocation so the next session can start that worktree.

This skill RECOMMENDS and hands off. It does NOT create a worktree or start
`vocca-begin-fast` itself; the user runs the handoff prompt when ready.

## When to use

- "what should I build next", "pick the next capability", at the start of a session.
- After a merged capability or a phase gate, when choosing the next unit of work.
- Not for: executing a chosen capability (use `vocca-begin-fast`), or planning an
  already-chosen one (use `prd-interview` / `tech-plan`).

## The candidate set is the FILES, never invented

Read these (the source of truth, in this order). Vocca is **greenfield**, so the
planning docs carry almost all the signal today — but code, once it exists, wins
over prose:

- `docs/ROADMAP.md`: the **phases P0..P5** (P0 core dictation → P1 AI cleanup → P2 latency +
  injection → P3 voice loop → P4 context + actions → P5 reach) in build order, their 🚦 gates,
  the locked launch wedge, the launch demo, and any risks the roadmap lists. This is the
  primary candidate set. A candidate that retires a High-probability/High-impact risk is worth
  more than its slot suggests.
- `CLAUDE.md` and `VISION.md`: the wedge, the scope, and the guardrails the pick must obey.
- `docs/planning/*/`: in-flight, completed, and DEFERRED work, once any exists. Read the
  understanding/PRD notes: a capability deferred for a real blocker must not be
  re-recommended as if it were a quick win.
- `git log` / `git tag` / the test suite: what actually shipped. Trust this over prose;
  code runs ahead of the narrative docs. **Today there are no commits** — say so plainly
  rather than implying shipped state.
- A `CHANGELOG.md` if one ever exists (it does not today).

If a file above is missing, still reference it by path and say it isn't written yet.
Never substitute memory for a file you couldn't read.

## How to rank (grounded in CLAUDE.md)

1. **In scope only.** macOS-only, local-first, dictation-first, open-core. Never cloud in the
   OSS core, never anything that cripples the local core to set up the later hosted-model
   tier, never anything requiring credentials or data the founder lacks. Drop any candidate
   that violates a guardrail.
2. **Respect the phase order and its dependencies.** P0..P5 are sequenced (P0 core dictation →
   P1 AI cleanup → P2 latency + injection → P3 voice loop → P4 context + actions → P5 reach).
   The next capability is usually the lowest unshipped phase whose prerequisites are met.
   Recommending the P3 voice loop while the P0 dictation core is unbuilt is not ambition, it's
   a blocked pick.
3. **Dictation-first.** The daily-use dictation core (type anywhere, AI-cleaned) ships before
   the assistant/agent layer — that's what earns the stars. Favor work that makes the core
   dictation loop excellent before the conversational layer.
4. **Protect the two make-or-break UX battles.** Streaming-ASR **latency** and reliable
   system-wide **text injection** (P2) gate the whole experience. They are first-class
   engineering, not polish-later; weight them accordingly.
5. **Don't over-scope the assistant before dictation is excellent.** The voice loop and
   actions (P3/P4) come after the dictation core is solid. If the calendar is tight, the later
   phases slip, not the P0/P1 dictation core.
6. **Gets better as local models improve.** Favor integration, UX, and the action layer that
   improve for free as ASR/TTS/LLM get better, and keep ASR/TTS/LLM **pluggable behind
   interfaces** so a stronger local (or the future hosted) model slots in without a rewrite.
7. **Follow-on slices count.** A shipped capability's next slice (e.g. a second ASR backend
   once the interface is earned) is a valid candidate.
8. **Demand-pull beats push.** A surface a real user or design partner asked for outranks one
   the roadmap merely lists.

## Process

1. Read the files above. Build the candidate list: unshipped capabilities whose
   dependencies are met, follow-on slices of shipped ones, and any demand-pulled work.
   For thoroughness, you may dispatch one read-only agent to summarize the planning docs.
2. For each candidate, record: shipped-state (cite the file), dependency status,
   scope/guardrail fit, the risk it retires or exposes (name it where the roadmap lists one),
   and any known blocker.
3. Rank by the rules above. Pick ONE, plus one or two alternates.
4. Sanity-check the pick against the guardrails and against the current phase gate.
5. Produce the handoff (below).

## Output format

- **The pick**: one line naming the capability (with its phase, P0..P5) and a kebab-case slug.
- **Why**: 2 to 3 bullets tying it to the scope/guardrails, its dependencies, and what
  shipped — each citing a file.
- **Alternates**: one or two lines.
- **Known caveat**: the nearest feasibility risk (name it where the roadmap lists one),
  stated honestly, so the `vocca-begin-fast` dig is not surprised by it.
- **Handoff prompt** (ready to paste): a `vbf feat <slug>` line plus a 3 to 5 sentence
  inline brief that includes the caveat and the capability's acceptance tests (they are
  written first — the repo is test-first). Make clear the user runs this to start the
  worktree; this skill does not start it.

## Honesty rules

- Ground every shipped / pending / deferred claim in a named file. Do not assert from
  memory; the code and git history win over the docs.
- **Nothing has shipped yet.** Until commits exist, say the state is "not started" rather
  than implying progress. Hold Vocca's honest-scope line: don't claim latency or accuracy
  numbers you didn't measure, and don't imply a phase is done that isn't in git.
- If the strongest-looking candidate has a real blocker, say so and rank it accordingly
  rather than papering over it.
- Recommend only capabilities the files support. If the files are thin, say the pick is
  based on discussion, not an artifact.

## Common mistakes

| Mistake | Fix |
|---|---|
| Inventing a capability not in the docs | The candidate set is the phases P0..P5 in `docs/ROADMAP.md`; cite where each came from |
| Recommending a capability whose dependencies are unbuilt | Check the phase order; the pick must be unblocked |
| Re-recommending shipped work | Check `git log` and the test suite first, not the prose |
| Re-recommending blocker-deferred work | Read the `docs/planning` deferral note; name the blocker |
| Recommending cloud in the OSS core, or crippling the local core | Drop it against the `CLAUDE.md` guardrails |
| Reaching for the voice loop / actions early because it's the interesting one | Dictation-first: the P0/P1 dictation core ships before the P3/P4 assistant layer |
| Building past an uncleared phase gate | Respect the 🚦 gates in `docs/ROADMAP.md`; don't jump ahead of one that isn't cleared |
| Under-weighting latency / injection | They're the two make-or-break UX battles (P2); everything downstream depends on them |
| Starting the worktree from this skill | Only recommend and hand off; the user runs `vbf` |
| A vague pick with no slice | Prefer a candidate with a clear, testable first slice |
