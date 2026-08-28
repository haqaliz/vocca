# Aspect 4: `speech-tab`

**Merge order: 4th.** Depends on aspects 1, 2, 3.

## Problem slice

`SettingsView.swift:160-176` renders a read-only Speech tab and says so.
`PRODUCT_SPEC.md:254-262` — authoritative on user-visible behaviour — specifies the surface:

```
◉ Parakeet v3      Fastest. 25 European languages.        [ installed ]
○ Whisper turbo    Slower, broader language coverage.     [ download ]

  Model management: disk used, remove, re-download.
```

`EnginePickerState`/`EnginePickerCopy`/`EnginePickerView` exist, are tested, and are constructed
by nothing.

**User outcome:** the person in scenarios S1, S2 and S4 can act.

## In scope

- **R1** Engine/tier rows with the honest tradeoff copy, over the existing reducer where it fits.
- **R2** Per-tier `[installed]`/`[download]` badge from aspect 1's presence query.
- **R3** The download flow, reusing the existing `ModelDownloadSession` surface and folding
  `DownloadState` the way `OnboardingView` already does for the MODEL step.
- **R4** Model management (`PRODUCT_SPEC.md:260`): disk used, remove, re-download.
- **R5** **Removal is allowed only when idle, and only after confirmation** (interview decision).
  The next dictation then refuses with `.modelUnavailable` before the microphone opens.
- **R6** **The in-between windows report one truth** (PRD M11): for (a) model removed, selection
  unchanged, (b) selection changed and preparing, (c) download in flight — the Speech tab, the menu
  bar icon and the pill agree. No window may look identical to working.
- **R7** **Whisper's honest status** (PRD S1/R-A): the tab does not present the two engines as
  equally exercised while whisper has never transcribed anything.
- **R8** Download-in-flight behaviour defined (PRD M12) for tier change, engine change and removal.

## Out of scope

- Hotkey rebinding; widget position; launch at login; sounds.
- The Cleanup tab (aspect 5) and the Privacy tab (not in this unit).
- Any WER or latency claim about either engine.

## Acceptance criteria (tests first)

1. The page's decisions live in a **reducer tested headless** — the house pattern (Apps tab,
   `MenuBarState`, `WidgetStateReducer`). The view is thin glue.
2. Copy pinned byte-for-byte to `PRODUCT_SPEC.md:254-262` (the `BadgeCopy`/Apps-tab precedent).
3. A row whose tier is present reads `installed`; absent reads `download`; and after aspect 1's
   fix, one Whisper tier being present never makes the other read `installed`.
4. R5: removal is refused while a session is in flight; permitted when idle; and after removal the
   presence query answers `false`.
5. R6 is a **closed-set** test: for each of the three windows, the three surfaces' reported states
   are asserted together, so a state that looks like working fails.
6. R8: each of the three in-flight interactions has an asserted outcome.
7. Reduce Motion and VoiceOver labels honoured, per the house rule that shape and text carry state.

## Risks

- **Executed by nothing in CI** (window-server rule). The reducer and copy are the tested half;
  the page's first execution is a new `SMOKE_CHECKLIST.md` step, which this aspect adds.
- The existing picker reducer was written for a standalone surface; it may not fit a settings Form
  unchanged. Reuse where it fits, and say plainly where it does not rather than bending it.
