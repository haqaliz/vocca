# Aspect spec: wiring-baseline

> Source: `docs/planning/agent-auth-baseline/prd.md` R3, R4, gap-3 + hard-question pins
> · Date 2026-10-01.

## Problem slice and user outcome

The composition: `AppBootstrap` wires `["HOME": NSHomeDirectory()]` into both providers,
the probe's drives decide the temp-HOME posture, the catalog gains the per-preset
`authHint` copy (rendered under the editor's Environment field), the surface gains the
hard question's D2 line, and the G5 re-anchor lands. User outcome: subscription-auth
CLIs run; the user knows which auth each CLI supports and what the baseline means.

## In-scope requirements

- **The wiring**: `AppBootstrap` passes `baselineEnvironment: ["HOME": NSHomeDirectory()]`
  into `CodingAgentProvider` and `ShellProvider` at their construction (the composition
  root may name Foundation; VoccaActions never computes home). This is an
  `AppBootstrap.swift` change → the **G5 re-anchor** lands in REFACTOR (deliberate,
  computed, dictation digests unchanged).
- **The probe posture**: the probe's drives keep the DEFAULT `[:]` (the composed
  default facts unchanged — `agents=0 spawnsSubprocess=false` untouched) or wire a
  temp HOME for the seeded round trips — decide in the aspect (a temp HOME keeps the
  seeded runs honest; the default facts stay unchanged either way).
- **The auth hints** (gap-3 honest wording): `KnownAgentPreset` gains
  `authHint: String?` — pinned copy per preset, honest ("Claude: `ANTHROPIC_API_KEY` or
  the `claude` subscription login — whichever you use in a terminal works here";
  analogous for codex/gemini/opencode/aider/cursor/q/crush with the subscription
  spellings that exist; a preset without a subscription mode says the key spelling
  only). The editor renders it under the Environment field.
- **The D2 line** (the hard question): the surface copy gains the honest sentence —
  "the baseline hands the agent your home directory; configure only agents you trust"
  (exact-in-spirit with the existing D2 copies, pinned).
- **G5**: the re-anchor in REFACTOR (computed with `shasum -a 256`, never
  edit-to-match; the dictation digests unchanged).

## Out-of-scope

- The executor/providers (own aspects); any credential storage; the dictation path.

## Acceptance criteria (test-first)

1. The composed providers carry the wired baseline (a composition-level test reads the
   provider's configuration or the wiring's fact).
2. The composed default facts unchanged (PROBE line verbatim).
3. The auth hints render under the Environment field (copy pins; each preset's hint
   pinned).
4. The D2 line ships and is pinned.
5. G5 re-anchored deliberately; dictation digests unchanged.

## Dependencies / sequencing

After `executor-baseline` + `provider-baseline`. Before `agent-pins`.

## Open questions

- The probe's temp-HOME posture: decided in the aspect, recorded.