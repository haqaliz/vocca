# Aspect spec: agent-registry

> Source: `docs/planning/coding-agent-handoff/prd.md` R1 · Date 2026-09-30.

## Problem slice and user outcome

The persisted definition of what a coding agent row is: which binary runs, what it is told,
where it works, and how long it may run — with the shape-only, tolerant, caps-refuse
conventions the repo has pinned three times (`shell-commands.json`, `action-config.json`,
`intent-phrases.json`). User outcome: a hand-editable `coding-agents.json` whose every row
is either valid or loudly skipped, never silently mangled.

## In-scope requirements

- **File**: `coding-agents.json` under `~/Library/Application Support/Vocca/`, shape
  `{"version": 1, "agents": [CodingAgentDefinition]}` — definitions only, no enablement, no
  timestamps (enablement lives in `action-config.json`).
- **Row** (`CodingAgentDefinition`): `id`, `executablePath` (**absolute, no PATH** — MCP
  precedent), `arguments: [String]` (fixed argv), `projectDirectory` (absolute — the
  "active project", founder decision Q2), `timeoutSeconds: Int` (default 30, hard cap 600 —
  founder decision Q5), `clause: String?` (sanitised on render), and
  `environment: [String: String]?` (**PRD refinement from planning**: a real agent binary
  needs its key material (e.g. `ANTHROPIC_API_KEY`) in a scrubbed-env executor; explicit
  values in the user's own file, capped, the D2 trust-extension copy covers it). **No
  `readOnly` field** — an agent is never read-only; radius is `outwardFacing` for every
  row by construction.
- **Caps refuse, never clamp**: max 16 agents, 64 KB file, 128-char ids, 64 argv elements,
  16 env entries, 256-char env keys/values, 600 s timeout. A row over any cap is skipped
  loudly, never truncated.
- **Tolerant load / throwing save**: absent file → quietly empty; unreadable/wrong-shape/
  wrong-version/oversized → loudly empty, one log each, never writes; per-row skip with one
  loud log (the F1 no-coercion rule: `"executablePath": 1` refused, never coerced);
  duplicate ids first-wins; atomic tmp+rename with sorted keys; byte-level pin.
- **Timeout semantics**: absent `timeoutSeconds` → 30; < 1 → skipped loudly; > 600 →
  skipped loudly (refuse never clamp).

## Out-of-scope

- Enablement, argument values, timestamps, model/provider selection, `readOnly` claims.
- Anything but the file + the actor store (no UI, no provider).

## Acceptance criteria (test-first)

1. An absent file loads as empty, quietly.
2. A corrupt/oversized/wrong-version file loads as empty with exactly one loud log each;
   loading never writes.
3. A row with a non-string executable path (`"executablePath": 1`) is refused, never
   coerced (the F1 lesson).
4. A row with `timeoutSeconds` 0 or 601 is skipped loudly; absent defaults to 30.
5. A row with > 64 argv elements, > 16 env entries, or a > 128-char id is skipped loudly.
6. Duplicate ids: first wins, one loud log.
7. Save is atomic (tmp+rename) and byte-stable (sorted keys); save throws on failure.
8. The file's byte pin holds.

## Dependencies / sequencing

After `agent-execution` (the timeout is a `ShellExecutor.Configuration` value) — the store
is otherwise standalone. Before `agent-provider` (its row source).

## Open questions

- Env values are plain text in the user's own file — keychain-backed env is a later
  founder call (the file is already the trust-extension surface).