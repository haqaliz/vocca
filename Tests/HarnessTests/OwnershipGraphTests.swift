// Copyright 2026 The Vocca Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import VoccaCore
import VoccaHotkey
import XCTest

private let space: UInt16 = 49
private let chord = HotkeyConfiguration(
    keyCode: space, modifiers: [.option], activation: .holdToTalk)

/// **Who keeps whom alive, pinned.**
///
/// Phase 4's review measured four sole-owner edges in this graph and found **not one of them held by
/// any test**: `TapHealthPolicy.source`, `TapHealthPolicy.sink`, `SessionWatchdog.machine` and
/// `SessionEventSink.watchdog` could each be changed to `unowned` and the whole 267-test suite
/// stayed green. Phase 5 is the phase that wires the graph, which is what makes them stop being
/// idle: the object whose cycle has to be broken is being assembled for the first time, the file
/// documenting *which* edge to break is the one no CI run can execute, and an author who breaks it
/// at `policy → source` instead of at `source ─weak→ observer` gets a green suite and a product with
/// no hotkey.
///
/// ## The shape every test here has, and why it is that shape
///
/// Construct inside a scope, keep only a `weak` handle outside it, and assert the object is **still
/// alive** afterwards. That is the opposite of the usual leak test and it is deliberate: what is
/// being asserted is that something owns it. The one exception is
/// ``testTheWholeGraphIsFreedWhenItsRootGoes``, which asserts the reverse for the whole graph at
/// once — because "everything owns everything" would satisfy every test above it and is a leak.
///
/// A harness that owns more than production does cannot measure any of this. That was phase 4's
/// finding I1, where a test named the exact mutant it existed to kill and did not kill it, because
/// its harness held a `let policy` that production does not have. So nothing below uses a harness:
/// each test builds its own edge by hand.
final class OwnershipGraphTests: XCTestCase {

    // MARK: - E1 and E2 — the tap-health policy's two collaborators

    /// The policy is the source's only owner. `unowned let source` deallocates the tap the instant
    /// `arm()` returns, and `CGEventTapSource.deinit` then tears down the `CFMachPort` — so every
    /// keystroke afterwards reaches an object that is not there.
    func testThePolicyKeepsItsSourceAlive() {
        weak var source: FakeHotkeyEventSource?
        var policy: TapHealthPolicy?

        do {
            let created = FakeHotkeyEventSource()
            source = created
            policy = TapHealthPolicy(
                source: created, sink: AlwaysPassingThroughSink(), clock: TestClock(),
                secureInput: FakeSecureInputState()) { _ in }
        }

        XCTAssertNotNil(
            source,
            """
            The event tap was deallocated while its policy still holds it. In production that is a \
            CFMachPort torn down by `deinit` the moment arming returns: no hotkey, no error, and \
            `arm()` having reported `.delivering`.
            """)
        XCTAssertNotNil(policy)
    }

    /// The policy is the sink's only owner too, and the sink is the whole session graph.
    ///
    /// Its own documentation says why it holds one at all — *"the synthetic end is this object's
    /// event, not one the source observed"* — and the synthetic end is how every entry point closes
    /// the microphone. A dead sink is a policy that ends nothing.
    ///
    /// The Secure Input reader is here for the same reason and is the newest of the three: a policy
    /// that stopped owning it would read a deallocated object once a second, and the failure it
    /// guards — the hotkey reported as fine while a password field swallows every key — is one the
    /// user meets before any of the others.
    func testThePolicyKeepsItsSinkAndClockAlive() {
        weak var sink: AlwaysPassingThroughSink?
        weak var clock: TestClock?
        weak var secureInput: FakeSecureInputState?
        var policy: TapHealthPolicy?

        do {
            let createdSink = AlwaysPassingThroughSink()
            let createdClock = TestClock()
            let createdSecureInput = FakeSecureInputState()
            sink = createdSink
            clock = createdClock
            secureInput = createdSecureInput
            policy = TapHealthPolicy(
                source: FakeHotkeyEventSource(), sink: createdSink, clock: createdClock,
                secureInput: createdSecureInput) { _ in }
        }

        XCTAssertNotNil(
            sink,
            """
            The sink was deallocated while its policy still holds it. Every route this class has to \
            close a microphone goes through it.
            """)
        XCTAssertNotNil(clock, "the clock every synthetic end is stamped with")
        XCTAssertNotNil(secureInput, "the read that says whether anything reaches the tap at all")
        XCTAssertNotNil(policy)
    }

    // MARK: - E3 and E4 — the session graph

    /// The watchdog is the machine's only owner, and the machine owns the microphone.
    ///
    /// `SessionWatchdog` holds no state of its own — every question it answers is derived from the
    /// machine — so an `unowned` edge here is not a stale answer, it is a trap on the next read.
    func testTheWatchdogKeepsItsMachineAndKeyStateAlive() {
        weak var machine: SessionMachine<RecordingSource.Buffer>?
        weak var keyState: TruthfulKeyState?
        var watchdog: SessionWatchdog<RecordingSource.Buffer>?

        do {
            let createdMachine = SessionMachine(
                configuration: chord, ceiling: SessionCeiling.default, clock: TestClock(),
                audioSource: RecordingSource())
            let createdKeyState = TruthfulKeyState(Keyboard())
            machine = createdMachine
            keyState = createdKeyState
            watchdog = SessionWatchdog(machine: createdMachine, keyState: createdKeyState)
        }

        XCTAssertNotNil(machine, "the session machine outlived by its watchdog is a trap on `.schedule`")
        XCTAssertNotNil(
            keyState,
            """
            The physical-key reader was deallocated. It is what stop rule (f) is made of — the only \
            thing that ever sees a key-up which generated no event at all.
            """)
        XCTAssertNotNil(watchdog)
    }

    /// The sink is the watchdog's only owner, which is the last link in the chain from the tap
    /// callback down to the microphone.
    func testTheSessionSinkKeepsItsWatchdogAlive() {
        weak var watchdog: SessionWatchdog<RecordingSource.Buffer>?
        var sink: SessionEventSink<RecordingSource.Buffer>?

        do {
            let created = SessionWatchdog(
                machine: SessionMachine(
                    configuration: chord, ceiling: SessionCeiling.default, clock: TestClock(),
                    audioSource: RecordingSource()),
                keyState: TruthfulKeyState(Keyboard()))
            watchdog = created
            sink = SessionEventSink(watchdog: created) { _ in }
        }

        XCTAssertNotNil(watchdog)
        XCTAssertNotNil(sink)
    }

    // MARK: - The edge phase 5 added, and the one it discharges

    /// `ScheduledWatchdog` keeps both of its collaborators alive — the watchdog it reads the schedule
    /// off, and the timer it drives.
    ///
    /// **Only one of those two edges is load-bearing, and saying which is the point of this
    /// paragraph.** Measured: `ScheduledWatchdog.timer` → `unowned` is killed by this test;
    /// `ScheduledWatchdog.watchdog` → `unowned` **survives the whole suite**, because the watchdog is
    /// also held by the `SessionEventSink` this object builds internally, and that edge is E4.
    /// Mutating *both* to `unowned` is killed.
    ///
    /// So the watchdog assertion below is true and redundant — it is the chain that carries it, and
    /// `testHoldingTheRootHoldsTheWholeGraph` is what covers the chain. It is left in place rather
    /// than deleted because the redundancy is the safe direction and because a future edit that
    /// stopped `ScheduledWatchdog` building its own sink would make it load-bearing again. What it
    /// must not do is read as coverage it does not provide, which is what this note prevents.
    func testTheScheduledWatchdogKeepsItsWatchdogAndTimerAlive() {
        weak var watchdog: SessionWatchdog<RecordingSource.Buffer>?
        weak var timer: FakeTimer?
        var scheduled: ScheduledWatchdog<RecordingSource.Buffer>?

        do {
            let createdWatchdog = SessionWatchdog(
                machine: SessionMachine(
                    configuration: chord, ceiling: SessionCeiling.default, clock: TestClock(),
                    audioSource: RecordingSource()),
                keyState: TruthfulKeyState(Keyboard()))
            let createdTimer = FakeTimer()
            watchdog = createdWatchdog
            timer = createdTimer
            scheduled = ScheduledWatchdog(watchdog: createdWatchdog, timer: createdTimer) { _ in }
        }

        XCTAssertNotNil(watchdog)
        XCTAssertNotNil(
            timer,
            """
            The timer was deallocated while the object that drives it still holds it. That is the \
            ceiling and the physical-key poll both gone, silently.
            """)
        XCTAssertNotNil(scheduled)
    }

    /// **The observer is the root of the graph, and the least obvious object to hold.**
    ///
    /// `CGEventTapSource.disablementObserver` is `weak` and must be — the observer holds the policy
    /// which holds the source, so a strong edge back would close a cycle around the object whose
    /// deallocation frees a `CFMachPort`. That leaves the observer needing an owner, while the policy
    /// is the thing with the API and therefore the thing an owner reaches for.
    ///
    /// Phase 4 carried this as an instruction to whoever wired the graph. `TapHealthTimer` retains it
    /// instead, so an owner that holds the one object it is told to hold gets this for free. This is
    /// what fails if that field is ever removed as "unused" — which it looks like, because nothing
    /// calls it.
    func testTheRuntimeKeepsTheDisablementObserverAlive() {
        weak var observer: CallbackSafeTapDisablement?
        var runtime: TapHealthTimer?

        do {
            let policy = TapHealthPolicy(
                source: FakeHotkeyEventSource(), sink: AlwaysPassingThroughSink(),
                clock: TestClock(), secureInput: FakeSecureInputState()
            ) { _ in }
            let created = CallbackSafeTapDisablement(policy: policy) { _ in }
            observer = created
            runtime = TapHealthTimer(policy: policy, timer: FakeTimer(), retaining: created) { _ in }
        }

        XCTAssertNotNil(
            observer,
            """
            The disablement observer was deallocated with the runtime still alive. Nothing reports \
            that: the source's weak reference goes nil, the tap callback's optional chain evaluates \
            to nothing, and every keystroke still works — while a tap disablement now closes the \
            microphone about a second late, if the health poll is running, and never otherwise.
            """)
        XCTAssertNotNil(runtime)
    }

    // MARK: - And the whole thing, in both directions

    /// **The shipped graph, assembled, with the root the only thing held.**
    ///
    /// Every other reference is `weak`, so this fails if any edge in the chain
    /// `runtime → policy → {source, sink} → watchdog → machine` is not an owning one. It is the
    /// composite of the six tests above and it is here because they can each pass while the *chain*
    /// is broken — a strong edge to an object whose own edge is `unowned` keeps nothing alive.
    func testHoldingTheRootHoldsTheWholeGraph() {
        weak var source: FakeHotkeyEventSource?
        weak var scheduled: ScheduledWatchdog<RecordingSource.Buffer>?
        weak var watchdog: SessionWatchdog<RecordingSource.Buffer>?
        weak var machine: SessionMachine<RecordingSource.Buffer>?
        weak var microphone: RecordingSource?
        weak var observer: CallbackSafeTapDisablement?
        var runtime: TapHealthTimer?

        do {
            let createdMicrophone = RecordingSource()
            let createdMachine = SessionMachine(
                configuration: chord, ceiling: SessionCeiling.default, clock: TestClock(),
                audioSource: createdMicrophone)
            let createdWatchdog = SessionWatchdog(
                machine: createdMachine, keyState: TruthfulKeyState(Keyboard()))
            let createdScheduled = ScheduledWatchdog(
                watchdog: createdWatchdog, timer: FakeTimer()) { _ in }
            let createdSource = FakeHotkeyEventSource()
            let policy = TapHealthPolicy(
                source: createdSource, sink: createdScheduled, clock: TestClock(),
                secureInput: FakeSecureInputState()) { _ in }
            let createdObserver = CallbackSafeTapDisablement(policy: policy) { _ in }

            microphone = createdMicrophone
            machine = createdMachine
            watchdog = createdWatchdog
            scheduled = createdScheduled
            source = createdSource
            observer = createdObserver

            // The edge that makes this graph production's shape rather than a tree: the source
            // points back at the observer, weakly. Without it there is no cycle here at all and the
            // freeing test below passes for a reason unrelated to its purpose.
            createdSource.disablementObserver = createdObserver

            runtime = TapHealthTimer(
                policy: policy, timer: FakeTimer(), retaining: createdObserver) { _ in }
        }

        for (name, alive) in [
            ("the event tap", source != nil),
            ("the scheduled watchdog / sink", scheduled != nil),
            ("the watchdog", watchdog != nil),
            ("the session machine", machine != nil),
            ("the microphone", microphone != nil),
            ("the disablement observer", observer != nil),
        ] {
            XCTAssertTrue(
                alive,
                """
                \(name) was deallocated while the composition root still holds the runtime. Some \
                edge on the chain runtime → policy → {source, sink} → watchdog → machine is not an \
                owning one, and nothing about that is observable at run time until a keystroke \
                arrives.
                """)
        }
        XCTAssertNotNil(runtime)
    }

    /// ...and letting the root go frees all of it.
    ///
    /// The counterweight, and it is not decoration: every assertion above is satisfied by a graph in
    /// which everything holds everything, which is a permanent leak of a live `CFMachPort` — a tap
    /// nobody can reach and nothing can stop.
    ///
    /// ## What this pins, stated exactly, because the sentence that used to be here overclaimed
    ///
    /// The one cycle in the shipped graph is `observer → policy → source ─weak→ observer`, and it is
    /// broken at `CGEventTapSource.disablementObserver`. This test **models** that cycle —
    /// `FakeHotkeyEventSource` carries a `weak var disablementObserver` for no other purpose — and
    /// what it pins is that *the modelled* weak edge is what frees the graph: make the double's field
    /// strong and this fails.
    ///
    /// It does **not** pin the shipped field. Mutating `CGEventTapSource.disablementObserver` from
    /// `weak var` to `var` leaves the whole suite green, and always will: that file is the one
    /// `tapCreate` makes unexecutable in CI, the same category as `SystemPhysicalKeyState`. The
    /// previous version of this comment claimed otherwise, and the double had no such field at all —
    /// so the test passed for a reason unrelated to its stated purpose, which is verbatim the defect
    /// class phase 4's review called blocking. Recorded rather than quietly fixed, because "the cycle
    /// is pinned" and "a graph shaped like the cycle is pinned" are different claims and only the
    /// second is true.
    func testTheWholeGraphIsFreedWhenItsRootGoes() {
        weak var source: FakeHotkeyEventSource?
        weak var machine: SessionMachine<RecordingSource.Buffer>?
        weak var microphone: RecordingSource?
        weak var observer: CallbackSafeTapDisablement?
        weak var policyAfterwards: TapHealthPolicy?

        do {
            let createdMicrophone = RecordingSource()
            let createdMachine = SessionMachine(
                configuration: chord, ceiling: SessionCeiling.default, clock: TestClock(),
                audioSource: createdMicrophone)
            let scheduled = ScheduledWatchdog(
                watchdog: SessionWatchdog(
                    machine: createdMachine, keyState: TruthfulKeyState(Keyboard())),
                timer: FakeTimer()
            ) { _ in }
            let createdSource = FakeHotkeyEventSource()
            let policy = TapHealthPolicy(
                source: createdSource, sink: scheduled, clock: TestClock(),
                secureInput: FakeSecureInputState()) { _ in }
            let createdObserver = CallbackSafeTapDisablement(policy: policy) { _ in }
            // The cycle, closed the way production closes it — weakly. This is the edge the test is
            // about; a strong one here leaks the whole graph and this test is what says so.
            createdSource.disablementObserver = createdObserver
            let runtime = TapHealthTimer(
                policy: policy, timer: FakeTimer(), retaining: createdObserver) { _ in }

            microphone = createdMicrophone
            machine = createdMachine
            source = createdSource
            observer = createdObserver
            policyAfterwards = policy

            // Used, so the compiler cannot decide the graph was never needed.
            XCTAssertEqual(runtime.arm(), .delivering)
            runtime.disarm()
        }

        for (name, leaked) in [
            ("the event tap", source != nil),
            ("the session machine", machine != nil),
            ("the microphone", microphone != nil),
            ("the disablement observer", observer != nil),
            ("the tap-health policy", policyAfterwards != nil),
        ] {
            XCTAssertFalse(
                leaked,
                """
                \(name) survived its whole graph being released, so there is a retain cycle. In \
                production the leaked object is a live `CGEvent` tap: it goes on seeing every \
                keystroke on the machine, and nothing left alive can reach it to stop it.
                """)
        }
    }
}
