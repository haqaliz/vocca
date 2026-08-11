# PRD — C2: Local ASR behind `ASREngine`

| | |
|---|---|
| **Capability** | C2 (`docs/technical/CAPABILITY_ROADMAP.md:50`) |
| **Phase** | **P0** — core dictation loop, week 2 |
| **Pipeline layer** | **ASR** (second of capture → ASR → cleanup → injection → TTS → actions) |
| **Branch** | `feat/local-asr/aliz` |
| **Dependencies** | C1 (`audio-capture` aspect must merge first; its hand-over type is this seam's input) |
| **Status** | Draft — awaiting review gate |

Evidence labels: **[SDK]** = verified against the FluidAudio README/API on 2026-08-09
(`from: "0.12.4"`); **[DOC]** = repo document with `file:line`; **[UNVERIFIED]** = flagged
as risk.

---

## 1. Problem statement

C1 ends with a microphone that captures into a ring buffer and a session machine that hands
the audio over. **Nothing transcribes it.** The product is named after the capability this
PRD builds: speech → text, on-device, fast enough to feel instant.

The real problem is not "add an ASR call". It is **the seam**, and then **the first engine
behind it**:

> Vocca's entire pluggability claim — a better local model, a community engine, or the
> future hosted tier slots in without a rewrite — stands or falls on `ASREngine` having two
> real implementations. C2 ships the first and proves the protocol is implementable; C3
> (whisper.cpp) ships the second and proves it is *swappable*.

**Evidence it is real, not theoretical:**

- `ROADMAP.md:82` — week-2 milestone: "ASR behind the seam; Parakeet via FluidAudio as the
  first implementation", success signal "a 10-second clip transcribes correctly, on-device,
  airplane mode on".
- `ROADMAP.md:304` (R5) — the Parakeet ecosystem is thin ("one maintained CoreML path; a
  break leaves us stranded") — the seam exists *because* of this risk; the hedge (whisper.cpp)
  is C3.
- `ROADMAP.md:302` (R3) — latency ceiling: ASR owns most of the perceived-latency budget;
  C2 establishes the engine that P2's p50 ≤ 400 ms gate will be judged on.
- `CLAUDE.md` (Key strategic constraints 1 and 2) — local-first and pluggable: audio and
  text stay on-device in the OSS core, and ASR sits behind an interface from day one.

### Secondary problem: the model lifecycle does not exist

`CAPABILITY_ROADMAP.md:57` requires download-on-first-run with a progress UI, integrity
verification, and a resumable transfer, with models in Application Support. **None of that
machinery exists, and no planning document names how the ~2 GB CoreML model reaches a
machine or a CI runner.** The acceptance literally cannot run until this is decided — the
planning docs name the destination (`ARCHITECTURE.md:489-490`), the fixture suite
(`ARCHITECTURE.md:527-528`) and the fixture home (`ARCHITECTURE.md:117`), and then stop.

### And the third: the completeness count stops at C1's seam

`docs/planning/audio-capture-hotkey/audio-capture/plan_20260806.md:331-334` says it plainly:
"Hand-over → transcript → *the user is told the audio was short* is owned by nothing."
The C1 aspect's Phase 5 will hand over a buffer marked incomplete-with-a-count; C2 is the
natural owner of the next link — the count must surface in whatever presents the transcript,
or short audio quietly masquerades as complete (I1, `ARCHITECTURE.md:15`).

---

## 2. Goals & success metrics

### Primary — the seam and its first implementation

| Metric | Target | How measured |
|---|---|---|
| `ASREngine` protocol | Exists in `VoccaCore` with the §4 vocabulary, `transcribe` real, `stream`/`prepare` declared | Protocol + vocab types per `ARCHITECTURE.md:219-229`, `:129-156`; module-boundary lint updated |
| First implementation | **Parakeet TDT 0.6B v3 via FluidAudio** behind it, `engineIdentity = "parakeet-tdt-0.6b-v3"`, `isLocal = true` | The fixture suite runs against it; identity asserted on every `Transcript` |
| Fixture suite (the C2 acceptance) | 5 fixtures within WER tolerance, **network interface down**, in CI | `Tests/Fixtures/` + parameterized harness + zero-network interposer (this PRD §4 M7) |
| **Transcript loss / completeness** | The captured buffer's `refusedSampleCount` reaches the `Transcript` as a visible "short by N samples" | Bridge test: incomplete buffer → `Transcript.missingSampleCount == N`; complete → `0` (this PRD §4 M5) |
| **Offline invariant** | Transcription itself makes **zero** network calls; FluidAudio's own download path is structurally disabled | `ModelHub.offlineMode = true`; the interposer run of the fixture suite; a lint forbidding the FluidAudio download APIs |

**WER tolerances (provisional, per the founding decision — adjusted from the first real run,
never guessed):** clean ≤ 10% · accented ≤ 12% · noisy ≤ 20% · 60 s ≤ 10% · 200 ms WER 0
(the single word recovered exactly; at most one substitution tolerated while provisional).
The exact values are set from the founder's first full run on an M-series Mac and recorded
in `Tests/Fixtures/FIXTURES.md`; the tolerance mechanism (scoring, normalization) is fixed
by then, only the numbers move.

**CI runtime budget:** the fixture suite (model download + transcription) must fit in
**≤ 12 minutes** of the 20-minute headless job (`ci.yml:67`) — a number the plan's CI task
is judged on, with the honest fallback (real-engine run on founder hardware, SMOKE_CHECKLIST)
triggered if the suite cannot meet it.

### Secondary — the model lifecycle

| Metric | Target | How measured |
|---|---|---|
| Download-on-first-run | Model fetched on first use, **user-initiated**, with progress | `ModelDownloader` with an injectable transport; stub-transport tests headlessly |
| Integrity verification | Every file verified against a pinned checksum manifest before load | SHA-256 manifest shipped in-repo per version; corrupt-file → redownload (bounded) |
| Resumable transfer | A killed download resumes, not restarts | `.part` files + Range; injected transport failures in tests |
| Storage | `~/Library/Application Support/Vocca/models/<engine-id>/<version>/` | `ARCHITECTURE.md:489-490`; asserted in tests with a temp Application Support dir |
| Warm load-once | Model loads at first use and stays warm; **first use is allowed to be slow** | Load time recorded (local-only); launch preload explicitly deferred to C7 |
| Zero-network default | The default dictation path makes no network calls — **unchanged** by adding ASR | The C1 interposer probe extended to drive a full session + transcription with the engine warm |

`ROADMAP.md:98` — latency is measured and recorded at P0, gated at P2. C2 records
(cold-load time, warm transcribe time per fixture, p50/p95 over 3 runs) and gates nothing,
with C7's end-to-end p50 ≤ 400 ms target (`ROADMAP.md:171`) as the yardstick the recorded
numbers are compared against.

---

## 3. Persona & scenario

The Vocca ICP: a Mac user who lives in dictation all day and will not send their audio to
the cloud. At C2 they can hold `⌥Space`, hear nothing happen (C1's waveform), and get no
text — the honest scenario is the **second trust transaction**:

> They install Vocca, grant permissions, hold `⌥Space`, say a sentence — and the words
> appear in the widget. The model downloaded itself on first use, with a progress bar and
> a Skip. The whole exchange was on-device; they can prove it by switching the Mac to
> airplane mode and doing it again.

That is the moment the product's name starts being true.

---

## 4. Requirements

### Must-have

**The seam (VoccaCore)**

- **M1** `ASREngine` protocol per `ARCHITECTURE.md:219-229` — `identity`, `supportsStreaming`,
  `prepare()`, `transcribe(_ buffer: AudioBuffer)`, `stream(...)` — in `VoccaCore`, which
  imports nothing. C2 makes `transcribe` real; `stream` is declared with a batch default
  and `supportsStreaming == false` for Parakeet at C2 (**streaming is C7's**,
  `CAPABILITY_ROADMAP.md:146-160`). Callers never branch on engine identity.
- **M2** The §4 vocabulary in `VoccaCore` — `AudioBuffer` (16 kHz mono Float32;
  `ARCHITECTURE.md:129-135`), `Transcript` (`text`, `segments`, `engine` — **non-optional**,
  attribution is I1, `ARCHITECTURE.md:140-141` — `isFinal`, `audioDuration`),
  `TranscriptSegment` (`text`, `range`, `confidence: Float?`), `EngineIdentity`
  (`id`, `displayName`, `isLocal`). `VoccaError.modelUnavailable` / `.transcriptionFailed`
  (`ARCHITECTURE.md:186-190`).
- **M3** **Empty/very-short buffer policy:** a ~0-sample buffer (C1: "an empty buffer is a
  legitimate answer", `SessionAudioSource.swift:95-97`; live presses under ~122 ms lose the
  opening, `plan_20260806.md:185-187`) yields a **valid empty `Transcript`** — `text == ""`,
  `audioDuration` = actual — never an error. The 200 ms fixture is the suite's floor.
- **M4** **The completeness link (I1):** `Transcript` carries `missingSampleCount: Int`
  (0 = complete). The C1→C2 bridge — the captured buffer (complete/incomplete + count) to
  `AudioBuffer` — lives in `VoccaAudio` (the adapter that produced it), and the count flows
  into the `Transcript`. **Amends `ARCHITECTURE.md` §4** (the vocab has no completeness
  field today; `plan_20260806.md:331-334` names the gap).

**The first engine (VoccaASR — moves leaf → adapter)**

- **M5** `ParakeetEngine` in `VoccaASR`, an **actor** per `ARCHITECTURE.md:36`; module
  boundary lint updated (`VoccaASR` imports `VoccaCore` and nothing else among Vocca
  modules). **The first external dependency in the repository**: FluidAudio
  `from: "0.12.4"` **[SDK]**, Apache-2.0 **[SDK]**, product `FluidAudio` — macOS, Swift 6.
- **M6** **FluidAudio integration rules.** `ModelHub.offlineMode = true` at engine
  construction **[SDK]** — every FluidAudio download API (`downloadAndLoad`, `fetchWithAuth`)
  then throws `DownloadError.networkDisabled`, so a wrong code path fails loudly instead of
  quietly egressing. Models are loaded **manually** from the Vocca-managed Application
  Support directory via the load-from-URL API **[SDK]**. A seam lint confines `FluidAudio`
  identifiers to exactly one file in `Sources/` — the H7 pattern (`HotkeySeamBoundaryTests`)
  applied to the ASR adapter.
- **M7** `prepare()` is idempotent and loads the model into the resident manager once;
  `transcribe()` ensures prepared. Warm load-once; **launch preload is explicitly C7's**
  (`CAPABILITY_ROADMAP.md:152`) — the C2 sentence "first dictation after launch is not the
  slow one" (`:58`) is unsatisfiable by load-once and is **amended in that document**.

**The model lifecycle (VoccaASR/Models, reserved at `ARCHITECTURE.md:93`)**

- **M8** `ModelDownloader`: fetch the pinned model files (`FluidInference/
  parakeet-tdt-0.6b-v3-coreml` **[SDK]**) into `Application Support/Vocca/models/
  <engine-id>/<version>/` with an **injectable transport** (URLSession seam), progress
  (0...1 closure), **resumable** transfer (`.part` files + Range), and **per-file SHA-256
  verification** against a manifest **shipped in-repo** (never fetched — verification stays
  offline and honest). User-initiated on first use; `Skip` leaves the engine unavailable
  with a clear `modelUnavailable` reason. **This is the first of the two named network
  types** (`ARCHITECTURE.md:16` names two and never names them — this PRD names one; the
  BYOK client in C6 is the other). **Amends `ARCHITECTURE.md` I2.**
- **M9** Model presence/version check: enough registry for C2 (`isPresent`, version,
  `downloadIfMissing`); the full in-app registry is C14's (`CAPABILITY_ROADMAP.md:276-288`).
  "**No auto-updating models**" (`PRODUCT_SPEC.md:273`) — the verifier never silently
  refetches.

**The fixture suite and CI (Tests/)**

- **M10** Fixture assets in `Tests/Fixtures/` (reserved `ARCHITECTURE.md:117`): `clean.wav`
  (~10 s), `accented.wav` (~10 s), `noisy.wav` (~10 s, deterministic mix of the clean clip
  and synthetic noise, fixed SNR, generated once and checked in), `sixty-second.wav`
  (60 s), `two-hundred-ms.wav` (200 ms, a single word), each with a checked-in golden
  transcript `.txt`. Provenance, recording settings, and licenses recorded in
  `Tests/Fixtures/FIXTURES.md` (founder's own voice — license-clean by construction).
- **M11** A **WER scorer** as a pure, table-tested function (word-level, case- and
  punctuation-normalized) — the repo's pattern: the decision lives where tests can reach it.
- **M12** The **fixture suite harness, parameterized over engines from day one** — one test
  body, run against every `ASREngine` (`CAPABILITY_ROADMAP.md:77` is C3's reuse of this
  suite; writing it parameterized now is what makes C3 a swap rather than a rewrite).
- **M13** **The offline assertion is part of the suite**: the fixture run executes with the
  zero-network interposer loaded (`CVoccaNetworkInterposer`), so any engine-side egress
  fails the run. **Amends the CI job** with a model-cache setup step (cache keyed on the
  model version; on miss, a provisioning script downloads and verifies — network allowed in
  provisioning, never in tests; FluidAudio's own offline-pipeline workflow is the cited
  reference **[SDK]**).
- **M14** **A lint test** pins the FluidAudio import set and the downloader's confinement
  (which file may name FluidAudio; which may name `URLSession`).

**The minimal download surface (VoccaUI)**

- **M15** A bare progress window: progress bar, cancel/Skip, honest copy ("Downloading the
  speech model — your audio never leaves this Mac"), shown when the engine is missing and
  dismissed on completion or skip. **The first real `VoccaUI` code** (it is a placeholder
  today). The full onboarding step 3 with copy and try-it semantics is the C1 widget
  aspect's, not C2's — `PRODUCT_SPEC.md:166-170` remains the design, truncated in scope.

**Docs, kept in sync (the C1 M37 pattern, `prd.md:242`)**

- **M16** Amend `ARCHITECTURE.md`: §4 vocab (+`missingSampleCount`), I2 (name `ModelDownloader`
  as the first network type), module table row (`VoccaASR` = adapter, actor). **Reviewer:
  aliz** (founder), signed off in this PR's review — the same doc-amendment discipline C1
  applied.
- **M17** Amend `CAPABILITY_ROADMAP.md`: C2 warm-start wording (`:58` → load-once at C2,
  preload at C7) and the C2 acceptance's fixture/CI strategy summary. Also correct
  `PRODUCT_SPEC.md:166`'s "≈600 MB" against the measured artifact size. **Reviewer: aliz.**

### Should-have

- **S1** `prepare()`/transcribe timing recorded (local-only counter, `endReason`-style
  instrumentation): cold-load time, warm transcribe per fixture, first-dictation-after-launch.
- **S2** A bench script (`Scripts/bench-asr.sh` + a probe target, the
  `measure-engine-start.sh` pattern) that runs the suite against a real model on the
  founder's machine and prints p50/p95 — the C7 latency work inherits real numbers.
- **S3** Download failure UX: a failed download retries with backoff and reports a
  distinct state; the widget (once it exists) shows it.

### Nice-to-have

- **N1** A second model tier (Parakeet TDT v2, English-only **[SDK]**) selectable by
  constant — C3's per-engine tier problem; only the plumbing.

---

## 5. Technical considerations

**Phase:** P0, week 2. **Layer:** ASR. **Prerequisites:** C1 — the `audio-capture` aspect
must merge before implementation begins (its hand-over Buffer type and the
`SessionAudioSource` conformance are this seam's input; the branch is mid-Phase-4 as of
this PRD). The planning work here does not wait on it.

**Local-first / zero-network:** inference is fully on-device; `ModelHub.offlineMode = true`
makes FluidAudio's own egress structurally impossible **[SDK]**. The one network-permitted
type (`ModelDownloader`) is user-initiated, verified, and skipped-by-default-silent-never:
no egress ever happens on the default dictation path, and the C1 interposer test is
extended (not replaced) to cover a full session + transcription. The C6 release blocker
(`CAPABILITY_ROADMAP.md:138`) inherits this unchanged.

**Latency:** ASR owns most of the budget (`ROADMAP.md:52`; ≤250 ms finalize in
`ARCHITECTURE.md:267`). C2 measures (S1/S2) and gates nothing; the numbers C7 optimizes
against come from here. The opening-syllable loss (~122 ms, `plan_20260806.md:185-187`)
means real utterances start slightly late — fixtures are evaluated on content, not timing.

**Pluggability:** one implementation at C2, proven at C3 — the accepted, time-bounded C1
pattern (`audio-capture-hotkey/prd.md:400-404`, G5). The fixture suite is written
parameterized from day one so C3 is a swap. `EngineIdentity.isLocal == true` ⇒ no egress
badge (`ARCHITECTURE.md:152-156`).

**Concurrency (Swift 6 strict):** `ParakeetEngine` is an actor; transcription never runs
on the main actor (I6, `ARCHITECTURE.md:20`); `AudioBuffer`/`Transcript` are `Sendable`
values. No `@unchecked Sendable` additions — the ring buffer keeps its monopoly
(`AudioRingBuffer.swift:48`).

**Model facts (verified today against the FluidAudio README, `from: 0.12.4`):** Apache-2.0;
SPM product `FluidAudio`; batch API `AsrModels.downloadAndLoad(version: .v3)` →
`AsrManager(config: .default)` → `loadModels(_:)` → `transcribe(samples)` where samples are
"16 kHz, already converted" — **the interchange format matches Vocca's exactly**
(`CapturedAudioFormat.interchange`). RTF "~190× on M4 Pro" **[SDK, unverified against the
repo's ~24× figure at `ROADMAP.md:14`]** — recorded, not resolved here. Model cache dir
default `~/.cache/fluidaudio/Models/` is **bypassed** via manual load-from-URL. Their CI
ships an offline-pipeline model-cache workflow usable as the reference for ours **[SDK]**.

**Distribution constraint:** unchanged — Developer ID, not MAS (`audio-capture-hotkey/
prd.md:303-308`). A ~2 GB model downloaded into Application Support is untouched by app
updates, per `PRODUCT_SPEC.md:273`.

---

## 6. Risks & open questions

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| **R3** (roadmap) | Latency ceiling worse than expected | High | C2 measures cold-load and warm-transcribe and records them (S1/S2) — C7 optimizes against data, not guesses |
| **R5** (roadmap) | Parakeet ecosystem thin — FluidAudio breaks | Med | FluidAudio is Apache-2.0, 2.6k stars, 644 commits, actively maintained **[SDK]**; the adapter isolates it (M6 lint); C3's whisper.cpp is the structural hedge and its fixture-suite reuse is built into M12 |
| **C2-A** | CoreML under the CI VM (no ANE) is slow enough to flake the 20-min job | Med | Model cache setup step; suite timeout budgeted explicitly; the honest fallback (real-engine run on founder hardware, SMOKE_CHECKLIST) is documented, not silent — the `test-with-floor` lesson |
| **C2-B** | FluidAudio API drift between 0.12.4 and the implemented version | Low | Version pinned; the adapter is one file; the M14 lint fails loudly on API renames |
| **C2-C** | Model artifact source/checksum provenance (HF repo `FluidInference/parakeet-tdt-0.6b-v3-coreml`) | Med | Checksum manifest shipped in-repo, per version; download verified file-by-file before load; corrupt → bounded redownload (M8) |
| **C2-D** | The completeness count stops at C2's transcript instead of reaching the user | Med | `Transcript.missingSampleCount` (M4); the widget's presenter (widget aspect) inherits it as a requirement — flagged in that aspect's backlog, closed as far as C2 can |
| **C2-E** | The "zero network on default path" claim erodes via the downloader | **Fatal (positioning)** | `ModelHub.offlineMode` makes it structural; the interposer runs the fixture suite (M13) and the C1 probe is extended; the downloader is the one named network type (M8) |
| **C2-F** | "Skip" leaves a user with a dictation tool that silently does nothing | High | `modelUnavailable` reason is explicit and honest (M8); the widget-facing copy is a named requirement for the widget aspect |

**Open questions**

1. Exact WER tolerances — deliberately unset; set from the founder's first run (founding
   decision, §2).
2. Actual model size on disk (PRODUCT_SPEC.md:166 says "≈600 MB"; ROADMAP/CAPABILITY say
   "~2 GB unified-memory floor" — the size discrepancy is recorded, resolved by measuring
   the downloaded artifact at implementation).
3. Accented fixture: the founder's own accent register, or a second speaker if one is
   available? Default: founder, two registers (clean and stronger accent).
4. Does the 60 s fixture stay one continuous read or include a mid-sentence pause
   (simulating the ~122 ms opening loss + natural phrasing)? Default: natural continuous
   read, ~150 words.

---

## 7. Out of scope

- **Streaming / partials / speculative ASR** — C7 (`CAPABILITY_ROADMAP.md:146-160`).
  `supportsStreaming == false` at C2; the protocol declares the capability so C7 slots in.
- **whisper.cpp and the engine picker settings** — C3 (`CAPABILITY_ROADMAP.md:68-82`);
  the C3-vs-`ROADMAP.md:74` settings tension is C3's to resolve, not C2's.
- **ITN / cleanup / custom dictionary** — P1 (`ROADMAP.md:108-146`); FluidAudio's ITN
  tool exists and is deliberately not wired here.
- **Model registry UI / management tab** — C14 (`CAPABILITY_ROADMAP.md:276-288`); C2 ships
  presence + download-if-missing only.
- **Onboarding step 3's full copy and try-it story** — the C1 widget aspect (truncated
  onboarding is C1's, `audio-capture-hotkey/prd.md:228-231`).
- **VAD / endpointing, the EOU model, streaming capture** — P3 (C10).
- **Audio capture itself** — C1; C2 consumes its output.
- **Any egress** — no cloud path, no BYOK, no telemetry. `EngineIdentity.isLocal == true`.

---

## 8. Guardrail check

Clean. macOS-only by construction (CoreML/ANE is the reason cross-platform was deferred,
`ARCHITECTURE.md:542`). Local-first: inference on-device, download user-initiated, zero
network on the default path (M6/M13 make that structural). Pluggable: seam in Core, one
implementation now, the fixture suite parameterized so C3's second implementation is a
swap, not a rewrite. Dictation-first (P0): this *is* the dictation core. Open-core: nothing
remote; `ASREngine` remains the hosted-tier slot-in point with the "added, never in place
of" rule (`ROADMAP.md:292`). The two make-or-break battles are respected: latency measured
(S1/S2) and the engine chosen for speed; injection untouched (C4). **Transcript never
lost:** M4 carries the C1 completeness count into the transcript — the invariant's next
link, closed as far as C2 can close it.

---

## 9. Self-critique (per `prd-generator` Workflow 1)

Run against this document before the review gate. Recorded rather than resolved, because
resolving them is a scope decision for the founder.

| Dimension | Score |
|---|---|
| Problem definition | 🟢 — three-part (seam, model lifecycle, completeness gap), each evidence-cited |
| User understanding | 🟡 — the only user at C2 is the founder; ICP validation is structurally impossible until the loop runs (same caveat as C1's G2) |
| Success metrics | 🟡 — WER numbers provisional by decision; the CI runtime budget is now a number (§2); warm-transcribe is recorded-not-gated per P0, correctly |
| Scope clarity | 🟢 — must/should/nice explicit; C3's settings tension correctly pushed out |
| Edge cases & risks | 🟢 — eight risks with mitigations; the CI-VM bet (C2-A) is named |
| Stakeholder alignment | 🟡 — M16/M17 amend authoritative docs; reviewer now named (aliz), but the ARCHITECTURE I2 amendment ("the first named network type") has downstream blast radius into C6's interposer design — worth a deliberate sign-off, not a byproduct |
| Feasibility signal | 🔴 — **no effort estimate, 17 must-haves**; this is plausibly 2–4 weeks solo (R10 materialising, the same flag C1's G1 raised for 37 must-haves) |
| Scope & layer fit | 🟢 |

**🔴 F1 — 17 must-haves is not one week, and one of them is a bet on unverified runner
behavior.** M13 (the CI fixture-suite gate) presupposes that a macos-15 GitHub runner can
compile the FluidAudio model graph and transcribe acceptably with no ANE. Nobody has
measured that; the repo's own lesson is that "milliseconds" estimates were wrong by two
orders of magnitude. **Fix: the plan's first task is a spike** — add FluidAudio to a scratch
package, download the model on a runner, transcribe one fixture, time it — *before* the CI
job design is committed. The plan sequences it as Phase 0 with a stop/go decision; the
SMOKE_CHECKLIST fallback is the documented no-go outcome.

**🟡 F2 — fixture recording is a human task with no owner in the plan.** The five fixtures
come from the founder's own voice (founding decision); that is a manual recording session
(the 60 s read is ~150 words) plus golden-transcript transcription. The plan must list it
as an explicit early task (or parallel task), not an assumed asset.

**🟡 F3 — the downloader's skip semantics stop at an error enum.** M8's "Skip leaves the
engine unavailable with a clear reason" is testable in the downloader, but *what the user
sees* is the widget aspect's, which does not exist yet. The PRD names the requirement
(C2-F) and stops; the plan should record that the hand-over message is the widget aspect's
first task after C2 merges.

### The question to answer before greenlighting

**If the macos-15 runner cannot run Parakeet at all — model compile failure, memory limit,
or a transcription time that breaks the 12-minute budget — does C2's acceptance move to
founder-hardware with CI running only the seam tests, and is that acceptable *now*, or only
after the spike proves it necessary?** The PRD's answer is "spike first, decide with data";
the founder's is the one that matters.
