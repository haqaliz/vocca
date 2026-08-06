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
# Raise it by hand, in the commit that changes the count, whenever the suite grows on purpose.
MINIMUM_EXECUTED_TESTS=388

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
