---
name: tech-plan
description: Create a phased technical implementation plan from planning artifacts in docs/planning (PRD + aspect spec). Use after prd-interview when ready to execute a specific aspect. Triggers on "tech plan", "implementation plan", "plan from PRD".
tags:
  - planning
  - documentation
metadata:
  status: trial
---

Create a phased technical implementation plan from planning artifacts under `docs/planning/{slug}/`.
Inputs can come directly from `prd-interview`; do not require `prd-generator`.
This is Phase 5 of `vocca-begin-fast` — the plan it produces is executed in Phase 6 through the agents team under strict TDD.

If the user provided artifacts in context (attached file, pasted content, or referenced path), use them directly.
Otherwise, search the workspace for:

- PRDs matching `docs/planning/*/prd.md`
- Aspect specs matching `docs/planning/*/*/spec.md`

Analyze the current codebase, then create a detailed **Implementation Plan** optimized for autonomous agent execution.
Vocca is **greenfield**: today the authoritative reading is `docs/ROADMAP.md` (the phases P0..P5, their gates, and any risks it lists) plus `CLAUDE.md`/`VISION.md`; the core will live under `src/vocca/` once it exists.
The plan should be structured so the agent team can work through it systematically with minimal human intervention.

## Handoff Contract

- **Feature requirements source:** `docs/planning/{slug}/prd.md`
- **Aspect requirements source (preferred):** `docs/planning/{slug}/{aspect}/spec.md`
- **Plan output (required):** `docs/planning/{slug}/{aspect}/plan_YYYYMMDD.md`

Plan one aspect at a time. If a feature has multiple aspects, create one plan file per aspect.

**Filename:** `plan_YYYYMMDD.md` (YYYYMMDD is today's date, e.g., `plan_20260715.md`)
**Location:** the aspect directory (e.g., `docs/planning/dictation-core/text-injection/plan_20260715.md`). Create it if needed.
If the user provided an aspect spec from a different location, write the plan alongside that spec.
If only a PRD is provided (no aspect spec), ask which aspect to plan, create or update `spec.md` for that aspect, then write the plan in that aspect directory.
If the PRD was pasted or attached (no file path), ask the user to confirm both feature slug and aspect name, then write to `docs/planning/{slug}/{aspect}/plan_YYYYMMDD.md`.

## Deliverables

### 1. Project Setup Checklist

- Directory/module structure to create (under `src/vocca/`, `tests/`, or the widget UI once it exists)
- Configuration needed (pyproject/cargo entries, env, pinned tool versions for reproducible builds)
- Dependencies to add (with specific versions where critical) — Python via `uv add`, widget UI via `npm install`
- **Greenfield:** if `pyproject.toml` / `uv.lock` / `src/` don't exist yet, scaffolding them is part of the plan's first phase — say so explicitly rather than assuming `uv sync` works. Test-first still holds: the failing test comes before the package.

### 2. Implementation Phases

Break the build into sequential phases that can be executed autonomously. For each phase:

**Phase N: [Name]**

- **Goal:** What this phase accomplishes
- **Prerequisites:** What must exist before starting
- **Files to create/modify:** Explicit list
- **Validation:** How to verify the phase is complete (`uv run pytest <path>`, expected outputs; the widget UI's test/build commands for UI work)
- **Commit message:** Suggested commit message for this phase

Each phase is a unit the agents team can own end-to-end under TDD (RED → GREEN → REFACTOR).

### 3. File-by-File Build Order

Ordered list of every file to create, with: filepath, one-line purpose, key functions/components it exports, and dependencies on other files.

### 4. Testing Strategy

- Unit tests to write (mapped to implementation phases) — these are written **first** in Phase 6
- Integration tests
- Manual verification steps
- Test commands: `uv run pytest` (Python core), widget UI test/build commands for UI work
- **Start from the phase's acceptance list.** `docs/ROADMAP.md` states each phase's acceptance as tests to write before the code — lift them rather than inventing parallel ones. Core tests **run with no network** and use fixture recordings for audio; any model call (ASR/TTS/LLM) sits behind an injectable seam so tests never hit a real model or the network in CI.

### 5. Environment & Privacy

- Environment variables needed
- External tools/services to configure (and how they're pinned)
- Local setup: `uv sync`; widget UI `npm install`
- Note any privacy/local-first requirements — Vocca keeps audio and text on-device by default; nothing leaves the box in the OSS core. Any network call must be opt-in and behind a pluggable seam. A test whose result depends on the network is a bug in the plan.

### 6. Edge Cases & Error Handling

- Known edge cases to handle
- Error states to account for, and **how each fails safely**. Name what happens when the layer can't do its job: ASR returns nothing, VAD never endpoints, the focused app rejects text injection, TTS can't load the voice, no microphone permission. Prefer a clear, recoverable failure (tell the user, keep the app usable) over a silent one.
- Fallback behaviors

### 7. Agent Execution Notes

- Suggested checkpoints for human review
- Areas likely to need iteration or debugging
- Sections where the agent should ask for clarification before proceeding

## Guidelines

- Be extremely explicit — assume no implicit knowledge
- Prefer small, testable increments over large monolithic steps
- Each phase should result in runnable (even if incomplete) code, with the suite kept green
- Flag any spec ambiguities that could block implementation
- Note assumptions clearly
- Optimize for autonomous execution by the agents team with minimal back-and-forth
- Don't plan work that puts cloud in the OSS core, crosses to another platform before macOS is solid, or cripples the local core to set up the paid tier — flag it against the `CLAUDE.md` guardrails instead
- Respect the phase build order (P0..P5): don't plan a capability whose prerequisites aren't built. Keep ASR/TTS/LLM behind interfaces — abstractions are earned by the second implementation, not designed for the first.

## Edge Cases

- **Greenfield vs. existing codebase**: For greenfield, include full setup. For existing code, skip scaffolding and focus on integration points and impact analysis. Vocca is greenfield today — expect the setup path.
- **No aspect spec exists yet**: Derive a candidate aspect list from the PRD, ask the user to choose one, draft `spec.md`, confirm, then plan.
- **Incomplete PRD**: If the PRD lacks testable acceptance criteria or measurable metrics, flag this and recommend running `prd-interview` before planning.
- **Multiple PRDs**: Separate plans per PRD unless they share infrastructure, in which case note shared phases.
- **Multiple planning sessions**: If an aspect has multiple `plan_YYYYMMDD.md` files, base the new plan on the current `prd.md` + `spec.md`. Create a new plan file with today's date.
- **PRD with flagged gaps**: If `prd-interview` produced the PRD via the "just write it" path, gaps may be marked. Note these in the plan and recommend resolution before the affected phase.
