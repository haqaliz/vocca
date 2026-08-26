#!/bin/bash
# Copyright 2026 The Vocca Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Runs `swift test` and fails the run unless it actually executed tests.
#
# WHY THIS EXISTS
#
# `swift test` exits 0 when it discovers nothing. Measured on this repository: renaming every
# `func testX` to `func checkX` — the shape of a careless refactor, not of sabotage — produces
#
#     Test Suite 'All tests' passed
#          Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds
#     swift test EXIT=0
#
# and every CI job goes green having measured nothing. The same happens if `.testTarget` is
# dropped from Package.swift, or if a `--filter` matches nothing.
#
# That matters more here than in most repositories, because *every* gate on this project is
# delivered by `swift test`: the zero-network invariant (a permanent release blocker), the module
# boundary lint, the licence-header lint, the entitlement set-equality check, and the build
# configuration detector. Without a floor under the test count there is no floor under any of them.
#
# The floor is the exact current count, ratcheted up in the same commit as every task that adds
# tests — fourteen times so far. That makes it a check against removing an individual test, not
# only wholesale disappearance of the suite: any drop below the floor, however small, fails CI and
# has to be a reviewed edit to this line rather than a silent loss. The cost is that every task
# must remember to raise it; the ledger below records each raise and why.
#
# Not overridable by an environment variable on purpose: a floor a caller can set to 0 is not a
# floor. Raising it as the suite grows is a deliberate edit to this line, visible in review.
#
# Usage: Scripts/test-with-floor.sh [extra swift test arguments...]
#   Environment (VOCCA_APP_BUNDLE, VOCCA_EXPECTED_CONFIGURATION, CI, ...) is inherited by
#   `swift test` unchanged, so this is a drop-in replacement for it in any context.

set -euo pipefail

# Deliberate, reviewed constant — not derived from the current run (see below for why). Raised to
# Deliberate, reviewed constant — not derived from the current run (see below for why). Raised to
# 717 by the merge of the C1 audio-capture branch into master: the C2/C3/C4 suite (623 on master)
# plus the capture suite the branch built on the same base (418 at its tip, 324 at the fork).
# The two ledgers below were written on their own branches and keep their own numbers — the first
# block's counts are the C1 branch's pre-merge totals, not project totals.
#
# The C1 audio-capture chain, newest first (branch totals, pre-merge):
# It was 426 by audio-capture phase 5, which added eight (434 at the branch tip — the floor line
# moves 725 → 733 in this commit). MicrophoneSourceTests drives the SessionAudioSource conformance
# over a fake graph and a real ring (and a real converter), which is what Phase 5's plan names as
# its RED, verbatim: a ring that refused samples hands over audio marked incomplete **and the
# number it carries equals the ring's refusedSampleCount** — at 16 kHz mono, and verbatim at
# 48 kHz stereo in the ring's own raw units; a ring that refused nothing hands over audio marked
# complete; and the cross-session negative case, which is why the conformance reads a per-session
# baseline at beginCapture (the ring's refusal counter is cumulative since creation, so a naive
# pass-through marks every later session incomplete after the first overrun). The remaining five:
# an empty press (a real session that captured nothing, complete), an engine that refuses to
# start (.unavailable, and no teardown is owed for an open that never happened), A8 at the seam
# boundary (one second at 48 kHz stereo arrives as exactly 16 000 mono frames — the count reads
# the rate off the data), the release-before-return obligation read off the fake graph's stop
# ledger, and a full session through the real machine — which is what makes the machine hold
# VoccaCore's own AudioBuffer and closes the C1→C2 completeness bridge (the outcome's audio
# carries missingSampleCount equal to the session's refusals).
# It was 418 by audio-capture phase 4, which added eight (426 at the branch tip, 725 on the merged
# tree — the floor line moves 717 → 725 in this commit). AudioBufferListInterleavingTests drives
# the channel policy with hand-built AudioBufferLists and reads the ring back: the deinterleaved
# two-buffer layout and the interleaved one-buffer layout (the two shapes CoreAudio produces), the
# null-mData skip with the accounting staying exact (a skipped buffer must not shorten the ring's
# count, and a refusal still counts the whole block), the oversized callback counted whole or not
# written at all, zero frames as a success, the declared channel count matching the samples at 1
# and 2 channels — the plan's "the one thing no test will catch", which this file exists to catch —
# and the clamp on a channel beyond the declared count. The sink block moved with them:
# `AudioBufferListInterleaver.receive` is now the AVAudioSinkNode block (the measured
# graph → node → block → graph leak is why), so the realtime declarations are receive + interleave
# and AudioCaptureGraph carries none.
# It was 388 by audio-capture phase 2 review round 2, which added four. The instructive one:
# 388 by audio-capture phase 2 review round 2, which added four. The instructive one:
# `convert(_:)` throws too, is called once per poll rather than once per session, and did **not**
# get the exception-safety treatment round 1 gave `finish(_:)` — so a test in the suite asserted a
# standard the code met in one place and not the other, which is this project's recurring shape.
# The rule now runs at every throwing entry point through one `discardStreamState()`.
# The second pins the premise the whole reset rests on and that nothing asserted: every sample handed
# in is either converted or counted — `output × channels + discarded == fed`, the analogue of the
# ring's `received + refused == sent`. Discarding a remainder is only defensible while it is smaller
# than a frame; unasserted, that bound was one edit away from trading contamination for silent
# truncation. The other two are an empty press (a real session that captures nothing) and
# `isHoldingAudio`, which is now computed from what is held rather than from whether convert ran —
# it reported a hazard for a pass-through that retains nothing, and each of its two terms was
# separately deletable with the suite green.
#
# It was 384 after audio-capture phase 2 review round 1, which added three — all of them one defect:
# **audio from one session reaching another session's transcript.** finish() cleaned up only after
# its flush succeeded, so a throw left the resampler's filter state and a partial frame in place for
# the next session to emit; and a session that ended any of the five ways that are not a normal
# key-up never called finish() at all, with no other way to reset. Both are silent — nothing
# downstream can tell contaminated audio from long audio. The cleanup is now in a `defer`, and
# beginSession() anchors the reset at the one point in a session's life that cannot be skipped.
# The third test drives the drain's iteration ceiling, which pins that the two drain constants
# multiply out to 524 s of 16 kHz audio against the product's 120 s ceiling — a claim the previous
# comment made without ever crossing it.
#
# It was 381 after audio-capture phase 2, which added eighteen: the format conversion to the 16 kHz
# mono interchange format (A2, A8), the downmix, the streaming and session-reuse behaviour, and a
# lint bounding which files in Sources/ may name AVFoundation.
#
# Raised to 363 by audio-capture phase 1 review round 2, which added two and closed a blocker.
#
# THE BLOCKER, because it is the one worth reading twice: a `// @realtime` marker above a **closure**
# resolved to the next `func` below it. Measured — a marker over a closure containing
# `[Float](repeating:count:)` and `print(...)`, sited above `write`'s own marker, passed the entire
# 361-test suite: both markers produced the same qualified name, `Set` collapsed them to one element,
# the set-equality assertion that is the compensating control was satisfied, all four passes ran over
# `write`'s body twice, and the allocating closure was read by nothing. **That is the exact shape
# `AVAudioSinkNode` requires and the shape phase 4 writes next**, so acceptance A3 — "the realtime
# block allocates nothing, asserted by a source lint" — would have been blind to the only realtime
# block that matters, in a file CI never executes. A marker must now sit directly above a `func`,
# with only attributes and declaration modifiers between; anything else is a hard error. The plan
# tells phase 4 to pass a named function to the sink node, and why `[` must not be deleted to get
# past the second rule.
#
# The other test is claim 2 of the @unchecked Sendable comment, checked instead of counted: no
# read-modify-write spelling anywhere in AudioRingBuffer.swift, and exactly three stores to atomics.
# It was enforced only on the realtime body, so an RMW on a cursor in the *consumer* survived the
# whole suite — behaviourally identical under one writer, and a falsification of a claim asserted as
# checkable, which is what the warrant for the codebase's only @unchecked Sendable cannot afford. The
# same edit also fixes a comment that told the reader to count `.store(` and gave the answer three;
# the grep says four, because the sentence counted itself.
#
# Two more mutations died without needing a new test: `room` — extracted the round before and left
# unlinted, where an allocation and a `print` passed everything — is now marked `// @realtime` and in
# `expectedRealtimeDeclarations`; and pass 4 now splits on `;`, closing its own bypass in the round
# after it was added (`let probe = count; Self.sidecar.total = probe` clears every earlier pass and
# cleared pass 4 because the *line* began with `let`).
#
# It was 361 after audio-capture phase 1 review round 1, which added seven. Four of them are a fourth pass in
# RealtimeSafetyTests and its controls: three planted constructs — a subscript on a stored array, a
# compound assignment on a captured object's property, and `scratch[0] = samples[0]` — survived all
# three existing passes, and the last of those is what a sink-node block is most likely to reach for
# in phase 4. The lint now also refuses `[` outright, and its header no longer reads as though the
# passes between them see everything: a permitted call *name* on a different receiver is outside
# what any text lint can reach, and that is now stated rather than implied.
#
# The other three close mutations that survived review's battery. `isValidCapacity` makes the
# power-of-two rule a testable function, because a `precondition` cannot be caught in-process and so
# both capacity checks were satisfiable by any predicate at all. A source lint pins that
# `AudioRingBuffer.deinit` calls `deallocate()`, because deleting it leaks ~23 MB per session with
# every runtime test green. And `room(capacity:write:read:)` exists so that the producer's occupancy
# arithmetic can be called with *inverted* cursors: the trapping `Int(write &- read)` it replaced is
# a `Fatal error` inside a CoreAudio callback — a dead microphone mid-sentence — and reverting to it
# is invisible to every test that goes through the API, because the trap only fires once the SPSC
# discipline is already violated. That is exactly the discipline `@unchecked Sendable` leaves
# unenforced, so it is not a state "the API cannot reach" in any sense that helps.
#
# It was 354 after audio-capture phase 1, the SPSC ring buffer the realtime thread writes into.
#
# The two that justify the raise on their own are AudioRingBufferTests'
# `testASingleProducerAndSingleConsumerNeverLoseReorderOrDuplicateASample` and
# `testUnderContentionEveryProducedSampleIsEitherReceivedOrCounted`. They drive two *real* threads
# through thousands of blocks of varying size — a hand-driven interleaving asks the hardware to
# reorder nothing — and the second pins the overrun accounting exactly: received + refused == sent,
# because the refusal counter is the only record a consumer has that the audio it holds is short.
# Scripts/test-under-tsan.sh runs both under ThreadSanitizer; read its header for what that does and
# does not prove.
#
# One of the twenty is there because a mutation battery of eighteen found it held by nothing:
# advancing the read cursor by the *requested* count rather than by what was taken drives the read
# cursor past the write cursor, `write &- read` underflows to an occupancy of about eighteen
# quintillion samples, and the ring then reports itself permanently full while the session records
# silence. The return value is identical either way and `drain()` never over-asks, so the original
# test could not see it. Of the eighteen, seventeen die; the survivor is weakening a memory
# ordering, which nothing automated in this repository can catch — see the note in
# AudioRingBuffer.swift, which says so rather than implying otherwise.
#
# RealtimeSafetyTests is acceptance A3, and it was three passes at that raise (a fourth arrived the
# round after) because each is blind to what the others see: an allow-list over call names cannot see
# `Task { … }` (no parentheses, so no call token), and neither identifier pass can see
# `[Float](repeating:count:)` or a string interpolation. Most of its tests are positive controls that
# watch each pass reject the shape it exists to reject, because nothing in CI ever executes the
# realtime block — `AVAudioSinkNode` is unsupported in manual rendering mode — so the lint is the
# only check there is.
#
# It was 317 after hotkey-source phase 6, which detects Secure Input. Of the ten tests it adds, the ones that
# justify the raise are `testSecureInputIsReportedAsBlockedAndNothingIsDoneToTheTap` and
# `testAPasswordFieldFocusedForTwoMinutesCostsNoTapWorkAndTwoLogLines` — a state that no test could
# reach before, because `IsSecureEventInputEnabled` is set by other people's software and a test
# cannot switch it on — and `testASessionSurvivingIntoSecureInputIsClosedByTheNextPollInBothModes`,
# which is the hot mic behind it: a tap that is enabled and receiving nothing has no key-up, no
# second press and no `flagsChanged` left to end a session with. Plus
# `testASessionStartingAfterTheTransitionPollIsStillClosed`, which measures the fifth instance of
# this project's recurring defect shape before it could ship: throttling the *ending* to the
# transition the way the log line is throttled leaves a session that started one poll later running
# to the 120 s ceiling, in both modes, with the whole suite green.

# The C2/C3/C4 chain, newest first (master totals):
# It was 815 by the dictation-loop widget-live-states Task 4, which added seven in
# MicrophoneLevelTests: the real `LiveLevelSource` conformance driven through the REAL interleaver
# (the callback body ships the peak accounting; the fake seam's `levelPeak` forwards the
# interleaver's atomic, and frames are fed as hand-built AudioBufferLists — the
# AudioBufferListInterleavingTests shape). The ones that justify the raise are
# `testThePublishedLevelTracksTheNewestCallbackNotALifetimeMaximum` (the level must fall when the
# voice falls — a lifetime maximum would hold yesterday's shout over today's whisper),
# `testTheLevelIsZeroWhileTheGraphIsStopped` (the seam's "decaying to 0 when stopped" half: a
# session that ends must not leave a ghost level for the waveform to draw) and
# `testEachSessionPublishesItsOwnPeakAndStoppingReturnsToSilence` (which is what grew the graph's
# stop() into engine-stop-plus-level-reset — the fresh-session-starts-silent contract, pinned
# through the fake that mirrors `AudioCaptureGraph.stop()`). The accounting itself is table-tested
# directly (`testThePeakAccountingTracksTheGreatestAmplitudeIgnoringSign` and the silence/range
# rows), and the realtime body it ships in is linted by RealtimeSafetyTests as a reviewed
# declaration (`MicrophoneLevelSource.swift: peak`, with `UnsafeBufferPointer` and `reduce` added
# to the permit list — a two-word non-owning view and the allocation-free standard fold). The
# floor moves 815 → 822.
# It was 808 by the dictation-loop widget-live-states Task 3, which added seven in
# WidgetCopyTests: the live widget's copy — every user-visible string rendered from the reducer's
# structured state, pinned to the spec with no AppKit anywhere near it (the views themselves are
# window-server glue executed by nothing in CI, so this file is the tested half). The ones that
# justify the raise are the target-indicator pair (`testTheOpeningLabelNamesTheTarget` and
# `testTheDeliveredLabelConfirmsTheTarget` — the PRODUCT_SPEC.md:70 "→ Slack" label must never
# dangle: the router folds OPENING with an empty name before the resolution lands, so an unresolved
# name renders nothing rather than "→ "), `testTheElapsedTimerFormatsAsMinutesAndSeconds` (the
# display ticks once per second, `0:04`-style, off the reducer's whole-second reading),
# `testTheEscapeHintIsTheSpecsCancelInstruction` (`esc to cancel`, `:129` verbatim — the obvious
# way out of a dictation the user has thought better of), and
# `testTheCeilingWarningCopyIsPresentAndDoesNotNameANumber` (the threshold is derived from the
# *configured* ceiling, so the copy must never hard-code the shipped 120 s). The floor moves
# 808 → 815.
# It was 798 by the dictation-loop loop-wiring Task 5, which added ten: four in
# WidgetStateStoreTests (the store fold over the closed event set — the recording timer's fires
# advance the display at the injected clock's cadence with the 2 s / 3 s surfaces appearing at
# exactly `WidgetTiming`'s constants, the DELIVERED collapse landing at exactly the 600 ms
# deadline, and the out-of-state timer no-ops) and six in DictationLoopTests (the toggle
# configuration through the root: press → runs → `.toggledOff`, the ceiling through the toggle
# timer, the `.tapDisabled` route, the mode switch moving the tap's route with the default
# hold-to-talk, the display-name resolution feeding the DELIVERED confirmation, and the widget
# clock collapsing the confirmation and stopping). The floor moves 798 → 808.
# It was 791 by the dictation-loop loop-wiring Task 4, which added seven in DictationLoopTests:
# the composed-loop acceptance driven through the real composition root (DictationLoopRoot) over
# fakes — the R8-1 100-cycle run (100 started, 100 ended, 0 overlapping, 0 orphaned, 100
# transcripts delivered into the key-down context, asserted against the fakes' ledgers rather
# than against anything the root claims), and the four failure injections the spec names
# (engine throws → .transcriptionFailed surface with the injector untouched; ladder exhausts →
# the held transcript presented on the panel; an empty buffer → no injector call; a cancelled
# session → no injector call), plus the readiness gate (`testAnUnpreparedEngineRefusesBeforeTheMicrophoneOpens`,
# which pins "the mic never opens" on the source's own begin-count and that the refusal is not a
# dead hotkey) and the arm contract (`testTheRootArmsTheTapAndStartsTheHealthPoll`, the
# `TapHealthTimer` root-ownership obligation). The floor moves 791 → 798.
# It was 768 after widget-live-states Task 2, which adds the widget reducer and the waveform
# mapping in VoccaUI — twenty-one tests (thirteen in WidgetStateReducerTests, eight in
# WaveformMappingTests), raising the floor to 791. The ones that justify the raise are
# `testDeliveredCollapsesToIdleExactlyAtSixHundredMilliseconds` and
# `testNoTimeBasedTransitionWithoutAClockEvent` (the injected-clock pair: the DELIVERED→IDLE
# collapse lands at exactly 600 ms of the fold's clock, and a fold with no clock event can be
# handed any time without moving the state — the structural pin that the widget has no hidden
# timers), `testTheCeilingWarningTracksTheConfiguredCeiling` (the warning is derived via
# `WatchdogPolicy.warningThreshold(before:)`, never hard-coded — a configured 60 s ceiling must
# warn at 50 s, the `SessionWatchdog.swift:118-128` doctrine enforced from the UI side), and
# `testTheClosedEventSetFoldsFromEveryState` (the closed action set from every state, asserting
# the bookkeeping invariants — the time anchors exist exactly while their states do — so a fold
# can never leave the widget claiming a session it no longer has).
# It was 757 before widget-live-states Task 1, which adds the widget projection and the
# live-level seam in VoccaCore — eleven tests in WidgetProjectionTests, raising the floor to
# 768. The ones that justify the raise are `testEveryMachineEffectMapsToExactlyOneResult` and
# `testRecordingNeverComesFromANonRecordingSignal` (the aspect's load-bearing pair: `.recording`
# must appear in the closed effect table exactly once, from `SessionEffect.started` — the
# machine's own recording signal, produced in exactly one place, `SessionMachine.openTheMicrophone()`
# at `SessionMachine.swift:596-603` — so a waveform can never be claimed over a dead mic), and
# `testTheLevelSourceSeamIsSendable` (the `LiveLevelSource` seam pinned at compile time by
# capturing the existential in a `@Sendable` closure — the read the widget's refresh makes, so a
# conformance that stops being Sendable stops building the test).
# It was 757 by the dictation-loop loop-wiring Task 3, which added two in
# TargetResolutionSurfaceTests: the composition root's construction surface for target
# resolution, pinned from OUTSIDE the module — the file imports VoccaInject without @testable,
# so the recipe `TargetResolution(focusedApp: AXSource(), secureInput: SystemSecureInputRead())`
# fails to compile the moment either adapter drops back to internal, and the is-checks pin that
# the type-erased values the resolver receives are the shipped adapters. The semantics half runs
# the same recipe over the seam fakes (per-file private actors, the AccessibilityRungTests norm)
# and proves one resolution yields bundleID, windowTitle and isSecureInput — the three facts
# the ladder's decision reads. Access-level changes only: AXSource and SystemSecureInputRead
# became public with public inits and public protocol witnesses; zero decisions moved and the
# H7-style seam tables are untouched (same one file per family).
# It was 751 by the dictation-loop loop-wiring Task 2, which added six in
# DictationEngineResolverTests: the engine lifecycle — the builder runs exactly once across
# repeated prepares with the resolver's own selection, and the readiness gate answers the *same*
# engine it resolved (identity-of-cast, since ASREngine is not class-bound); a non-default
# selection arrives at the builder intact; two concurrent prepares are single-flight (the first
# parked inside the engine's prepare at a gate — the ModelStore proof shape — the parked count
# stays one and the builder does not re-run, and both callers complete when the gate opens);
# readiness flips only after prepare succeeds; a prepare failure surfaces its reason intact and
# keeps engineIfReady() nil; and a failure does not poison the next attempt — the retry re-warms
# the same engine (prepare twice, builder once) and readiness opens.
# It was 742 by the dictation-loop loop-wiring Task 1, which added nine in
# DictationPipelineTests: the pipeline's whole decision table over the closed set — the cancelled
# outcome discards even while carrying audio (no transcribe, no inject, no holder touch — Esc is
# an instruction, not the pipeline forgetting), the empty captured buffer is decided empty before
# the engine is asked (the empty-buffer policy makes samples.isEmpty and text == "" the same
# fact, `ASREngine.swift:28-32`), the engine's own empty answer for non-empty audio never reaches
# the injector (no paste of ""), the happy path transcribes once and injects into the exact
# key-down context, every delivery rung ends idle with the holder untouched (over the closed
# InjectionRung set), `.widgetFailsafe` surfaces the handoff's held transcript after reading the
# holder exactly once — never holding or releasing — plus the residual row (a failsafe with
# nothing held surfaces .exhausted rather than a silent idle), the transcribe-throw row
# (.reasonOnly(.transcriptionFailed), nothing injected, nothing held), and the four non-ended
# effects routing to idle touching nothing. StubEngine gained a transcribeCalls ledger beside its
# prepareCount so the skip rows assert on a counter.
# It was 737 by the dictation-loop failure-surfaces Task 2, which added five in
# FailsafeStateReducerTests: the reason-only state's decision table over the closed action set —
# .reasonShown presents the newest reason from hidden and from every presented state, ⌘C/⏎ are
# no-ops (no text is held to copy or re-run), and the fold of every action from .reasonOnly lands
# in exactly {reasonOnly, hidden} with dismissRequested the only exit — never-auto-dismiss for
# the new state is structural, not policed. The same commit grew FailsafeCopy.affordancesLine(for:)
# to render an empty legend for the reason-only state (PRD R5).
# It was 733 by the dictation-loop failure-surfaces Task 1, which added four in FailsafeReasonTests:
# the two voice-processing reasons (PRD R5) round-trip through the recovery journal over the REAL
# FileSystemJournalStore — the reason field is persisted as its raw spelling, so only a real JSON
# encode→decode proves the spelling survives the schema — and each reason's copy renders the PRD
# sentence verbatim, non-empty, with no ⌘C/⏎ ladder affordance in it (no held text exists to copy).
# It was 405 by the local-asr download-ui: 405 by the local-asr download-ui: the three session-adapter tests in ModelDownloadSessionTests
# (the seam's happy path ends .committed with monotonic progress, a failure ends .failed with the
# cause and no presence, and a skip ends .cancelled with the .part surviving — the resume
# assertion proves the skip is a pause, not a discard) and the five reducer tests in
# DownloadStateReducerTests (the window's whole decision table, headless: clamping, terminal
# states, cancelled-reads-as-skipped). The window itself is glue executed by nothing in CI,
# which is exactly why the reducer is this thorough.
# It was 397 by the local-asr fixture-suite Phases 2-3: the four harness tests in ASRFixtureHarnessTests
# (the parameterized evaluate body proven end-to-end with stubs — the imperfect stub's WER must
# equal the scorer's direct arithmetic, which is the plumbing proof that needs no model) and the
# env-gated real-engine test in ParakeetEngineWERTests, which skips visibly without
# VOCCA_MODEL_DIR and is the C2 acceptance's real-number half where it runs. The real run on
# founder hardware passed all provisional tolerances on the first attempt (15.4 s for prepare +
# six fixtures, word-perfect on the clean clips).
# It was 392 by the local-asr fixture-suite Phase 1, which adds the WER scorer: the seven table-driven
# tests in WERTests. The ones that justify the raise are `testOneSubstitutionScoresOneOverReferenceLength`
# and `testDeletionsAndInsertionsScoreOneEach` (the score the P0 gate is judged on, pinned per
# edit class), `testTheEmptyReferenceRule` (the degenerate case must be defined, not a crash),
# and `testTheImperfectStubShapeScoresExactly` — the exact arithmetic the harness test asserts
# end-to-end through a real engine seam.
# It was 385 by the local-asr parakeet-engine Phase 3, which adds the adapter behind the seam: the three
# tests in ParakeetSeamTests that pin the H8b SDK confinement. The one that justifies the raise is
# `testExactlyOneFileInSourcesMayNameTheFluidAudioFamily` — the same shape as H7/H8, with the
# egress half of the family (`ModelHub`) explicitly in the prefix list: naming it outside the
# adapter would be the network decision escaping the one file that must hold it. The negative
# control proves the detector can fail, and the comment-strip test keeps the adapter's own
# documentation legal.
# It was 382 by the local-asr parakeet-engine Phase 2, which adds the engine's testable core: the eight
# tests in ParakeetCoreTests. The ones that justify the raise are `testTheMapperProducesOneSegmentedTranscriptAttributedToTheEngine`
# (attribution and duration-from-buffer pinned as pure rules — the adapter's transcription path
# contains no other decisions), `testLoadStateRetriesAfterAFailure` (a failed load must not mark
# loaded, or a skipped download would permanently dead-end prepare), and the timing tests (the PRD
# S1 ledger, read by C7). Every test runs headless with no model and no SDK: the core is the
# reachable side of the adapter, exactly as the H7 lesson demands.
# It was 374 by the local-asr parakeet-engine Phase 1, which shapes the model store for the SDK's repo
# layout (spike finding `spike_20260809.md` §4.1): the six tests across ModelManifestTests,
# ModelStoreTests and ModelDownloaderTests that pin `sdkDirectory` + nested names. The ones that
# justify the raise are `testNestedPartFileKeepsPresenceFalseEvenBesideTheMarker` (the "a .part
# anywhere" promise must survive nesting — a non-recursive scan would have read a half-downloaded
# SDK-shaped version as present) and `testAnSDKDirectoryManifestCommitsUnderTheDirectoryWithTheMarkerAtTheVersionRoot`
# (the layout the engine's `load(from:)` call resolves to, pinned recursively). The traversal
# rejection tests matter because a manifest name becomes a filesystem path: `../evil.bin` must
# fail at decode, where the shape failures are caught, not at write time.
# It was 368 by the local-asr spike's lint fix, which lets the licence header lint skip `.build`
# directories: `Tools/ASRSpike` is the first Tools package with a Package.swift, so its FluidAudio
# checkout (a third-party tree that carries no Vocca header) lives under the scanned `Tools/`
# directory. The skip is a reviewed rule, not an afterthought — the test that justifies the raise
# is `testABuildDirectoryIsSkippedButAHeaderlessFileIsStillCaught`, which pins the rule in both
# directions: a headerless file under `.build` is ignored, a headerless file outside it is still
# caught, and a properly headed file still passes.
# It was 367 by the local-asr model-downloader Phase 3, which adds the H8 network-confinement lint: the
# three tests in ModelDownloaderSeamTests. The one that justifies the raise is
# `testExactlyOneFileInSourcesMayNameURLSession` — the zero-network claim's enforcement, in the
# same shape as H7: a wrong code path that opens a socket anywhere in Sources/ fails this test,
# not an audit. The negative control (`testTheLintDetectsAPlantedURLSession`) makes the detector
# provably able to fail, and the doc-comment test pins that comments are stripped before the scan
# (ModelTransport's own documentation names URLSession on purpose).
# It was 364 by the local-asr model-downloader Phase 2, which adds the downloader: the seven tests in
# ModelDownloaderTests that pin every download decision above the transport seam. The ones that
# justify the raise are `testAFailedTransferResumesFromThePartialFileOnTheNextRun` and
# `testCancellationPreservesThePartialFileAndTheNextRunResumes` (a dead or cancelled transfer must
# leave the model re-downloadable from zero never — the .part is the resume anchor, and the second
# run's recorded Range must start exactly at the partial size), `testAResumeRefusingTransportRestartsOnceAndCommits`
# (a transport that ignores Range would silently assemble a misaligned file; the size check must
# catch it and the committed bytes must equal the source exactly), and
# `testCorruptBytesRestartFromZeroAndExhaustTheRetryLimit` (wrong bytes are discarded and fetched
# from zero, never resumed — and the retry ledger [0, 0, 0] proves it). The store's own contract —
# `ModelStoreError.checksumMismatch` surfaced from exhausted retries — is pinned by the mapping
# test, so the Phase 1 contract and the Phase 2 vocabulary both hold.
# It was 357 by the local-asr model-downloader Phase 1, which adds the manifest and the verified-presence
# store: the nine tests in ModelManifestTests and the eight in ModelStoreTests, written red and run
# red before any of it existed. The ones that justify the raise are the store tests, because they
# test the store's contract as *observable behaviour over the real seam* rather than as assertions
# on an implementation: `testIsPresentFlipsTrueOnlyAfterEveryFileIsVerifiedAndCommitted` parks the
# store inside the stub transport's async gate at both stages of a two-file manifest and reads the
# store while it is suspended — the first verified file sits in a `.part` awaiting commit and
# presence must still be false, which is the atomic-commit claim in the only form it can be
# observed; `testTwoConcurrentDownloadsAreSingleFlight` submits two calls while the first is parked
# in the gate, so a store without the one-flight guard starts a second download before the
# assertion ever runs; and `testACommittedVersionDirectoryIsImmutableAgainstASecondDownload`
# compares the committed directory byte-for-byte and mtime-for-mtime across a second call
# (PRODUCT_SPEC.md:273). In ModelManifestTests, `testUnknownTopLevelJSONFieldsAreRejected` and
# `testAnUnknownFieldInsideAFileEntryAreRejected` pin the unknown-field scan to the exact mechanism
# that works on this SDK: a keyed container typed with a fixed CodingKeys enum drops unknown keys
# before `allKeys` can see them (measured with a probe before the fix), so the scan goes through a
# wildcard key type — without that, unknown fields silently decode as nothing and the trust anchor
# is a registry that does not check.
# It was 340 after local-asr asr-seam Phase 2, which adds the ASREngine seam: the six tests in
# ASREngineSeamTests that pin the protocol ARCHITECTURE.md:219-229 specifies before any real engine
# exists. The ones that justify the raise are `testAStubWithoutStreamStillSatisfiesTheProtocol` and
# `testTheBatchDefaultBuffersThreeChunksIntoOneFinalTranscript` (streaming optional-with-default in
# its compile-time and runtime halves — the moment the batch default disappears, StubEngine stops
# conforming and the file stops building, and the runtime half pins "exactly one final transcript"
# so a caller never branches on supportsStreaming), and `testAttributionIsTheStubsOwnIdentityAndDiffersAcrossEngines`,
# the C2 acceptance's identity clause and the C3 swap test's seed: a transcript credited to the
# wrong engine is the "which model said this?" lie downstream code cannot detect once it has a
# Transcript in hand. `testEmptyBufferTranscribesToAValidEmptyTranscript` pins the empty-buffer
# policy (PRD M3) — silence is a transcript, never an error, because a 20 ms press is a legitimate
# C1 answer.
# It was 334 after local-asr asr-seam Phase 1, which adds the ASR vocabulary: the ten tests in
# ASRVocabularyTests that pin the types ARCHITECTURE.md §4 names before any engine exists. The ones
# that justify the raise are `testEngineIdentityIsHashableAndCodable` (the C8 directory key and the
# C14 persistence contract are both forward contracts, so a collapse or a dropped field would fail
# here years early), `testTheFormatPredicateRejectsEveryNearMiss` (the trapping init's rule made
# testable on its own — a precondition cannot be caught in-process, so any predicate at all
# satisfied the first version of such a check), and `testTranscriptRequiresAndCarriesItsEngine`,
# which pins attribution (I1) at compile time rather than by assertion: the annotated `EngineIdentity`
# binding stops compiling the day the field is weakened to optional, the same pin
# SessionVocabularyTests applies to the custody payload.
# It was 307 after hotkey-source phase 5 review round 1, whose Critical finding was that
# `TapHealthTimer.disarm()`'s forward to the policy was held by NO test: reducing it to `timer.stop()`
# alone passed the whole 306-test suite, and so did a `disarm()` that forwarded to `policy.arm()` — a
# build in which disarming Vocca RE-CREATES the tap and leaves the microphone open. Only the clock
# half was pinned, by a test that never pressed a key.
# It was 306 after hotkey-source phase 5, which wired the two timers and measured the two hazards two aspects
# had carried as unverified. Of the 39 tests it added, the ones that justify the raise are:
# `MainRunLoopTimerTests`, which measures the H10 run-loop-mode hazard rather than asserting it — a
# timer in `.default` mode delivered 0 of 33 fires through a gesture, and the shipped `.common` one
# delivered all 33; `ScheduledWatchdogTests.testAnAutorepeatTrainDoesNotRestartTheTimer`, which pins
# the one-line defect that would make the 120 s ceiling unreachable for every hold-to-talk session;
# and `OwnershipGraphTests`, which closes the four sole-owner edges phase 4's review measured as held
# by **no test at all** — each of `TapHealthPolicy.source`, `TapHealthPolicy.sink`,
# `SessionWatchdog.machine` and `SessionEventSink.watchdog` could be made `unowned` with the whole
# 267-test suite green.
#
# It was 267 after hotkey-source phase 4 review round 1, whose blocking-shaped finding was **a test
# that named the exact mutant it existed to kill and did not kill it.**
# `testTheDeferredRecoveryStillRunsIfTheObserverIsReleasedFirst` had a doc comment saying a
# `[weak policy]` capture in the deferred block *"would do exactly that, silently, on a path no other
# test in this package visits"* — and that mutation passed all 266 tests. The defect was in the test's
# **ownership graph**, not its assertions: the harness held `let policy`, so releasing the observer
# left the policy alive and the recovery ran whatever the capture list said. Production is
# `root → observer → policy → source ─weak→ observer`, where the observer is the policy's only strong
# owner. Rewritten to build that graph by hand with no strong handle on the policy, plus a weak
# liveness probe asserted *before* the queue is drained — the load-bearing line, because without it the
# test is satisfiable by any harness that retains the policy some other way. The mutation now fails on
# three assertions.
#
# **The general lesson, carried into phase 5: a harness that owns more than production does cannot
# reproduce a lifetime bug, however precisely its comment describes one.**
#
# The second test added this round kills the other survivor: a fourth entry in the classifier's table
# at event type 65 claimed a key event the mask never requested, because Swift's `<<` yields 0 on an
# over-shift rather than trapping, and every existing guard stopped at 64.
#
# Also corrected this round, and it is why this ledger is worth reading rather than skimming: **the
# stated cost of dropping `flagsChanged` from the mask was false**, in five places including this
# header and the phase-4 commit message. It does not produce "a hot mic to the ceiling, every time".
# `SessionRules.swift` puts `.keyDown` and `.flagsChanged` on one branch and ends on a matching
# `.keyUp` without consulting modifiers at all, so the session still ends — at the next autorepeat or
# at key-up, never later than the finger. The real cost is the *immediacy* of stop rule (b) and the
# ability to add a modifier-only binding. The bit stays; the justification is now the true one.
#
# It was 266 after hotkey-source phase 4, **the only phase of this aspect whose own code CI cannot execute a
# line of.** `CGEvent.tapCreate` returns `nil` without an Accessibility grant and TCC cannot be
# granted on a hosted runner, so `CGEventTapSource.swift` is untestable forever rather than untested
# for now. Twenty-nine tests were added anyway, and the reason there are any is the point of the
# phase: everything with a branch in it was kept *out* of that file. What is left there is four
# system calls, four optional guards and one `switch` that turns an `EventPropagation` into a C
# return value.
#
# Ten of them are the transcription check for the tap's second table of magic numbers
# (`TapEventClassification`). `CGEventType`'s raw values are written out by hand there, as
# `CGEventFlags`' are in the flag translation, so that no seam type reaches a file that is not the
# adapter — and a test may import CoreGraphics where `Sources/` may not, which turns a transcription
# error into a red suite. The load-bearing one is the mask, whose every failure mode is silent: too
# narrow costs stop rule (b)'s immediacy, and too wide costs the permission check itself, because
# `tapCreate` returns NULL only when the cleared keyboard bits leave the mask empty. The mask and the
# classifier are built from one table and a test walks all 64 bits requiring them to agree.
#
# Nine are the callback's own body, lifted into `TapEventDispatch` so that it has somewhere to run.
# The load-bearing one is H6 in **both** directions at the last point before the C ABI: a dispatch
# that hard-coded a disposition leaves every session test in this package green and either types the
# hotkey into the user's document or eats their whole keyboard. The `fn` rule's application is pinned
# here too — the rule itself is exhaustively covered elsewhere, but *that this path applies it, to
# this event's key code* is a separate claim, and getting it wrong makes every arrow-key binding
# unfireable.
#
# Ten are decision A — **which half of a tap disablement happens on the tap's own callback.** Both
# `kCGEventTapDisabled…` notifications are delivered *to the callback*, and
# `TapHealthPolicy.tapWasDisabled(_:)` ends in a re-creation, which is a `stop()` that invalidates
# the `CFMachPort` whose callback is on the stack. Resolved by splitting it: the session ends
# synchronously, because a run-loop turn is not a bound on how long a microphone stays open, and the
# recovery is deferred whole. `CallbackSafeTapDisablement` is where that lives — above the seam,
# with the run loop injected — so a test can stand between the two halves and look. What is asserted
# there is that the microphone is closed and the tap untouched on the near side, that an equivalent
# immediate deferral produces the identical notes, outcome and tap state as calling the policy
# directly, and that a run loop which never turns costs the tap and never the microphone.
#
# It was 237 after hotkey-source phase 3 review round 4, which closed the *class* of defect the previous three
# rounds closed one instance at a time: **a guard justified by a claim about what cannot be in
# flight, false on a path the file already models.**
#
# The last instance was the poll's arming check, which returned above every ending. `disarm()` clears
# `isArmed` and *then* tears the tap down, and the teardown is where a queued key-down is delivered —
# so an unarmed policy really can hold a running session, and it is the state with the fewest ways out
# in this file: no tap, no key-up, in toggle no physical-key poll, and no reason for an owner that has
# just disarmed to still be running a timer. What was left under it was the 120 s ceiling.
#
# Two fixes, because the prescribed one-line fix is not sufficient on its own. The poll's guard moved
# below the ending, which is the backstop; and — since after a disarm there may be no further poll —
# the two operations that can leave the policy without a tap now **end again afterwards**. The rule in
# full is no longer "end first" but *"end before, and again after, if what is left cannot end it
# itself"*. That second ending is a real decision rather than a defensive line: a creation that
# *succeeds* must keep the session its teardown started, because there is a tap now and it will carry
# the key-up, and a test asserts exactly that.
#
# The sweep the review asked for found no further instances. Every early return in the class was
# checked; the only one that skips an ending is the poll's healthy branch, and it is safe for a reason
# that is not a claim about sessions at all — a delivering tap can carry the key-up, so the session
# has its ordinary way out.
#
# Also measured rather than claimed: the recovery rate limit bounds a *run of consecutive trouble*,
# not a minute. A flapping tap gets a recovery every time — 30 recoveries and 60 log lines a minute at
# one death every other poll — and that is deliberate, because the cost is proportional to something
# real and because tightening it would delay a genuinely new fault. The constant's doc now carries the
# table, pinned by a test so it cannot drift.
#
# Mutation: 23 applied this round, 23 killed — including the three that survived every previous round
# (an ending moved below the `isArmed` guard at `tapWasDisabled`, `systemDidWake` and
# `accessibilityGrantChanged`), which the new closed-set test kills together.
#
# It was 232 after hotkey-source phase 3 review round 3, whose blocking finding was a regression the previous
# round introduced while fixing a diagnostics problem: **the rate limit sat above the ending, and
# turned a one-second hot mic into a thirty-one-second one.**
#
# The guard was justified in a comment by "nothing should be in flight — every route that clears
# aTapExists ends the session first". That is false, and false on the exact hazard this repository
# added `duringStop` to model one round earlier: a key *down* queued behind a teardown, delivered
# from inside `stop()` while the sink is still attached, starts a session **after** the entry point's
# end and **before** the flag is cleared. Measured in both activation modes — no tap, and a recording
# session, with no key-up possible because there is no tap, and in toggle no physical-key poll either:
#
#     stranded: tap attached = false   microphone open = true   state = recording
#     polls (= seconds) of open microphone:  1   (was 31)
#
# The fix is the distinction the previous round failed to draw: **what is throttled is the recovery,
# and never the ending.** A rate limit exists to save system calls, and a microphone is not a system
# call. The ending now happens on every poll — one call into an idle state machine, which answers
# `.ignore`, costing no syscall and no log line — and only the note, the re-enable and the
# re-creation are gated.
#
# The bound also covers the branch it had missed. The poll has two ways to find persistent trouble;
# the first version gated "no tap" and left "a tap that exists and never delivers" reproducing the
# unbounded numbers **to the digit** (61 creates, 121 log lines a minute). Both are now bounded, and
# measured: 3 creates and 5 log lines a minute for the second, 3 and 3 for the first.
#
# And the first discovery is never delayed, which is the trap on the other side of a rate limit: a
# healthy poll re-arms the entitlement to recover at once, so a tap that dies five seconds after it
# was created — or one that dies, is recovered, works, and dies again — is handled on the very next
# poll. Only repetition is slowed. `TapHealth` gained a fourth case for the honest answer while
# throttled: `.notDelivering`, because `permissionMissing` there would send a user to System Settings
# to grant something they granted already.
#
# Mutation: 21 applied this round, 21 killed. The one that survived the first pass was the healthy-poll
# re-arm — my test for it could not fail, because healthy polls never decrement the counter, so the
# sequence had to become trouble → health → trouble before it measured anything.
#
# It was 227 after hotkey-source phase 3 review round 2, whose blocking finding was the previous round's own fix
# containing the next hole: **the ordering defect closed on `disarm` was open on `pollTapHealth`**,
# the entry point that round had just added to close a different gap. A key event queued behind the
# disablement and delivered from inside `CGEventTapEnable` ended the session as `.keyUp` — a release
# nobody made — because the poll reaches both recovery calls by its own route through
# `restoreDelivery()` and the four-leg ordering test covered neither. Two more legs; the answer was
# already in the file, unused (`RecoveryRoute.recoveredByPoll`).
#
# Two behaviours this round bounded rather than merely recorded. The poll retried `tapCreate` **once
# per second, forever, in the state every first run is in** — no Accessibility grant, which is also
# where a user who declines it stays. Measured at 61 creates and 121 log lines a minute, which
# destroys the diagnostic channel in exactly the state it most needs to be readable: eleven real
# re-creations are invisible in it. The retry is kept, because a grant notification can be dropped,
# and slowed to one attempt per 31 polls — measured at one create and one log line in the first
# minute. `.foundDeadByPoll` is no longer spent on it either: nothing died silently there, `arm()`
# said so loudly, and that note exists to mark the case worth knowing about.
#
# And the poll's claim is now bounded to what its one read can support. `CGEventTapIsEnabled` catches
# a tap **disabled** silently; it cannot catch one **enabled and deaf** — created successfully,
# reporting itself enabled, delivering nothing. That state is not hypothetical and this package
# asserts elsewhere that it exists: a mask cleared at creation before the grant (the reason
# `accessibilityGrantChanged()` re-creates rather than re-enables), and Secure Input. In toggle mode
# the uncaught shape is still a 120 s hot mic. A test measures the gap — 120 polls, a hot mic in both
# modes, a log with nothing to say — and it will fail when phase 6 closes it, which is how the limit
# moves on purpose rather than by nobody noticing.
#
# Mutation: 15 applied this round, 15 killed, including all three the re-review found live (the poll's
# ordering, its `aTapExists` half — which needed a source that violates the contract, since a
# conforming one can never reach the guard — and a failed re-arming logged as a first arming).
#
# It was 221 after hotkey-source phase 3 review round 1, which added eleven and fixed a Critical the review
# demonstrated: **the policy returned `.delivering` with no tap in existence.** After an `arm()` that
# found no Accessibility grant, a disable notification called `resumeDelivery()` anyway and believed
# the answer — so the return value said delivering, the health log said `.reenabled`, and every
# session afterwards started nothing. Both channels wrong in the same call, and it is the exact
# hazard the class's own `systemDidWake` doc names: healthy while deaf.
#
# The root cause was one flag doing two jobs. `isArmed` means *the owner wants a tap*, which survives
# a failed creation on purpose; there was no field for *a tap exists*, which does not. `aTapExists` is
# that field, written from one place — the single call to `start(delivering:)` — because two fields
# with four update sites would be the same defect with more places to hide. The fake now models the
# same truth (a tap that does not exist cannot be switched on) and the protocol states it, so the
# decision is above the seam in both halves rather than left for an adapter to invent.
#
# The other addition is a **~1 s health poll**, which `spec.md:57` puts in scope and which no phase of
# the plan had. It is the only thing that catches a tap dying with **no** notification of any kind —
# measured before it was built: armed, delivering, session in flight, tap dies silently, microphone
# open and machine `.recording` in *both* activation modes. In toggle that is a two-minute hot mic
# bounded only by the ceiling, because toggle has no physical-key poll behind it. The policy half is
# built here; phase 5 owns the timer.
#
# It is also the one entry point that does **not** end the session unconditionally, and the test that
# matters most about it asserts the opposite of its seven siblings: a poll runs once a second for as
# long as Vocca runs, so a poll applying the class's rule without thinking would cut every session off
# within a second of starting. Both directions are pinned.
#
# Mutation: 34 applied this round, 34 killed, including all four the review found live — the `disarm`
# ordering hole (a third source call that pumps the run loop, now with a `duringStop` hook, and the
# hook's own placement pinned so it cannot model nothing), the fake's redundant second copy of one
# decision (deleted, so there is one copy and deleting it fails four tests), and the two entry-point
# table mutants that left a method covered twice and another not at all (closed by requiring the eight
# cases to produce eight distinguishable health logs, which pins `invoke` against `name`).
#
# It was 210 after hotkey-source phase 3, which added twenty-seven in TapHealthPolicyTests: the policy for a
# dying event tap, decided over an injected tap handle with no CGEvent call anywhere in it.
#
# H3, H4 and H5 are one test each per branch — a disabled tap ends the in-flight session and is
# switched back on; a re-enable that does not take is followed by a re-creation; a tapCreate that
# returns nil leaves as "permission missing" and not as silence — but the test that matters most is
# the one phrased over a closed set: **every entry point ends an in-flight session**, driven over a
# `CaseIterable` of all six, asserted against the microphone's own ledger. A tap that died may have
# dropped the key-up, and the key-up is the only thing that would have ended the session, so a
# session that outlives its tap is a hot mic with the widget insisting it is closed.
#
# Eighteen mutations were applied and fifteen died. Three shaped the commit. The ordering mutation —
# ending the session *after* the recovery rather than before it — **survived the first pass**, and it
# survived honestly: nothing arrives during a recovery in a test double, so both orders produce the
# same log. What kills it is the hazard the real system has and the double did not: switching a tap
# back on runs through CoreFoundation, CoreFoundation pumps the run loop, and the key event queued
# behind the disablement is delivered right there. So `FakeHotkeyEventSource` grew `duringResume` and
# `duringStart` — the counterpart of the audio ledger's `duringEndCapture`, for the identical reason —
# and with a stale key-up arriving mid-recovery the two orders differ: ending first leaves it ignored
# by a session already over, and ending afterwards lets an event that came through a tap Vocca has
# just declared untrustworthy end the session under the *user's* name. A `.keyUp` in the log for a
# release nobody made, and the log is the only evidence anyone gets.
#
# Two are honestly equivalent and are recorded rather than claimed. (a) A re-creation that calls
# `stop()` itself before `start` is behaviourally identical, because `start` is documented to do that
# already; the objection is that it second-guesses a contract whose failure mode is a use-after-free,
# which is a design argument and not a testable one. (b) Gating the end on `isArmed` is equivalent —
# but only *because* `disarm()` ends the session too. The two are joined: pin one and the other
# becomes vacuous, so the mutation that removes the end from `disarm()` (killed, three tests) is what
# keeps this one equivalent rather than live.
#
# It was 183 after hotkey-source phase 2 review round 1, which added one in HotkeyEventSourceTests: a second
# `start(delivering:)` on an already-started source tears the first down rather than leaving two taps
# installed. That is the exact call the tap-health policy will make — its charter is "if re-enable
# fails, tear down and re-create", and re-creating is calling `start` again — and a source that
# merely overwrote its sink there would leak a CFMachPort and a run-loop source and leave a second
# tap whose callback still points at the previous context, which is a use-after-free on the next
# keystroke reached by a caller who did everything the protocol documents.
#
# The round's Important finding added no test — it replaced a mechanism. The re-export rule held a
# list of five frameworks named after what they are, and review broke it: `@_exported import AppKit`
# planted in the real tree left the suite green at 182/0, because AppKit re-exports CoreGraphics. The
# proposed fix was five more names. Probing the SDK before adopting them (`swiftc -swift-version 6
# -typecheck` over `import <F>` plus each forbidden type) showed the list was wrong in *both*
# directions: the proposal would have added CoreServices, which carries no CGEvent type at all, while
# still missing SwiftUI — the one import VoccaUI certainly will have — and Foundation, which carries
# CFMachPort, the tap handle itself. So the list is gone and the rule is now "a file in Sources/ may
# re-export Vocca's own modules and nothing else", which cannot go stale and costs nothing because it
# fires only on `@_exported`; every module may still `import AppKit` freely. Seven planted
# `@_exported` lines now fail the suite where three used to pass, and reverting the rule to either the
# original five-name list or the review's proposed ten-name list is caught by the control.
#
# It was 182 after hotkey-source phase 2, which added seventeen: eleven in HotkeyEventSourceTests for the
# HotkeyEventSource seam and the session driven through it, and six in HotkeySeamBoundaryTests
# hardening H7 against four further ways out of a text lint.
#
# The eleven are the C1 acceptance re-run over the seam the real tap will implement — 100 synthetic
# key-down/key-up pairs at 80 ms to 60 s, through a fake source into the shipped sink, watchdog and
# machine, with ~20,000 watchdog polls interleaved — plus **H6 pinned in both directions at the far
# end of the seam**. That last distinction is the point of the file: `SessionWatchdogTests` already
# pins propagation by reading the `SessionResponse` the watchdog returns, which is a claim about the
# machine's answer, not about the answer surviving the journey back out to the caller. A source that
# ignored the disposition it was handed passes every assertion phrased against the response and eats
# the user's whole keyboard anyway, so `applicationSaw` is built from what the *source returns* and
# every H6 assertion is made against it — with an always-swallowing and an always-passing sink run
# beside it as controls, because the merged aspect's suite was green at 119/119 with a hard-coded
# `.swallow` in the path.
#
# Twenty-seven mutations were applied and all twenty-seven died: the two hard-coded dispositions and
# the inversion (3, 10 and 10 failures), the effect dropped entirely, dropped only when swallowing,
# and dropped only for the outcome (3, 1, 3), the event never reaching the session (10), a stale
# disposition returned after driving it (5), the source ignoring its answer (10) or pre-filtering to
# the hotkey's key code (1), a stopped source swallowing rather than passing through (4), an
# unavailable start attaching the sink anyway (2), `stop()` not releasing it (1), the event forwarded
# with its modifiers stripped (10) or its autorepeat cleared (2), and six against the H7 lint. Two of
# them shaped this commit: a filter that never reported a violation survived in *both* new lint rules
# — the real-tree checks iterate an empty permitted list and a clean tree, so a predicate answering
# "never" left them green — which is why both are now named functions under a positive control. A
# third case added to `HotkeyEventSourceStart` and a `CGEvent` type planted in the seam both fail at
# compile time.
#
# One is honestly untestable and is recorded rather than claimed: a sink holding the `SessionMachine`
# directly instead of the `SessionWatchdog` is behaviourally identical, and the suite stays green.
# What stops it is the constructor signature — there is no way to build the sink without a watchdog —
# not a test.
#
# The six in HotkeySeamBoundaryTests close routes a reviewer would construct next. A `@_exported
# import CoreGraphics` contains no forbidden identifier at all, because the module is not called
# CGEvent, so it puts the whole family in scope wherever the re-exporting module is imported with
# nothing for the identifier scan to see. A conformance declared on a CoreGraphics type in the
# permitted file is the typealias hole wearing a protocol: `any TapHandle` then reaches it from
# anywhere in Sources/. A `typealias` nested inside a type launders exactly as completely as one at
# file scope. And the walk is now proven to reach a violation planted in a subdirectory — which found
# a real defect in the scan itself: relative paths were computed by string subtraction without
# resolving symlinks, so a root reached through one (every macOS temp dir, and any repository checked
# out under one) yields mangled paths and an allow-list that silently stops matching.
#
# It was 165 after hotkey-source phase 1 review round 1, which added three in HotkeySeamBoundaryTests: H7's
# "exactly one permitted file" claim, enforced rather than left in a comment; a prohibition on a
# typealias in that permitted file; and its positive control.
#
# The typealias rule is the one worth explaining. The H7 lint matches identifier text, so once the
# tap adapter is on the permitted list, `public typealias TapHandle = CFMachPort` declared *there*
# is invisible everywhere else in Sources/ — verified: the aliased use site scans clean. One alias
# in one permitted file would reopen H7 across the whole tree with the suite green. `CGKeyCode` and
# `CFRunLoop` joined the forbidden prefixes for the same reason: both carry the seam, and CGKeyCode
# looks harmless because it is only a UInt16 typealias.
#
# The round's Important finding added no test — it added two assertions to an existing one. The
# 30-count guard ran on the *array* while the set comparison ran on `Set(map(\.code))`, so a
# duplicated fixture row made the array 30 and the set 29, and an implementation missing kVK_F20
# passed 13/13 with F20 bindings silently dead. Reproduced exactly, then closed by asserting the
# de-duplicated cardinality of both the codes and the names. Same class as the controlBit superset
# mutation this phase set out to close — a cardinality guard over a container that admits duplicates
# — closed for the flag constants and missed for the key codes.
#
# It was 162 after hotkey-source phase 1, which added nineteen: thirteen in HotkeyFlagTranslationTests for the
# event-flag translation and the founder's `fn` rule, four in HotkeySeamBoundaryTests for acceptance
# H7, and two in ModuleBoundaryTests.
#
# The two in ModuleBoundaryTests are a *replacement*, not an addition. VoccaHotkey stopped being a
# leaf module in this commit — it implements a seam VoccaCore owns, so it depends on VoccaCore — and
# leaving it in `leafModules` while it did so was impossible. Rather than delete the coverage, rule 3
# restates it with exactly one import exempted, and its positive control runs it against a map that
# violates it. Measured: with VoccaHotkey importing VoccaAudio, rule 3 fails exactly as rule 2 did.
#
# Of the thirteen, one is there because of a mutation that survived the other twelve. Changing
# `controlBit` from 0x0004_0000 to 0x0004_0001 — a transcription slip, not sabotage — was invisible
# to a table driven by known-good flag words, because `rawFlags & bit != 0` still matched whenever
# the real bit was set and nothing in the suite ever set bit 0. Sweeping all 64 bit positions and
# requiring that exactly six produce anything is what pins the constants. Six further mutations were
# applied and all six died: a key code dropped from the implicit-`fn` set (3 failures), forward-Delete
# confused with backspace (5), the `fn` strip made unconditional (12), `kVK_Function` wrongly added to
# the set (3), an unrecognised bit folded into a modifier (2), and a CGEventFlags type planted in code
# (H7, 1).
#
# It was 143 after task 7, which put VoccaCore's real work inside the zero-network invariant. The probe now
# drives one complete session — press, three watchdog wakes, release, custody — through the real
# SessionMachine and SessionWatchdog, and ZeroNetworkTests asserts the post-condition it reports.
# The added test is the guard on that assertion: the expected post-condition is one string, and
# strings that appear in a failing diff get regenerated, so it is read back and refused unless it
# still describes a session that captured audio, handed it to custody and released the microphone.
# Fourteen weakenings of it were applied and all fourteen died.
#
# It was 142 after task 6's review round, which added one in SessionMachineTests: the stale-claim valve, in
# toggle. Two mutations that skipped it in that mode survived 141/141. The valve is *more*
# load-bearing in toggle than in hold-to-talk and was tested only in hold-to-talk — a stale claim
# there lives at most one poll interval, because `observePhysicalKey(isDown: false)` clears it, and
# in toggle there is no poll, so a fresh press is the only thing that ever releases it. Until then
# every press of the hotkey's key code is swallowed instead of typed.
#
# It was 141 after task 6 itself, which added twenty for toggle mode: seven in SessionDecisionTests (including a
# second 144-row truth table, because the two modes are two policies and a row given to the wrong
# half of a combined table would read as a deliberate difference), five in SessionMachineTests, seven
# in SessionWatchdogTests, and one in SessionVocabularyTests. Four of them carry the mode's whole
# risk: the ceiling is driven wake-by-wake *through the watchdog*, because a toggle branch that
# returns `.unchanged` instead of ticking passes every rules test and every machine test that ticks
# directly; the physical key is asserted never to be read in toggle with a hold-to-talk run beside it
# as the positive control; the cost of having no rule (f) is measured rather than argued — one poll
# interval against 700 of them for the same lost stopping gesture; and a stalled clock, which task 5
# measured as costing hold-to-talk nothing beyond the ceiling, is shown to remove the *only*
# unconditional backstop toggle has.
#
# It was 121 after task 5's second review round, which added two in SessionWatchdogTests — both about the
# direction of propagation the first round left unpinned. The tap delivers *every* key event to the
# watchdog, because stop rule (c) applies to any event whose flags drop the modifier, so a wrapper
# that hard-coded `.swallow` would eat the user's entire keyboard in every application. Round 1
# asserted propagation only for keys that are supposed to be swallowed; that mutation survived
# 119/119. Now an event the machine passes through is asserted to reach the application across that
# seam, in three states, and a key event delivered from inside the handoff gets the machine's own
# answer rather than a fabricated constant.
#
# It was 119 after task 5's first review round, which added two in SessionWatchdogTests. A clock that never
# advances disables the ceiling outright while every other mechanism keeps working — `elapsed`
# accumulates deltas, so stalled readings do not delay the ceiling, they remove it — and the test
# measures the half that bounds the damage too: the poll reads no clock, so it still ends the
# session the moment the key comes up. And every input a session owner has now arrives through the
# watchdog, including the key events that are the only thing that can *arm* it; that test pins the
# arming path and that cancellation still closes the microphone.
#
# It was 117 after task 5 itself, which added thirteen in SessionWatchdogTests: the watchdog policy — when to poll,
# what a release means, and how the system triggers map. The two that are not obvious from that
# list are the ones that make the rest mean anything: a **positive control** proving the hot-mic
# meter can detect a session that did stay open (a run whose only difference is a seam that never
# reports a release), and a measurement of what a backwards clock costs — three backward steps cost
# exactly three poll intervals, and a step smaller than an interval costs only its own size.
# `MonotonicClock.swift`'s "at most one tick interval" is per jump, not per session, and this is
# where that is measured rather than restated.
#
# It was 104 after task 4's first review round, which added two in SessionMachineTests: a stop arriving inside
# the microphone opening is now applied the moment the session exists rather than dropped (the
# review measured the real recovery for a dropped `.tapDisabled` as the 120 s ceiling, not the one
# poll interval the code claimed), and the bookkeeping on that same re-entrant path is pinned.
#
# It was 102 after task 4 itself, which added twenty-five: twenty-three in SessionMachineTests for
# the session state machine and its custody funnel, and two in CoreBoundaryTests — that a SessionOutcome is
# constructed in exactly one place in VoccaCore, and that the module reads no standard-library
# clock. The second of those closes a gap the import allow-list structurally cannot: ContinuousClock
# and SuspendingClock need no import, so `ContinuousClock().now` inside the session machine would
# leave the ceiling untestable with the boundary lint green.
#
# It was 77 after task 3's second review round, which added one: the dictate and converse bindings of
# PRODUCT_SPEC.md:127 must not match each other's press. Starting a session now requires an *exact*
# match on the bindable modifiers (locks masked), because superset semantics let one press match two
# configured bindings — and the direction that matters types speech meant for the agent into the
# focused field.
#
# It was 76 after the first review round, which added one: a multi-modifier chord must be matched as a
# whole and not in part. Every other test configured a hotkey with one modifier or none, and for
# those a chord predicate meaning *intersects* is indistinguishable from one meaning *contains all*
# — the suite was green at 75/75 with that defect in place.
#
# It was 75 after task 3 itself, which added twenty-three: twenty-one in SessionDecisionTests for
# the decision function, and two in CoreBoundaryTests (no mutable global state in VoccaCore, and
# the SessionOutcome source pins).
#
# It was 52 after task 2, which added sixteen: six in CoreBoundaryTests and ten in
# SessionVocabularyTests. (That one passed through 48 and 51 mid-task; review round 1 added the
# transitive re-export rule with its positive control and the autoclosure check, round 2 the
# CapturedAudio constraint.) It was 36 after the package-root-helper consolidation (task 1), and 33
# before that.
#
# It was 822 when the dictation-loop branch forked, and the probe-full-cycle aspect raised it to
# 823: one new test — `testTheAssertedCyclePostConditionStillDescribesACompleteDictationCycle`,
# the guard-the-guard that reads the full-cycle post-condition back and refuses a version that no
# longer describes a cycle which started, captured, transcribed with the stub's attribution,
# delivered through a real rung, and never touched the failsafe, the handoff or the download
# session. The extended `testDefaultConfigurationMakesZeroNetworkConnections` assertion is the
# same test, grown.
#
# It was 823 by the dictation-loop review-closure commit that routes the session's cancel key:
# eight tests. Six in SessionKeyPolicyTests pin "Escape is a session key" two-sided, in the
# tap-policy layer (`VoccaHotkey`, the H7 shape — the adapter stays decision-free): a fresh
# Escape key-down is the cancel gesture, the closed set of near-misses is not (autorepeat,
# key-up, flagsChanged, the hotkey's own key, a letter), the session key is swallowed while
# something is in flight and passes through over an idle Vocca, a non-session key passes through
# in both states, and the two dispositions are not collapsed into one. Two in DictationLoopTests
# close the route through the composed root, the `PRODUCT_SPEC.md:129` acceptance: Esc during
# RECORDING delivered **through the tap** ends the session `.userCancelled` (the only
# `EndReason` permitted to discard), closes the microphone, swallows the key — the focused app
# never sees it — and injects nothing; Esc during TRANSCRIBING cancels the in-flight transcribe
# parked on `GatedTranscribeEngine`'s real sleep, the engine observes the cancellation, and a
# cancelled transcription never injects, never notices and returns the widget to IDLE. The
# floor moves 823 → 831.
#
# It was 831 by the dictation-loop review-closure commit that wires the live pill into the
# composition root: five tests. Four in WidgetPanelBindingTests pin the store↔window binding —
# show/hide follows the reducer state in both directions (IDLE → RECORDING → IDLE), OPENING and a
# terminal notice also order the window front, and the pill is non-activating and **can never
# become key** — that last one is a caught defect, not a formality: a titled NSPanel can become
# key by default, so the shipped panel's "never takes focus" (`PRODUCT_SPEC.md:22`) was inherited
# rather than real, and `WidgetPanel` now overrides `canBecomeKey` to `false` — the exact inverse
# of `FailsafePanel`'s override. One in DictationLoopTests is the composition recipe: the root's
# `liveWidget` is bound (identity, not type) to the same store the effect stream folds and to the
# injected level source, `configure` created no window, and the first non-IDLE fold through the
# real effect stream constructs the panel and it orders itself front. The window itself is glue
# executed by nothing in CI (the precedent); the binding and the recipe are the tested half, and
# the zero-network probe still drives `configure` with no window created (the panel is lazy).
# The floor moves 831 → 836.
#
# The floor moves 836 → 894.
#
# The deterministic-cleanup rules-engine aspect raises it: the raise absorbs the cleanup seam's
# five tests (its plan deferred the raise to M8) and this aspect's thirteen — the B1–B12
# acceptance tables of `RulesCleanupTests`. `pipeline-wiring` (M8) will ratchet further to its
# own total — the ratchet working, not a conflict.
#
# The deterministic-cleanup user-dictionary aspect raises it again: the B1–B4 semantics and
# round-trip tables of `UserDictionaryTests` (eight), the real-store B5/B6/B8 tests of
# `DictionaryStoreTests` (eleven) and the FileManager seam's planted-tree negative control
# (one) — the suite executes what this aspect shipped, so the floor follows it.
#
# The deterministic-cleanup pipeline-wiring aspect raises it to 925: the pipeline's cleanup
# contract tests (eight, B1–B8-pipeline) and the ShippingCleanup contract tests (three, B10).
# The floor now equals the suite again — the latency-instrumentation gap (40 tests shipped
# unfloored) is closed for this aspect, per the review finding `prd.md:120-123`.
#
# The deterministic-cleanup eval-harness aspect raises it to 934: the pairwise-preference
# comparator's decision table (nine, B1) — every blind-answer × presentation row, the oracle's
# four rows, the exact percentage arithmetic (3 of 4 ⇒ 0.75), the tie-excluded denominator, the
# named `noPreferenceSample` error on all-tie and empty runs, and the seeded presentation
# order's determinism (the blindness mechanism's determinism half).
#
# The same aspect raises it to 940: the corpus loader's contract (six, B2) — discovery over a
# scratch corpus at the vacuity minimum with `dictionary.json`/`FIXTURES.md` ignored, the
# `missingCleanTarget` / `missingClassTag` / `unknownClassTag` loud failures naming the pair,
# `noPairsFound` on an empty directory, and the `corpusBelowMinimum` vacuity guard with its
# at-the-minimum success row.
#
# The same aspect raises it to 943: the provisioning script's contract (three, B5) — the
# deterministic two-run byte-identical generation over scratch goldens (24 pairs, clean side
# byte-equal to the golden, the injection actually happening), the planted raw-preferred pair
# emitted with raw == clean, and the loud rejections (unknown class directory exits 2 naming it,
# an empty goldens tree exits 1, neither creating an output directory).
#
# The same aspect raises it to 949: the provisional targets and the latency gate (six, B5/B6) —
# the stand-in corpus cleaning under the provisional p50 budget, the seeded-slow rule genuinely
# failing the gate (a gate that cannot fail proves nothing), the gate consuming the provisional
# table, the table's own existence and values, the real run consuming the preference minimum,
# and the single-source scan pinning `0.80` to the named table and its pinning test.
#
# The same aspect raises it to 954: the headless stand-in run (four, B3) — the whole-corpus
# score with the recovery guarantee (every non-planted pair cleaned, the per-class tallies
# covering all six classes, the percentage equal to the scorer's arithmetic), the planted pair
# counted as a loss through the real engine, the two-run determinism, and the printed record
# (exact percentage, seed, per-class lines) — plus the eval-family no-`URLSession` lint row in
# ModelDownloaderSeamTests (one), the family's empty-permitted-set confinement.
#
# The same aspect raises it to 958: the env-gated real run (four, B4) — the missing-pairs-
# directory loud failure naming VOCCA_CLEANUP_EVAL and the smoke step, the ballot-and-verdict
# flow (verdicts follow the comparator's mapping for the printed seed, the run records and
# never gates on a losing ballot), the missing/unknown-answers loud failures, and the
# env-gated test itself (visible skip without the variable, hard failure with a broken
# directory, wav-sidecar engine-attribution guard, recorded comparison line when complete).
#
# The llm-transport aspect raises it to 971: the LLM transport seam's contract tests (eight,
# B1/B3/B4) — the seam round-trip through the stub, the `Sendable` existential compile pin, the
# closed-and-distinct error vocabulary, `serverStatus` carrying its code, the stub emitting
# every failure mode, the default POST method, the recorded request's URL/method/headers/body,
# and the hang mode parking a call at the gate until release.
#
# The ollama-provider aspect raises it to 985: the Ollama cleanup provider's contract tests
# (fourteen, B1-B5) — the identity/network/budget declarations, the request shape over the stub's
# ledger (`api/generate`, the JSON body, the pinned prompt prefix), the happy path, the seven
# failure modes throwing (unreachable/serverStatus/invalidResponse passed through, malformed
# JSON, missing response key, empty and whitespace-only responses), and the two pinned prompts'
# byte-fidelity.
#
# The byok-provider aspect raises it to 1010: the BYOK cleanup provider's contract tests
# (nineteen, B1-B8) — the identity/network/budget declarations, the request shape over the stub's
# ledger (the configured endpoint, the `Authorization: Bearer <key>` header, the chat-completions
# body with the pinned system instruction), the nil-model omission, the happy path, the key
# absent ⇒ `.keyUnavailable` and key-throws rethrow rows (both with no recorded request), the
# 401/403 ⇒ `.unauthorized` mapping (exactly one request — never a retry — and no key in the
# error), the seven remaining failure modes throwing (unreachable/serverStatus(500)/
# invalidResponse passed through, malformed JSON, missing choices, empty choices, empty and
# whitespace-only content), and the B8 key-hygiene sweep (the sentinel rides the wire and
# appears in none of the error descriptions across every failure path) — plus the six-test
# Security seam row (tree-wide scan, one-file-per-seam, two-sided pin, planted-identifier
# negative control, the planted-tree "another file" control, comment-strip control).
#
# The cleanup-chain aspect raises it to 1017: the rules-then-LLM cleanup chain's contract tests
# (seven, B1-B7) — the rules-only passthrough (identity/network/budget from the rules provider),
# the chain composition (the LLM stub receives the rules output as its transcript, its result
# returned), the LLM-throws degrade to the rules output, the empty/whitespace LLM output degrade,
# the cancellation rethrow (a genuinely-cancelled task rethrows CancellationError rather than
# returning a stale rules result), the identity/network/budget propagation from the LLM stage,
# and the never-empty rule (an empty or whitespace rules output skips the LLM stage entirely).
#
# The cleanup-config aspect raises it to 1037: the config types' decode table (nine, B1-B2 —
# the kind round-trip with pinned raw values, the unknown-kind loud degrade, the valid full
# config with unknown keys tolerated, the silent rules config, the ollama-without-model, the
# byok-without-endpoint, the wrong-typed field, the non-dialable endpoint, and the never-throws
# sweep), the store's load contract (three, B3 — the silent missing-file default, the valid-file
# decode, the corrupt-file loud degrade that never rewrites the file), the resolver's resolve-once
# and decision table (seven, B4-B5 — the single-flight no-re-read proof, the absent-file/rules/
# ollama/byok resolution rows, and the two loud degrades), plus the FileManager seam table's
# exact-three-seams pin (one, B6 — the config row joined the table).
#
# The egress-badge aspect raises it to 1048: the egress badge's reducer contract (seven, B1-B3,
# B5 — the .none default, the active-state endpoint, the egressChanged set, the no-other-action-
# touches-egress enumeration, the no-dismissal enumeration, the wiring's explicit clear, and the
# survives-a-full-session fold), the store's setEgress fold (one), and the badge copy's
# byte-fidelity (three, B4 — the U+2601+U+FE0F glyph, the spec-pinned hover template, and the
# endpoint interpolation).
#
# The root-wiring aspect raises it to 1052: the composition root's cleanup wiring contract
# (four, B4 — the fromResolvedProvider fold for a network provider and for an offline provider,
# the absent-config resolve ⇒ rules ⇒ .none fold through the widget store, and the ollama-config
# resolve ⇒ requiresNetwork ⇒ .active(endpoint:) fold through the widget store), while the
# zero-network probe's own cycle report now carries `egress=none` on the default path.
#
# The widget-streaming aspect's Phase 2 raises it to 1068: the widget reducer's streaming-partial
# contract (WidgetStateReducerTests, eight) — the partial fold into RECORDING and TRANSCRIBING,
# the truncation at exactly `WidgetTiming.maxPartialCharacters` (the cap pinned both directions
# from the one named constant), the clearing rows (adopting IDLE/DELIVERED/a notice), the keeping
# rows (adopting RECORDING/TRANSCRIBING), the never-into-DELIVERED pin, the state-carries-the-
# text pin for the view's Reduce Motion choice, the dropped-outside-the-live-states row, and the
# closed-set fold's new `.partial` action under the invariant that provisional text rides only
# over RECORDING/TRANSCRIBING.
#
# The warm-start aspect's Phase 1 raises it to 1060: the warm-start ratio evaluator's contract
# table (WarmStartRatioTests, eight) — the within / exactly-the-bound-inclusive / exceeds-with-
# the-bound-named rows of the decision table, the two insufficient-samples rows (an empty side
# is never fabricated into a ratio, the `notPresent` precedent), the median pin for the
# steady-state side (the p50 discipline), the target's own value pin, and the single-source
# scan that keeps the bound's literal in exactly the named table and its pinning test.
#
# Raise it by hand, in the commit that changes the count, whenever the suite grows on purpose.
MINIMUM_EXECUTED_TESTS=1112

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log_file="$(mktemp -t vocca-swift-test.XXXXXX)"
trap 'rm -f "$log_file"' EXIT

set +e
(cd "$REPO_ROOT" && swift test "$@") 2>&1 | tee "$log_file"
test_status="${PIPESTATUS[0]}"
set -e

if [ "$test_status" -ne 0 ]; then
    # The suite itself failed. That is a real, loud failure and needs no help from this script;
    # exit with swift test's own status so the reason in the log is the reason in the exit code.
    exit "$test_status"
fi

# XCTest prints "Executed N tests" once per suite and once for the whole run. The largest number
# is the run total, which is what the floor is about. `sort -n | tail -1` rather than parsing the
# "All tests" line specifically, because that line's exact wording is XCTest's, not ours.
executed="$(grep -oE 'Executed [0-9]+ tests' "$log_file" | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
: "${executed:=0}"

if [ "$executed" -lt "$MINIMUM_EXECUTED_TESTS" ]; then
    printf '%s\n' \
        "::error::swift test executed $executed tests (floor: $MINIMUM_EXECUTED_TESTS). swift test exits 0 when it discovers nothing, so a green run proves nothing without this check. Either test discovery broke (methods renamed off the 'test' prefix, the test target dropped from Package.swift, a --filter matching nothing), or the suite genuinely shrank and the floor in Scripts/test-with-floor.sh needs a deliberate, reviewed edit." >&2
    exit 1
fi

printf '%s\n' "swift test executed $executed tests (floor: $MINIMUM_EXECUTED_TESTS)."

# THE MEASUREMENT HARNESS, COMPILED — because `swift test` cannot see it
#
# `Tools/TimerProbe/` is deliberately not a package target (it links AppKit and puts a real
# `NSApplication` on the screen, which nothing in the suite may do), so `swift build` and
# `swift test` never compile it. It is not decoration: it is what measured the run-loop-mode hazard
# and App Nap — the two hazards CI structurally cannot reach — and `SMOKE_CHECKLIST.md` steps 8-11
# send a human to run it before a release.
#
# This ran in CI only, as its own workflow step, and that is exactly how it broke: `hotkey-source`'s
# final-review commit added `stopWithoutAssertingIsolation()` to `RepeatingTimer`, the probe's own
# `DefaultModeTimer` conformer was not updated, and *every local signal stayed green* — the suite,
# the floor, `swift build --build-tests` under strict concurrency, all of them. Master went red on
# merge. The probe's own source predicted this in as many words ("it bit-rots silently the first
# time `RepeatingTimer` ... changes shape") and the prediction was right, because the check that
# would have caught it was not in the path anyone runs.
#
# So it runs here, in the one command the repository documents as *the* way to check the package,
# and the workflow step it duplicated has been deleted rather than left as a step that can no longer
# fail. The cost is a few seconds of incremental compile on a tree `swift test` has just built.
#
# It compiles and stops. Running a measurement needs a window server session and a human, which is
# the whole reason those two hazards are smoke steps.
set +e
"$REPO_ROOT/Scripts/measure-timers.sh" --build-only
harness_status=$?
set -e

if [ "$harness_status" -ne 0 ]; then
    printf '%s\n' \
        "::error::The timer measurement harness (Tools/TimerProbe) does not compile. It is not a package target, so nothing else in a local run or in CI compiles it — this check is the only one. It links the shipped VoccaHotkey, so a change to RepeatingTimer, WatchdogPolicy or TapHealthPolling breaks it here first. Fix the conformance rather than skipping the check: this harness is what measured the run-loop-mode hazard and App Nap, and SMOKE_CHECKLIST.md steps 8-11 tell a human to run it before every release." >&2
    exit "$harness_status"
fi

# THE ENGINE-START HARNESS, COMPILED — for the same reason and by the same rule

#

# `Tools/EngineStartProbe/` opens the microphone, which nothing in `swift test` may do, so it is not

# a package target either and nothing else compiles it. It is what answered `prd.md:280` — the

# engine-start cost the PRD had required since C1 was planned and nobody had taken — and the number

# it produced is what decided that the capture start happens off the tap callback

# (`CaptureStartTiming`). A harness that stops compiling is a number that cannot be re-taken, and the

# doc comments quoting it become unfalsifiable claims.

#

# It does not link the package: at the time it was written there was no adapter to link, because the

# engine graph is the phase after this one. When there is, this is where it should be measured.

set +e

"$REPO_ROOT/Scripts/measure-engine-start.sh" --build-only

engine_harness_status=$?

set -e



if [ "$engine_harness_status" -ne 0 ]; then

    printf '%s\n' \

        "::error::The engine-start measurement harness (Tools/EngineStartProbe) does not compile. It is not a package target, so this check is the only one. It is the instrument behind every engine-start number quoted in CaptureStartTiming, HotkeyEventSink.receive(_:) and SessionAudioSource.beginCapture() — if it cannot be run, those numbers cannot be re-taken and become claims nobody can check. Fix it rather than skipping it." >&2

    exit "$engine_harness_status"

fi





# THE ASR SPIKE PROBE, COMPILED — for the same reason, and because it is the first consumer

# of the repository's first external dependency.

#

# `Tools/ASRSpike/` depends on FluidAudio and is deliberately not a package target: nothing in

# `swift build` or `swift test` would ever compile it, and a FluidAudio API rename would surface

# only at the moment the model is actually needed — months later, mid-implementation. The probe

# is what measured the F1 spike's numbers (build, download, load, transcribe on a hosted

# runner), and `SMOKE_CHECKLIST.md` step 17 and `spike_20260809.md` send a human to it.

#

# The cost is the one the spike was asked to measure: FluidAudio now compiles on every suite

# run. That is a deliberate price for never discovering the dependency is broken at the moment

# of need.

set +e

"$REPO_ROOT/Scripts/measure-asr-spike.sh" --build-only

spike_status=$?

set -e



if [ "$spike_status" -ne 0 ]; then

    printf '%s\n' \

        "::error::The ASR spike probe (Tools/ASRSpike) does not compile. It is the repository's first FluidAudio consumer and is not a package target, so this check is the only thing that compiles it. A FluidAudio API change breaks it here first. Fix the probe rather than skipping the check: it is what the F1 spike and SMOKE_CHECKLIST.md step 17 run." >&2

    exit "$spike_status"

fi


