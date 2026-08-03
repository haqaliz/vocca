---
name: vocca-end
description: Use when finishing local work on a Vocca unit of work after the PR is merged and you also need a completion report on Desktop. Triggers on "vocca-end", "ve", "ve bug 12", "ve feat dictation-core", "end full".
arguments: "type id"
---

# Vocca End (Full Track)

## Overview

Same cleanup as `vocca-end-fast`, **plus** a completion report at the end via `vocca-report`.

**Invocation:** `ve <type> <id>` — e.g. `ve bug 12`, `ve feat dictation-core`.
Arguments and conventions are identical to `vocca-end-fast`.

## Pipeline

**REQUIRED SUB-SKILL:** Use `vocca-end-fast` for the cleanup pipeline.

Run its **Phase 0 → Phase 2 exactly as written** (safety check → master + pull → remove worktree → delete branch). Vocca's base branch is **`master`**, never `main`. **There is no version-release step:** Vocca is greenfield with no release machinery (no `RELEASING.md`, no `release.yml`), so finishing a unit of work does not tag or publish anything. Only proceed to the report once cleanup verification passes.

> **Note:** When Vocca later gains a macOS release pipeline (likely a signed/notarized app via GitHub Releases, possibly a Homebrew cask — **not** PyPI), update these skills to add a release phase.

### Phase 4 — Completion report

**REQUIRED SUB-SKILL:** Use `vocca-report` with the unit-of-work id and the corresponding type.

The two skills use slightly different type vocabularies — map before invoking:

| `ve` arg | `vocca-report` arg |
|---|---|
| `bug` | `bug` |
| `task` | `task` |
| `chore` | `task` |
| `feat` | `feature` |
| `feature` | `feature` |

Example: `ve bug 12` → invoke `vocca-report` with `bug` + `12` → writes `/Users/aliz/Desktop/bug-12-completion.md`.

`vocca-report` fetches the issue via `gh` when reachable (otherwise works from the merged PR / what we just did) and produces the standard template. If it asks for a screenshot/video, provide one (or hand it to the user to attach), then confirm the file landed on Desktop.

### Phase 5 — Comment on the issue (optional)

Same approach as `vocca-end-fast` Phase 4 — ask the user, draft (using the issue + the just-generated report as source material), confirm, then `gh issue comment <id>`. Skip if there's no reachable issue.

The comment can mirror the report's plain-English summary in a sentence or two. Same tone rules: no em dashes, no jargon, no commit hashes. Skip entirely if the user declines.

## Common mistakes

| Mistake | Fix |
|---|---|
| Running the report before cleanup | Phases 0–2 first; the report is last |
| Skipping the report on purpose | Use `vocca-end-fast` / `vef` instead |
| Passing the wrong type to `vocca-report` | Apply the mapping table (`feat`/`feature` → `feature`, `chore` → `task`) |
| Posting the issue comment before the report | The comment (Phase 5) comes after the report (Phase 4); the report's plain-English summary is good source material |
| Cleaning up against `main` | Vocca's base branch is `master` |
| Trying to tag or publish a release at end | There is no release machinery yet — cleanup only; add a release phase when Vocca gains a macOS release pipeline |
| Posting the comment without confirmation | Draft first, confirm with the user, then post |
