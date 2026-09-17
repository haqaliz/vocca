# Card: feat/dual-mode

> Inline brief — no GitHub issue exists (`gh issue list` for `haqaliz/vocca` is empty).
> Source: the `vocca-next` handoff (2026-09-16) + `CAPABILITY_ROADMAP.md` C11 entry +
> the C10 unit records (STATUS.md turn-taking-barge-in entry, turn-taking PRD/plans).

## Brief

Build **C11 — dual mode (dictate vs converse)** (`CAPABILITY_ROADMAP.md:309-325`): the
CONVERSING surface C10's machinery was built for. C10 shipped 2026-09-15 as seam-only
machinery — `TurnTakingLoop`, `PlaybackEngine`/`SystemPlayback`, `ContinuousAudioSource`
+ `StreamingCapture` — composed into nothing and holding no mic seam; its records name
this unit as the consumer: "nothing wires the loop into the app until C11"
(`docs/STATUS.md:107`), "the CONVERSING surface is C11's" (turn-taking PRD), and the
loop's composition recipe and `onStateChange` hook are recorded as C11's wiring
(`turn-taking-barge-in/barge-in-loop/plan_20260915.md:877-880`).

What we build: two distinct hotkeys with two unmistakably different widget states (color,
shape, sound); `SessionMode` as an explicit state machine with **no implicit mode
switching, ever**; per-mode configuration (different cleanup providers, different ASR
engines) — deferred here by the llm-cleanup, cleanup-config, engine-picker and
hotkey-rebinding records; a visible indicator of the injection *target* in dictate mode
("→ Slack"); and the structural guarantee that converse mode can never call
`TextInjector`.

Dependencies C4 (injection ladder) and C10 (turn-taking machinery) are shipped; C11 is
the lowest unshipped capability.

Acceptance, written first (per `CAPABILITY_ROADMAP.md:315-321`): a test asserting that in
converse mode **no `TextInjector` call is ever made** — the structural guarantee that
agent conversation cannot leak into an app field, enforced by type or assertion rather
than discipline; a mode-transition test asserting state is fully reset between modes with
no carryover of buffer, transcript, or target.

Seams: `SessionMode` as the explicit state machine, with the injection path only
reachable from the dictate state. `SessionMode` already exists in `VoccaCore` (declared,
dictation-only in the pipeline). Per-mode deferrals to honor: cleanup selection
(`llm-cleanup/prd.md:216,267`), engine choice (`second-asr-engine/engine-picker/spec.md:39`),
the converse-mode second chord (`hotkey-rebinding/prd.md:268`).

## Caveats (binding)

- The P2 and P3 gates stay **uncleared**; this is the third unit built ahead of them
  under the recorded posture (`docs/STATUS.md`, kokoro-binding and turn-taking entries),
  not a drift. No gate passes; the P3 gate's full spoken exchange is SMOKE-verifiable
  only, never CI.
- **The realtime conversation is executed by nothing in CI.** The env-gated suite skips
  visibly; SMOKE steps 131-133 are written and runnable for the founder's machine
  (`STATUS.md:93-96`); C11's real verification lands there too.
- **`ParakeetEOU` stays PENDING** — `SilenceThresholdDetector` is the shipped
  `TurnDetector` (`STATUS.md:29-31`); C11 consumes the seam as-is, no re-litigation.
- The zero-network invariant and the transcript-never-lost invariant are load-bearing:
  nothing here may hand a URL to any port, and every `.ended` with non-empty text
  terminates in an injector call or a journaled failsafe hold.
- Hold-to-talk remains available forever as the escape hatch — dual mode must not
  remove or weaken the dictate path.