# C4 — System-wide injection ladder

**Type:** feat · **Id/slug:** `injection-ladder` · **Branch:** `feat/injection-ladder/aliz`
**Owner:** aliz · **Source:** inline brief (no GitHub issue exists)

---

## Brief

Build C4: the system-wide injection ladder — `TextInjector` with
`inject(String, into: TargetContext) -> InjectionResult` — with the four rungs in order:
AX `kAXSelectedTextAttribute` gated behind a verified allowlist (it lies), clipboard
save→set→paste→restore with a settling delay tolerating clipboard managers, CGEvent
keystroke synthesis last, and the widget failsafe ending every path. Secure Input
(`IsSecureEventInputEnabled`) short-circuits straight to the failsafe with an honest
message. Precondition: the `feat/audio-capture/aliz` branch merges first.

Write the acceptance tests first, exactly as `CAPABILITY_ROADMAP.md:106` names them: a
UI-automation harness drives the P0 app matrix and asserts injected text appears verbatim;
**the load-bearing test is the failure path** — a fault-injection harness forces each rung
to fail in sequence, including AX's *silent* failure simulated as success-with-no-insert,
and asserts that in every combination the transcript is recoverable from the widget.
Transcript loss is asserted at exactly zero; there is no tolerance band on this test.

## Caveats the dig must not be surprised by

- Real-app AX insertion cannot run on a hosted runner (needs an Accessibility grant and
  real apps) — the same structural limit as the tap adapter and the real-engine WER run.
  Every decision must live above the seam, tested over injected handles.
- The clipboard-manager race is a named failure class: Raycast/Alfred/Paste/Maccy racing
  the restore (`ROADMAP.md:85`).
- The widget failsafe (rung 4) is the next real surface of the still-placeholder `VoccaUI`
  beyond the download window.
- The `feat/audio-capture/aliz` branch must merge first; its `SessionAudioSource` hand-over
  feeds the loop, and the `refusedSampleCount → missingSampleCount` bridge is gated on it
  per `CLAUDE.md`.
- R1 and R2 (`ROADMAP.md:300-302`) are the risks this capability retires: AX silently
  no-ops (High likelihood, Fatal impact) and Secure Input blocks everything.

## Grounding

- Capability definition: `docs/technical/CAPABILITY_ROADMAP.md` C4 (lines 89–110); seam
  table line 305.
- Phase: **P0** — core dictation loop (`docs/ROADMAP.md` weeks 1–4; week-3 milestone at
  line 84; P0 app matrix at lines 89–91; success metrics at lines 93–98).
- Risk register: R1 (`docs/ROADMAP.md:300`), R2 (`:302`), R9 (notarization scrutiny, `:308`).
- Seam discipline: `docs/technical/CAPABILITY_ROADMAP.md:27`.
