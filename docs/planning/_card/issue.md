# feat/agent-auth-baseline — inline brief

No GitHub issue filed; the source is the founder's request (2026-10-01): "i don't want to
use api key, can we support both api key and the subscription approach? not only for
claude any of the items that support."

## Brief

Agent rows authenticate two ways: an **API key in the row's environment** (today) or the
CLI's **own subscription login** (Claude subscription via `claude`'s OAuth login, ChatGPT
sign-in for Codex, Google account for Gemini, etc.) — credentials stored in the user's
home directory (`~/.claude/…`). The shipped executor **scrubs the environment** (the
child gets only the configured entries, never the caller's session — N2), so a
subscription-auth child has **no HOME** and cannot find its credentials. The gap: both
auth modes must work; the scrub must be refined, deliberately and narrowly.

Decisions (founder, 2026-10-01):
- **Executor-level baseline, every child** (the "most complete" option): the executor's
  Configuration gains a declared `baselineEnvironment` (default empty — byte-identical
  when not wired); the merge rule is baseline ∪ configured entries, configured wins.
- **Baseline = HOME only** — the one thing a CLI needs to find its own credential store;
  row entries win; nothing beyond the declared baseline ever reaches the child.
- **Auth hints**: the presets catalog gains per-preset auth copy (key + subscription
  spellings), rendered under the editor's Environment field, so the user knows
  subscription works for that CLI.

Scope: the executor's Configuration + both providers' configuration-building + the
composition root wiring HOME + the catalog copy + probes/pins + SMOKE 163 (the
subscription flow with a logged-in CLI and NO key on the founder's machine). The N2
record is refined in writing ("never the caller's environment" → "never beyond the
declared baseline + the row's entries"); zero network; the dictation path untouched;
the default still spawns nothing (the baseline is a value, not a spawn).

Out of scope: storing any credential in Vocca (the CLI owns its login), changing the
row's `environment` semantics, anything cloud.

## Labels (proposed)

feat, C13 follow-on, P4