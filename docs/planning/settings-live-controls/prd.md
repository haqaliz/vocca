# PRD: Settings that actually change things

**Unit:** `settings-live-controls` · **Branch:** `feat/speech-engine-switch/aliz` · **Owner:** aliz
**Date:** 2026-08-28 · **Phase:** P0 (capability C3), with a P1 tail (C5/C6's deferred settings surface)
**Sources:** `docs/planning/_card/issue.md` (brief), `docs/planning/_card/understanding.md` (deep dig)

---

## Problem Statement

Vocca ships four things a user cannot choose:

1. **The ASR engine.** whisper.cpp shipped as a real second engine in C3, and the composition root
   hardcodes `EngineSelection.defaultSelection` at five sites (`AppBootstrap.swift:196,206,208,355,937`).
   `EnginePickerState`/`EnginePickerCopy`/`EnginePickerView` were built and tested in C3 and are
   constructed by **nothing**. `SettingsView.swift:160` admits it: *"Read-only: switching engines is
   the picker's own surface and is not wired into this window yet."*
2. **The model tier.** A constrained machine cannot drop to the smaller Whisper model, which is the
   whole point of shipping two (`CAPABILITY_ROADMAP.md:82`).
3. **The cleanup provider.** Still `cleanup-config.json`, hand-edited in Application Support
   (`SettingsCopy.cleanupNotEditable` says so in the UI).
4. **The activation mode — which the user *can* change, and which is then silently discarded.**
   `activeMode` initializes from the constant `DictationLoopRoot.defaultMode`
   (`AppBootstrap.swift:888`) and is read from no store, so the General tab's one live control is
   lost on every relaunch.

**Why it's real, not cosmetic.** `docs/ROADMAP.md`'s risk register lists **R5** — *"Parakeet
ecosystem is thin: one maintained CoreML path; a break leaves us stranded"*, Med likelihood /
High impact — mitigated by *"whisper.cpp shipped as a real second engine from week 2, not promised
later"*. A second engine no user can select does not mitigate anything. And
`CAPABILITY_ROADMAP.md:400` guardrail 7 states the standard plainly: **"One implementation and a
promise is not a seam."** By that standard the `ASREngine` seam is, today, an assertion.

`CAPABILITY_ROADMAP.md:81` names the unbuilt deliverable exactly: *"Engine selection in settings,
**switchable without restart**"* plus *"a per-engine model-tier choice"*.

## Goals & Success Metrics

| Goal | Measure |
|---|---|
| The `ASREngine` seam is exercisable by a user, not just by a test | A user selects Whisper in Settings and the next dictation is attributed to `whisper-large-v3-turbo` |
| No setting is silently discarded | Engine, tier and activation mode all survive a relaunch — pinned by test |
| No restart to change engine | A selection change applies at the **next session boundary**; a session in flight is never swapped |
| The privacy surface tells the truth | The Cleanup tab names the actually-resolved provider and its endpoint, agreeing with the widget's egress badge |
| The tier collision cannot ship | Each tier has a distinct store key; downloading one never reports the other installed |

**Explicitly not a metric here:** whisper's transcription quality. See R-A.

## User Personas & Scenarios

The ICP — a Mac user who lives in dictation all day and will not send audio to the cloud.
**Stated as an assumption, not a finding:** Vocca has zero external users today, and the P2 gate is
the first that requires any (`ROADMAP.md`, P2→P3). The scenarios below are reasoned from the ICP
and from named repo facts; none is validated by a real user.

- **S1 — the stranded user (R5 made concrete).** A Parakeet/CoreML regression lands. Today their
  only recourse is editing Swift and rebuilding. After this unit: Settings → Speech → Whisper turbo.
- **S2 — the constrained machine.** An 8 GB M1. Parakeet's ~2 GB unified-memory floor hurts. They
  pick the q5_0 tier (574 MB) instead of falling off a cliff.
- **S3 — the privacy check.** Before dictating something sensitive they open Settings → Cleanup to
  confirm nothing leaves the Mac. Today that tab answers from a hardcoded literal
  (`AppBootstrap.swift:938`) and would say "Built-in rules" even under BYOK.
- **S4 — the reclaimer.** 2.2 GB of models on a full disk; they remove the one they don't use.

## Requirements

### Must-have

- **M1** A persisted settings store holding engine selection, tier, and activation mode. Absent or
  invalid values fall back to the shipped defaults **loudly** (the `cleanup-config.json` precedent).
- **M2** The composition root reads the store at all five `defaultSelection` sites; `defaultSelection`
  is reached only when the store is empty/invalid.
- **M3** **Switch without restart.** A selection change applies to the next session. A session in
  flight is never swapped — the `setActiveMode` precedent (`AppBootstrap.swift:1277-1291`): refuse
  while in flight, log, apply otherwise.
- **M4** **F1 fix.** The q5_0 manifest declares a tier-specific `engineID`, so the two Whisper tiers
  no longer share `<root>/<engineID>/<version>/` (`ModelStore.swift:89-92`) and one tier's verified
  marker can never satisfy the other.
- **M5** The Speech tab per `PRODUCT_SPEC.md:254-262`: engine/tier rows with the honest tradeoff
  copy, a per-tier `[installed]`/`[download]` badge computed from the (now-distinct) store key, and
  the download flow.
- **M6** Model management (`PRODUCT_SPEC.md:260`): disk used, remove, re-download. **Removal is
  allowed only when idle and only after confirmation**; the next dictation then refuses with
  `.modelUnavailable` before the microphone opens, via the path that already exists.
- **M7** Activation mode persisted (F4) — the General tab's choice survives relaunch.
- **M8** The editable Cleanup tab per `PRODUCT_SPEC.md:264-272`: the three rungs, writing
  `cleanup-config.json`, with the **one-time confirmation dialog naming exactly what gets sent**
  when the cloud rung is selected (*"Not a checkbox buried in a paragraph — a dialog the user has
  to read"*). Subsumes F3: the summary reports the resolved provider, not a literal.
- **M10** **Eager preparation on switch.** Selecting a different engine starts its `prepare()`
  immediately, and the UI shows a *preparing* state. Without this, the first press after a switch
  is refused with `.modelUnavailable` by `engineIfReady()` even though the model is on disk —
  because `DictationEngineResolver` stores its selection at `init` and documents *"resolution is
  never repeated, only preparation is"* (`DictationEngineResolver.swift:29-31,83-85`), so a switch
  needs a fresh resolver whose `isPrepared` starts `false`.
- **M11** **Defined states for the in-between windows** — the question the review gate asked. For
  each of (a) model removed but selection unchanged, (b) selection changed and preparing,
  (c) download in flight, the Speech tab, the menu bar icon and the pill must each report the same
  truth. No window may look identical to working. This is the repo's dominant bug class
  (`CLAUDE.md`: an `LSUIElement` app where "a failed launch and a successful one look exactly the
  same"), so it is a must-have, not polish.
- **M12** **Download-in-flight behaviour is defined**: what happens to a running download when the
  user changes tier, changes engine, or removes a model. `StoreModelDownloadSession` is built with
  one manifest fixed at construction (`AppBootstrap.swift:206`), so this needs a decision, not a
  default.
- **M9** The seam-lint table amendment ships in the **same commit** as the new store, per the house
  process `CompletionFlagStore` itself followed.

### Should-have

- **S1** The Speech tab states each engine's verification status honestly while whisper is unproven
  (see R-A) rather than presenting the two engines as equally exercised.
- **S2** An env-gated check that the shipped manifest digests match the bytes the repository serves.

### Nice-to-have

- **N1** Disk-used figures per tier rather than per engine.
- **N2** A "re-download" that verifies in place rather than deleting first.

## Technical Considerations

**Phase:** P0/C3 for M1–M7, P1/C5–C6 for M8. Prerequisites are all built (C2, C3, C5, C6 shipped).

**Persistence.** `CompletionFlagStore.swift:17-20` is *"the one file in `Sources/` permitted to name
`UserDefaults`"*, pinned by the seam table at `InjectionSeamBoundaryTests.swift:1540`; the FileManager
table at `:1294-1304` is pinned at **exactly four** seams. Decision: **one general UserDefaults-backed
settings store, with the lint-table amendment in the same commit** — the precedent
`CompletionFlagStore` set for itself. Synchronous reads matter: the `main()` show decision already
depends on one (window-server rule — `main()` shows, `configure` never constructs a window).

**Resolution.** `DictationEngineResolver` is constructed once at `AppBootstrap.swift:196` with a
fixed selection. M3 needs the current selection read at each session start.
`EngineSessionStart.resolve(selection:)` (`EnginePickerView.swift:28`) is already the pure,
tested identity resolver for exactly this.

**A contract that is currently untrue.** `EngineSelectionConsumptionTests.swift:24-27` documents
*"**No restart needed** … the resolver takes the current `EngineSelection` as its input, so nothing
about it is cached at launch."* True of the pure function; **false of the wired app**. A passing
test narrates a promise the product does not keep. This unit makes it true, and the doc comment
must be corrected either way.

**Latency & injection:** untouched. No new work on the dictation critical path; the tier choice is
what lets a constrained machine avoid the latency cliff.

**Privacy / local-first:** clean and slightly improved. The only network is the pre-existing,
user-initiated model download. M8 touches the egress surface and must not weaken it — the badge
stays non-dismissable, and the confirmation dialog is added, never traded away.

**CI reality.** The pages are executed by nothing in CI (window-server rule). Reducers, copy pins
and store decisions are the tested half; the panels' first execution is the smoke checklist.

## Risks & Open Questions

| # | Risk | Mitigation |
|---|---|---|
| **R-A** | **Whisper has never transcribed anything.** `WhisperCppEngineWERTests` skips without `VOCCA_MODEL_DIR`; `SMOKE_CHECKLIST.md` step 19 is unexecuted; `tolerances_20260810.md` records the tolerances as *seeded from Parakeet's table, not measured*. The picker offers a 1.6 GB download to an unproven destination. | Ship the switch; a smoke step gates the release. Whisper is labelled unverified until a real run re-baselines its tolerances. **Decided at interview.** |
| **R-B** | Manifest digests are unverified against the served bytes. The predicted `{}`-placeholder defect **does not reproduce** (checked: `44136fa3…` appears in no manifest; no 0/2-byte sizes; no duplicated digests) — but "not the known defect" is not "verified". | S2's env-gated check plus a smoke step. |
| **R-C** | **Scope.** This unit tripled during the interview: three tabs, a store-keying defect, a new seam, a lint amendment, a confirmation dialog. Risk is a branch that never lands. | Six aspects, each independently shippable and reviewable. **Committed merge order: 1 → 2 → 3 → 4 → 6 → 5.** The halfway line: aspects 1–4 alone close C3's milestone and retire R5; aspect 5 (`cleanup-tab`) is the severable tail and may become its own branch without weakening anything that landed before it. |
| **R-F** | **Warm start after a switch.** `startEnginePreparation` preloads the launch engine only, so the first dictation on a newly selected engine is a cold start the C7 `WarmStartTargets` bound never modelled. | M10 prepares eagerly on switch. The warm-start gate's meaning is unchanged for the launch path; the PRD claims **no** warm-start number for the post-switch path and must not imply one. |
| **R-G** | **No effort estimate exists** for any aspect. | `tech-plan` sizes each aspect before its implementation; the merge order above means an overrun truncates the tail rather than stranding the whole branch. |
| R-D | M4 changes an on-disk path. | No user has downloaded either Whisper tier — the release publishes none, and step 19 is unexecuted — so there is nothing to migrate. Verify before implementing. |
| R-E | M8 touches the egress path, the one place `ROADMAP.md` principle 2 says must survive an audit. | The zero-network probe stays green and is the gate; the confirmation dialog is a must-have, not a should. |

**Answered at the review gate:** M11 defines the in-between states; M10 defines post-switch
preparation; M12 defines download-in-flight behaviour.

**Open questions:** whether the completion flag migrates into the new store or stays put (an
implementation detail for the `settings-store` aspect); whether "disk used" is per tier or per
engine (N1).

## Out of Scope

- Hotkey rebinding (`SettingsCopy.hotkeyNotRebindable` stays true).
- The Privacy tab (`PRODUCT_SPEC.md:277`), including the real network-connection counter.
- Widget position, launch-at-login, sounds (`PRODUCT_SPEC.md:252`).
- Measuring whisper's WER, or any claim that one engine is better than the other.
- Anything on the C7 streaming/speculative path, and the C8 matrix baseline run.
- Cross-platform, cloud in the OSS core, hosted-tier work of any kind.

## Aspects

| # | Aspect | Boundary | Depends on |
|---|---|---|---|
| 1 | `model-store-keying` | M4 + per-tier presence/disk queries. Pure store work, no UI. | — |
| 2 | `settings-store` | M1, M9 — the seam, tolerant decode, loud fallback, lint amendment. | — |
| 3 | `engine-resolution` | M2, M3, M7 — the root reads the store; next-boundary switching; the corrected contract. | 2 |
| 4 | `speech-tab` | M5, M6, S1 — the page, badges, download, model management. | 1, 2, 3 |
| 5 | `cleanup-tab` | M8 — three rungs, config write, BYOK confirmation dialog. | 2 |
| 6 | `verification-smoke` | S2, R-A, R-B — env-gated digest check, whisper smoke steps, tolerance re-baselining procedure. | 1 |
