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
# 227 by hotkey-source phase 3 review round 2, whose blocking finding was the previous round's own fix
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
MINIMUM_EXECUTED_TESTS=227

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
