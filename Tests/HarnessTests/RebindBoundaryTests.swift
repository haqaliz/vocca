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

import Foundation
import VoccaBootstrap
import VoccaCore
import VoccaHotkey
import VoccaInject
import VoccaUI
import XCTest

/// **Rebinding the hotkey at an idle boundary** — `hotkey-rebinding/rebind-boundary`, the aspect
/// that carries the unit's only Fatal-rated risk.
///
/// The binding is immutable end to end: `HotkeyConfiguration`'s fields are `let`,
/// `SessionMachine.configuration` is a `let`, and each `Wiring` bakes it in at construction. So a
/// rebind is not a value update — it is a **rebuild**, and the whole of this file is about the
/// window in which a rebuild could strand a recording on a key nobody is holding (roadmap C1-A,
/// *stuck recording*, rated Fatal).
@MainActor
final class RebindBoundaryTests: XCTestCase {

    /// The chord every harness below launches on — the shipped ⌥Space.
    private static let launchChord = PersistedSettings.defaultHotkeyChord

    /// A chord every successful row below rebinds **to** — ⌃⌥J. Modified, so the rules accept it,
    /// and a different key code from ⌥Space, so "the old chord no longer starts a session" is a
    /// claim about the key and not only about the modifiers.
    private static let newChord = HotkeyChord(keyCode: 38, modifiers: [.control, .option])

    /// A bare `J` — an unmodified text-entry key, which the rules refuse.
    private static let bareTextEntryChord = HotkeyChord(keyCode: 38, modifiers: [])

    // MARK: - Phase 1: the two wirings come from one construction

    /// **The §1 drift guard, at launch.** `init` and `rebind` build the two wirings through one
    /// factory, so what the factory pairs is what both callers get: each configuration with *its
    /// own* microphone and *its own* timer, and neither crossed.
    ///
    /// Crossed timers are the failure this row is planted against, and it is not cosmetic: two
    /// watchdogs sharing one `RepeatingTimer` means the second `start` cancels the first, so the
    /// machine whose timer was taken has no ceiling and no physical-key poll — a hot mic with
    /// nothing left to end it.
    func testTheLaunchWiringsPairEachConfigurationWithItsOwnSourceAndTimer() {
        let harness = Harness()

        XCTAssertEqual(
            harness.root.holdToTalk.configuration,
            HotkeyConfiguration(
                keyCode: Self.launchChord.keyCode, modifiers: Self.launchChord.modifiers,
                activation: .holdToTalk),
            "the hold-to-talk wiring carries the hold-to-talk configuration")
        XCTAssertEqual(
            harness.root.toggle.configuration,
            HotkeyConfiguration(
                keyCode: Self.launchChord.keyCode, modifiers: Self.launchChord.modifiers,
                activation: .toggle),
            "and the toggle wiring carries the toggle one")

        XCTAssertTrue(
            harness.root.holdToTalk.timer === harness.launchHoldTimer,
            "each wiring is woken by the timer it was given")
        XCTAssertTrue(
            harness.root.toggle.timer === harness.launchToggleTimer,
            "and never by the other wiring's — one timer under two watchdogs leaves the loser "
                + "with no ceiling and no key poll")
        XCTAssertFalse(
            harness.root.holdToTalk.timer === harness.root.toggle.timer,
            "two wirings, two timers")
        XCTAssertFalse(
            harness.root.holdToTalk.source === harness.root.toggle.source,
            "and two microphones, so the two machines can never disagree about who owns the input")
    }

    // MARK: - Phase 2: what a rebind can answer

    /// **M5.** The refusals are a **closed set**, and this row is what makes a fourth reason
    /// state itself here rather than arrive as a `default:` somewhere a user never sees.
    ///
    /// A rebind is *returned* rather than merely logged — the Speech tab's model-removal shape,
    /// not activation mode's silent no-op — because a rebind that appears not to have registered
    /// invites a second attempt, and the second attempt is made on a keyboard whose binding the
    /// user is no longer sure of.
    func testTheRefusalsAreAClosedSet() {
        XCTAssertEqual(
            Set(RebindRefusal.allCases), [.sessionInFlight, .notBindable],
            "two reasons a rebind is refused — a third must be named here, and given copy, "
                + "rather than reaching a user as a rebind that silently did nothing")
    }

    /// The three answers are distinguishable, which is the whole reason the outcome is a type
    /// rather than a `Bool`: *nothing changed* and *we would not change it* lead to different
    /// sentences on the page, and a caller that cannot tell them apart writes one of them wrong.
    func testTheThreeOutcomesAreDistinguishable() {
        XCTAssertNotEqual(RebindOutcome.rebound, .unchanged)
        XCTAssertNotEqual(RebindOutcome.unchanged, .refused(.sessionInFlight))
        XCTAssertNotEqual(
            RebindOutcome.refused(.sessionInFlight), .refused(.notBindable),
            "a refusal carries *which* refusal — the reason is the half the user needs")
        XCTAssertEqual(RebindOutcome.refused(.notBindable), .refused(.notBindable))
    }

    // MARK: - Criterion 4: a no-op rebind rebuilds nothing

    /// **Criterion 4.** Re-asking for the chord already bound answers ``RebindOutcome/unchanged``
    /// and rebuilds **nothing** — asserted by object identity of both wirings, not by comparing
    /// state, because two wirings built from the same chord have identical state and a state
    /// comparison would pass over a needless rebuild.
    ///
    /// A needless rebuild is not free: it discards two watchdogs and two timers, and it is exactly
    /// what a recorder's Save button does when a user opens it, looks at the binding and saves it
    /// back.
    func testARebindToTheChordAlreadyBoundRebuildsNothing() {
        let harness = Harness()
        let holdToTalk = harness.root.holdToTalk
        let toggle = harness.root.toggle

        XCTAssertEqual(harness.root.rebind(to: Self.launchChord), .unchanged)

        XCTAssertTrue(
            harness.root.holdToTalk === holdToTalk,
            "the hold-to-talk wiring is the same object — a no-op rebuilds nothing")
        XCTAssertTrue(
            harness.root.toggle === toggle,
            "and so is the toggle one")
        XCTAssertEqual(
            harness.settings.chordWrites, 0,
            "and nothing was written: a no-op is not a change to persist")
    }

    // MARK: - Criterion 7: a chord the rules refuse

    /// **Criterion 7.** A chord ``HotkeyBindingRules`` refuses is rejected before anything is
    /// persisted or built — and the answer names *why*, so the recorder can say it.
    ///
    /// The chord below is a bare `J`. Binding it would swallow the key **system-wide** — the tap is
    /// active and eats what is bound — and the way out would be a Settings window the user now
    /// needs that keyboard to reach. The rules are asked here rather than re-derived, which is the
    /// point of `binding-vocabulary` M6: the recorder, the launch read and this method give one
    /// answer or they give three.
    func testARebindToAChordTheRulesRefuseIsRejectedBeforeAnythingMoves() {
        let harness = Harness()
        let holdToTalk = harness.root.holdToTalk
        let toggle = harness.root.toggle

        XCTAssertEqual(
            harness.root.rebind(to: Self.bareTextEntryChord), .refused(.notBindable))

        XCTAssertEqual(
            harness.settings.chordWrites, 0,
            "nothing is persisted — a store describing a chord the app refused would be honoured "
                + "by the next launch, and the user would find the key gone after a relaunch they "
                + "did not connect to it")
        XCTAssertTrue(harness.root.holdToTalk === holdToTalk, "and nothing was rebuilt")
        XCTAssertTrue(harness.root.toggle === toggle)
        XCTAssertEqual(
            harness.root.holdToTalk.configuration.keyCode, Self.launchChord.keyCode,
            "the previous binding is still the live one")
    }

    /// A *warned* chord is adopted, not refused — the ``PersistedSettings/isAdoptable`` rule, asked
    /// here rather than re-derived. There is nothing that warns yet; what this row pins is that the
    /// question asked is adoptability and not "is it `.accepted`", so the day `shortcut-conflicts`
    /// gives the rules something to warn about, a user is not told their choice is impossible.
    func testTheRebindAsksAdoptabilityRatherThanAcceptance() {
        for validity in [HotkeyBindingValidity.accepted, .warned(.usedBySystemShortcut(name: nil))] {
            XCTAssertTrue(
                PersistedSettings.isAdoptable(validity),
                "\(validity) must be adoptable — the refusal below is the only one that stops a "
                    + "rebind")
        }
        XCTAssertFalse(
            PersistedSettings.isAdoptable(.refused(.unmodifiedTextEntryKey)),
            "and a refusal is not")
    }

    // MARK: - Criterion 1: refused while a session is in flight

    /// **Criterion 1 — the load-bearing test of the aspect.** A rebind is refused if *either*
    /// machine has a session in flight, not only the routed one.
    ///
    /// Both machines are constructed at every launch and a session in the unrouted one is still a
    /// session — the onboarding TRY IT step and a mode switch a moment earlier both put one there.
    /// A rebind is a **rebuild**: adopting one under a running session would discard the machine
    /// that owns the open microphone, and the session would be left on a key nobody is holding,
    /// with no watchdog left to notice. That is roadmap C1-A, *stuck recording*, rated Fatal for
    /// trust — the only Fatal-rated risk in this unit.
    ///
    /// Driven over the closed set of non-`.idle` states, for each machine independently.
    /// ``SessionState/ending`` is reachable only from inside the handoff itself, so it is asked
    /// from there — see ``testARebindIsRefusedFromInsideTheHandoffOfAnEndingSession``.
    func testARebindIsRefusedWhileEitherMachineIsRecording() {
        for busy in [\Harness.holdToTalkWiring, \Harness.toggleWiring] {
            let harness = Harness()
            let wiring = harness[keyPath: busy]
            let holdToTalk = harness.root.holdToTalk
            let toggle = harness.root.toggle

            harness.startSession(in: wiring)
            XCTAssertEqual(
                wiring.machine.state, .recording,
                "\(wiring.configuration.activation): a session really is in flight")

            XCTAssertEqual(
                harness.root.rebind(to: Self.newChord), .refused(.sessionInFlight),
                "\(wiring.configuration.activation): a rebind must be refused while this machine "
                    + "is recording — even when it is not the machine the tap is routed to")

            XCTAssertEqual(
                wiring.machine.state, .recording,
                "\(wiring.configuration.activation): and the session is untouched — a refusal "
                    + "never interrupts a dictation")
            XCTAssertTrue(
                harness.root.holdToTalk === holdToTalk,
                "\(wiring.configuration.activation): nothing was rebuilt")
            XCTAssertTrue(harness.root.toggle === toggle)
            XCTAssertEqual(
                harness.settings.chordWrites, 0,
                "\(wiring.configuration.activation): and nothing was persisted")

            // The refusal is about the *session*, not about the chord: the same chord binds the
            // moment the session ends. Without this half, a `rebind` that refused everything would
            // pass every assertion above.
            harness.endSession(in: wiring)
            XCTAssertEqual(
                harness.root.rebind(to: Self.newChord), .rebound,
                "\(wiring.configuration.activation): and the same chord binds once the session ends")
        }
    }

    /// The other non-`.idle` state. ``SessionState/ending`` exists for one reason — further events
    /// must not start a new session while the previous one is still handing off — and it lives
    /// entirely inside the handoff: the funnel sets it, closes the microphone, and is back in
    /// `.idle` before it returns.
    ///
    /// So the question is asked from inside `endCapture()`, which is a real place for it to be
    /// asked from: closing an audio engine pumps a run loop, and a run loop pumped there can
    /// deliver the click that calls this method.
    func testARebindIsRefusedFromInsideTheHandoffOfAnEndingSession() {
        let harness = Harness()
        let wiring = harness.root.holdToTalk
        harness.startSession(in: wiring)

        var observed: RebindOutcome?
        var stateDuringHandoff: SessionState?
        harness.holdToTalkSource.duringEndCapture = { [root = harness.root] in
            stateDuringHandoff = wiring.machine.state
            observed = root.rebind(to: RebindBoundaryTests.newChord)
        }
        harness.endSession(in: wiring)

        XCTAssertEqual(
            stateDuringHandoff, .ending,
            "the hook really did run inside the handoff — otherwise this row asks about `.idle`")
        XCTAssertEqual(
            observed, .refused(.sessionInFlight),
            "a rebind during the handoff is refused: the outcome is still on its way downstream, "
                + "and rebuilding under it would discard the machine carrying it")
        XCTAssertEqual(
            harness.settings.chordWrites, 0, "and nothing was persisted from inside the handoff")
    }

    /// **A deferred opening is a session too, and `state` cannot see it.**
    ///
    /// Under `CaptureStartTiming.whenTheOwnerAsks` — which is what ships, because
    /// `AVAudioEngine.start()` was measured at ~114 ms and a tap callback may not pay it — a press
    /// claims the key, delivers `.opening`, and leaves the machine in `.idle` with an opening owed
    /// until a later turn of the run loop. Every press passes through that window.
    ///
    /// Rebuilding inside it discards the wiring that owes the opening. The deferral captures its
    /// `ScheduledWatchdog` weakly, so the block finds nothing, the microphone never opens, and no
    /// `.ended` is ever delivered — the pill is stranded in OPENING with nothing able to move it,
    /// which is precisely the defect `settings-live-controls` found on the refused-press path.
    /// `state == .idle` is true throughout, so the guard has to ask ``SessionMachine/hasPendingOpening``
    /// as well.
    func testARebindIsRefusedWhileAnOpeningIsOwedButNotYetPerformed() {
        var pending: [() -> Void] = []
        let harness = Harness(deferOpening: { pending.append($0) })
        let wiring = harness.root.holdToTalk
        let holdToTalk = harness.root.holdToTalk
        let toggle = harness.root.toggle

        harness.startSession(in: wiring)
        XCTAssertEqual(
            wiring.machine.state, .idle,
            "the microphone has not opened yet — `state` cannot see this session")
        XCTAssertTrue(
            wiring.machine.hasPendingOpening,
            "but an opening is owed, and the key is already claimed")

        XCTAssertEqual(
            harness.root.rebind(to: Self.newChord), .refused(.sessionInFlight),
            "a rebuild here would drop the opening on the floor and strand the widget in OPENING")
        XCTAssertTrue(harness.root.holdToTalk === holdToTalk, "so nothing was rebuilt")
        XCTAssertTrue(harness.root.toggle === toggle)

        // Let the run loop turn: the opening completes into the wiring that owes it, and the
        // session becomes an ordinary one the guard can already see.
        pending.forEach { $0() }
        XCTAssertEqual(harness.holdToTalkSource.beginCount, 1, "the deferred opening ran")
        XCTAssertEqual(wiring.machine.state, .recording)
    }

    // MARK: - Criteria 2 and 8: the new chord works and the old one does not

    /// **Criterion 8 — the behavioural proof.** After a rebind the *new* chord starts a session
    /// and the *old* one does not, driven end to end through the tap.
    ///
    /// Every other row in this file asserts about objects. This one asserts about the keyboard,
    /// which is the only claim a user can check: it would still pass if the wirings were swapped
    /// by some entirely different mechanism, and it fails for every mechanism that swaps them
    /// wrongly.
    ///
    /// **Criterion 2** rides with it: both machines carry the new chord, exactly one is routed, the
    /// routed one is the one ``DictationLoopRoot/activeMode`` names, and both are back in `.idle`.
    func testAfterARebindTheNewChordStartsASessionAndTheOldOneDoesNot() {
        let harness = Harness()
        XCTAssertEqual(harness.root.activeMode, .toggle, "the shipped default, and what is routed")

        XCTAssertEqual(harness.root.rebind(to: Self.newChord), .rebound)

        XCTAssertEqual(
            harness.machinesStartedByPressing(Self.launchChord), [],
            "the old chord starts nothing — a rebind that left the previous binding live would "
                + "give the user two hotkeys, one of which they cannot see in Settings")
        XCTAssertEqual(
            harness.machinesStartedByPressing(Self.newChord), [.toggle],
            "and the new chord starts a session in the routed machine, and in that one only")

        XCTAssertEqual(
            harness.root.holdToTalk.configuration,
            HotkeyConfiguration(
                keyCode: Self.newChord.keyCode, modifiers: Self.newChord.modifiers,
                activation: .holdToTalk),
            "the hold-to-talk machine carries the new chord")
        XCTAssertEqual(
            harness.root.toggle.configuration,
            HotkeyConfiguration(
                keyCode: Self.newChord.keyCode, modifiers: Self.newChord.modifiers,
                activation: .toggle),
            "and so does the toggle machine — both are configurations of one binding")
        XCTAssertEqual(harness.root.holdToTalk.machine.state, .idle, "and both are idle")
        XCTAssertEqual(harness.root.toggle.machine.state, .idle)
    }

    // MARK: - Criterion 10: the routing sink points at the new wiring

    /// **Criterion 10.** After a rebind the tap's route points at the **new** wiring for the
    /// current activation mode — driven in both modes, because a route re-pointed to the wrong
    /// mode's wiring and a route left on the old object fail differently.
    ///
    /// The plant this row is written against is re-pointing at the *old* wiring: the graph then
    /// looks entirely healthy and the hotkey is simply dead, which on an `LSUIElement` app is
    /// indistinguishable from a working one until the user presses the key. That failure class is
    /// what three `fix/local-dev-launch` defects were made of.
    func testTheRouteFollowsTheRebuildInBothActivationModes() {
        for activation in [HotkeyConfiguration.Activation.holdToTalk, .toggle] {
            let harness = Harness(activation: activation)
            let expected = DictationLoopRoot.mode(for: activation)
            XCTAssertEqual(harness.root.activeMode, expected, "\(activation)")

            XCTAssertEqual(harness.root.rebind(to: Self.newChord), .rebound, "\(activation)")

            XCTAssertEqual(
                harness.machinesStartedByPressing(Self.newChord), [expected],
                "\(activation): the tap's events reach the newly built wiring for the mode the "
                    + "root says it is running — not the other mode's, and not the discarded object")
        }
    }

    // MARK: - Criterion 6: the tap is never re-created

    /// **Criterion 6.** The event tap is the same object across a rebind, and nothing re-arms it.
    ///
    /// Identity, not equality. The tap is binding-agnostic — its `eventsOfInterest` mask is built
    /// from event *kinds*, never key codes — and it is owned above the wirings, so a rebind has no
    /// reason to touch it. Re-creating it would be actively worse than pointless: `CGEvent.tapCreate`
    /// needs the Accessibility grant, so a needless re-create is a chance to lose a working tap for
    /// no gain, and losing it is silent.
    func testARebindLeavesTheTapAloneEntirely() {
        let harness = Harness()
        let tap = harness.root.tap
        let startsBefore = harness.tap.startCount
        let stopsBefore = harness.tap.stopCount
        let resumesBefore = harness.tap.resumeCount

        XCTAssertEqual(harness.root.rebind(to: Self.newChord), .rebound)

        XCTAssertTrue(harness.root.tap === tap, "the same tap object — never re-created")
        XCTAssertEqual(
            harness.tap.startCount, startsBefore,
            "and never re-armed: `tapCreate` needs the Accessibility grant, so a needless "
                + "re-create is a chance to lose a working tap for nothing")
        XCTAssertEqual(harness.tap.stopCount, stopsBefore, "nor torn down")
        XCTAssertEqual(harness.tap.resumeCount, resumesBefore, "nor resumed")
        XCTAssertTrue(harness.tap.isDelivering, "and it is still delivering")
    }

    // MARK: - Criterion 5: the persist

    /// **Criterion 5.** The chord is persisted on success — exactly once — and on no other answer.
    ///
    /// A count rather than a flag: persisting twice and persisting once are different bugs, and a
    /// flag cannot tell them apart.
    ///
    /// The persist happens **after** the two new wirings are built and before they are adopted.
    /// That order deviates from `setActiveMode(_:)`, deliberately: that method's adopt is
    /// infallible, so persisting first cannot leave the store ahead of the app. This one does real
    /// construction, and a store describing a chord the running app never adopted is the exact
    /// failure `setActiveMode`'s own comment warns about, reached from the other direction.
    func testTheChordIsPersistedOnceOnSuccessAndOnNoOtherAnswer() {
        let harness = Harness()

        XCTAssertEqual(harness.root.rebind(to: Self.newChord), .rebound)
        XCTAssertEqual(harness.settings.chordWrites, 1, "written exactly once")
        XCTAssertEqual(
            harness.settings.hotkeyChord(), Self.newChord,
            "and the next launch reads back the chord the user chose")

        XCTAssertEqual(harness.root.rebind(to: Self.newChord), .unchanged)
        XCTAssertEqual(harness.settings.chordWrites, 1, "a no-op writes nothing")

        XCTAssertEqual(
            harness.root.rebind(to: Self.bareTextEntryChord), .refused(.notBindable))
        XCTAssertEqual(harness.settings.chordWrites, 1, "and a refusal writes nothing")
    }

    // MARK: - Criterion 9: init and rebind agree

    /// **Criterion 9 — the §1 drift guard.** A root *launched* on a chord and a root *rebound* to
    /// the same chord are the same graph.
    ///
    /// Both go through one factory, so this row is what says the factory really is the only
    /// construction: two inline constructions would drift, and a rebuilt wiring that differs from a
    /// launched one is a defect that appears only after a rebind — which every test that never
    /// rebinds stays green through.
    func testARootReboundToAChordMatchesARootLaunchedOnIt() {
        let launched = Harness(chord: Self.newChord)
        let rebound = Harness(chord: Self.launchChord)
        XCTAssertEqual(rebound.root.rebind(to: Self.newChord), .rebound)

        for (which, pair) in [
            ("hold-to-talk", (launched.root.holdToTalk, rebound.root.holdToTalk)),
            ("toggle", (launched.root.toggle, rebound.root.toggle)),
        ] {
            XCTAssertEqual(
                pair.0.configuration, pair.1.configuration,
                "\(which): same binding, same activation")
            XCTAssertEqual(pair.0.machine.state, pair.1.machine.state, "\(which): both idle")
        }

        XCTAssertTrue(
            rebound.root.holdToTalk.source === rebound.holdToTalkSource
                || rebound.root.holdToTalk.source !== rebound.toggleSource,
            "the rebuilt hold-to-talk wiring still captures through the hold-to-talk microphone — "
                + "a rebuild that crossed the two sources would leave both machines on one input")

        XCTAssertEqual(
            launched.machinesStartedByPressing(Self.newChord),
            rebound.machinesStartedByPressing(Self.newChord),
            "and the two roots answer the same chord the same way, which is the only comparison a "
                + "user can make")
    }

    // MARK: - The clocks a rebuild mints and the ones it retires

    /// **A rebuilt wiring gets its own timer, and the retired ones are stopped.**
    ///
    /// The hazard this row exists for is the one the plan calls out: a `RepeatingTimer` handed to a
    /// second `ScheduledWatchdog` while the first still holds it has two owners, and the first
    /// owner is about to be discarded. `ScheduledWatchdog.deinit` stops the timer it holds — so if
    /// the discarded watchdog were sharing the new wiring's clock, its release would stop the
    /// *running* session's watchdog, leaving that session with no ceiling and no physical-key
    /// poll. Nothing would then be left to end it: a hot mic, which is the Fatal-rated failure this
    /// aspect exists to make unrepresentable.
    ///
    /// The last assertion is the one that would catch it: a session started after the rebind has a
    /// clock that is actually ticking.
    func testARebuildMintsAFreshTimerPerWiringAndStopsTheRetiredOnes() {
        let harness = Harness()

        XCTAssertEqual(harness.root.rebind(to: Self.newChord), .rebound)

        XCTAssertEqual(harness.timers.made.count, 2, "one fresh timer per wiring, and no more")
        XCTAssertFalse(
            harness.root.holdToTalk.timer === harness.root.toggle.timer,
            "the two rebuilt wirings do not share a clock")
        for (which, timer) in [
            ("hold-to-talk", harness.root.holdToTalk.timer),
            ("toggle", harness.root.toggle.timer),
        ] {
            XCTAssertTrue(
                harness.timers.made.contains(where: { $0 === timer }),
                "\(which): the rebuilt wiring is woken by a timer minted for it")
            XCTAssertFalse(
                timer === harness.launchHoldTimer, "\(which): never the retired hold-to-talk clock")
            XCTAssertFalse(
                timer === harness.launchToggleTimer, "\(which): nor the retired toggle one")
        }

        XCTAssertGreaterThanOrEqual(
            harness.launchHoldTimer.stopCount, 1,
            "the retired hold-to-talk clock was stopped — a timer left firing into a discarded "
                + "watchdog spends battery for the life of the process")
        XCTAssertGreaterThanOrEqual(harness.launchToggleTimer.stopCount, 1)
        XCTAssertFalse(harness.launchHoldTimer.isRunning)
        XCTAssertFalse(harness.launchToggleTimer.isRunning)

        harness.startSession(in: harness.toggleWiring)
        XCTAssertEqual(harness.root.toggle.machine.state, .recording)
        XCTAssertNotNil(
            harness.root.toggle.timer.interval,
            "and the session started after the rebind has a watchdog whose clock is running — "
                + "which is the whole of the ceiling, the key poll and the stop rules")
    }

    // MARK: - The harness

    /// One composed root over fakes, on the `ActivationPersistenceTests` shape: every event is
    /// driven through the **tap**, so what is asserted is which microphone actually opened rather
    /// than which wiring the root claims to be routing to.
    @MainActor
    private struct Harness {
        let keyboard: Keyboard
        let tap: FakeHotkeyEventSource
        let holdToTalkSource: RecordingAudioSource
        let toggleSource: RecordingAudioSource
        /// The two timers the *launch* wirings were built with — the old ones, once a rebind lands.
        let launchHoldTimer: FakeTimer
        let launchToggleTimer: FakeTimer
        /// Every timer a rebuild has minted, in order.
        let timers: TimerFactory
        let settings: EphemeralSettingsStore
        let root: DictationLoopRoot

        /// The two wirings by key path, so a row can drive "each machine independently" over a
        /// closed pair rather than by copying itself.
        var holdToTalkWiring: Wiring { root.holdToTalk }
        var toggleWiring: Wiring { root.toggle }

        /// - Parameter deferOpening: where the microphone is opened. Synchronous by default, which
        ///   is what every other headless harness in the suite uses; a row that wants to observe
        ///   the deferred-opening window passes one that queues instead.
        init(
            chord: HotkeyChord = RebindBoundaryTests.launchChord,
            activation: HotkeyConfiguration.Activation = PersistedSettings.defaultActivation,
            deferOpening: @escaping RunLoopDeferral = { $0() }
        ) {
            let settings = EphemeralSettingsStore(chord: chord, activation: activation)
            let configurations = AppBootstrap.hotkeyConfigurations(chord: chord)
            let keyboard = Keyboard()
            let tap = FakeHotkeyEventSource()
            let holdToTalkSource = RecordingAudioSource()
            let toggleSource = RecordingAudioSource()
            let launchHoldTimer = FakeTimer()
            let launchToggleTimer = FakeTimer()
            let timers = TimerFactory()
            let holder = LedgerHolder()
            let engine = StubEngine.parakeet()

            let root = DictationLoopRoot(
                configuration: configurations.holdToTalk,
                ceiling: SessionCeiling.default,
                clock: TestClock(),
                audioSource: holdToTalkSource,
                keyState: TruthfulKeyState(keyboard),
                watchdogTimer: launchHoldTimer,
                healthTimer: FakeTimer(),
                deferOpening: deferOpening,
                tap: tap,
                secureInput: FakeSecureInputState(),
                resolver: DictationEngineResolver(selection: .defaultSelection) { _ in engine },
                targetResolution: TargetResolution(
                    focusedApp: FakeFocusedApp(
                        identity: FocusedAppIdentity(
                            bundleID: "com.apple.Notes", windowTitle: "The Draft")),
                    secureInput: FakeSecureInput()),
                panel: RecordingPanel(holder: holder),
                pipeline: DictationPipeline(
                    engine: engine,
                    injector: LedgerInjector(
                        result: InjectionResult(
                            rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                            elapsed: .zero)),
                    holder: holder),
                settings: settings,
                toggleConfiguration: configurations.toggle,
                toggleSource: toggleSource,
                toggleTimer: launchToggleTimer,
                runningAppName: FakeRunningAppName(),
                widgetClock: FakeTimer(),
                liveLevel: SilentLevelSource(),
                makeWatchdogTimer: { timers.make() })

            self.keyboard = keyboard
            self.tap = tap
            self.holdToTalkSource = holdToTalkSource
            self.toggleSource = toggleSource
            self.launchHoldTimer = launchHoldTimer
            self.launchToggleTimer = launchToggleTimer
            self.timers = timers
            self.settings = settings
            self.root = root

            // The readiness gate opens here rather than in each row: with it shut every
            // `beginCapture` answers `.unavailable`, no machine ever leaves `.idle`, and every
            // "a session is in flight" row below would pass while proving nothing.
            root.markEnginePrepared()
        }

        /// Starts a session in **one** wiring, driving that wiring's own sink.
        ///
        /// Deliberately not through the tap: the unrouted machine is reachable no other way, and a
        /// session in the unrouted machine is exactly the case this file exists for.
        func startSession(in wiring: Wiring) {
            keyboard.hold(wiring.configuration)
            _ = wiring.scheduledWatchdog.receive(
                keyEvent(
                    .keyDown, wiring.configuration.keyCode, wiring.configuration.modifiers))
        }

        /// Ends a session started by ``startSession(in:)``, in either activation mode: the key-up
        /// ends a hold, and the second key-down ends a toggle.
        func endSession(in wiring: Wiring) {
            let code = wiring.configuration.keyCode
            let modifiers = wiring.configuration.modifiers
            _ = wiring.scheduledWatchdog.receive(keyEvent(.keyUp, code, modifiers))
            keyboard.release(code)
            if wiring.machine.state != .idle {
                _ = wiring.scheduledWatchdog.receive(keyEvent(.keyDown, code, modifiers))
                _ = wiring.scheduledWatchdog.receive(keyEvent(.keyUp, code, modifiers))
            }
        }

        /// **Which machines opened a microphone for a press of `chord` through the tap** — the
        /// routing claim, asserted as hardware rather than as a field the root reports.
        ///
        /// Through the tap on purpose: a root whose reported route and actual route disagree is a
        /// hotkey silently driving the wrong machine, and reading `activeMode` would agree with
        /// itself in exactly that case. An empty answer means the chord started nothing at all.
        ///
        /// The press is completed rather than left open — a second press ends a toggle session,
        /// and is sent only when one is still in flight, because in hold-to-talk it would start a
        /// second session instead of ending the first.
        func machinesStartedByPressing(_ chord: HotkeyChord) -> [DictationMode] {
            let holdBefore = holdToTalkSource.beginCount
            let toggleBefore = toggleSource.beginCount
            pressThroughTap(chord)
            if root.holdToTalk.machine.state != .idle || root.toggle.machine.state != .idle {
                pressThroughTap(chord)
            }
            var started: [DictationMode] = []
            if holdToTalkSource.beginCount > holdBefore { started.append(.holdToTalk) }
            if toggleSource.beginCount > toggleBefore { started.append(.toggle) }
            return started
        }

        /// One complete press and release of `chord`, delivered through the tap.
        private func pressThroughTap(_ chord: HotkeyChord) {
            keyboard.press(chord.keyCode)
            keyboard.heldModifiers = chord.modifiers
            _ = tap.deliver(keyEvent(.keyDown, chord.keyCode, chord.modifiers))
            _ = tap.deliver(keyEvent(.keyUp, chord.keyCode, chord.modifiers))
            keyboard.release(chord.keyCode)
            keyboard.heldModifiers = []
        }
    }
}

// MARK: - The doubles

/// Every timer a rebuild minted, in order — so a test can say *fresh*, not merely *a timer*.
@MainActor
private final class TimerFactory {
    private(set) var made: [FakeTimer] = []

    func make() -> any RepeatingTimer {
        let timer = FakeTimer()
        made.append(timer)
        return timer
    }
}

/// A settings store with no disk behind it, remembering what it was handed.
private final class EphemeralSettingsStore: SettingsStore, @unchecked Sendable {
    private var chord: HotkeyChord
    private var activation: HotkeyConfiguration.Activation
    private var selection = EngineSelection.defaultSelection
    private var acknowledgedCloud = false

    /// How many times a chord was written — a count rather than a flag, because "persisted twice"
    /// and "persisted once" are different bugs and a flag cannot tell them apart.
    private(set) var chordWrites = 0

    init(
        chord: HotkeyChord = PersistedSettings.defaultHotkeyChord,
        activation: HotkeyConfiguration.Activation = PersistedSettings.defaultActivation
    ) {
        self.chord = chord
        self.activation = activation
    }

    func engineSelection() -> EngineSelection { selection }
    func setEngineSelection(_ selection: EngineSelection) { self.selection = selection }
    func activationMode() -> HotkeyConfiguration.Activation { activation }
    func setActivationMode(_ activation: HotkeyConfiguration.Activation) {
        self.activation = activation
    }
    func hotkeyChord() -> HotkeyChord { chord }
    func setHotkeyChord(_ chord: HotkeyChord) {
        self.chord = chord
        chordWrites += 1
    }
    func hasAcknowledgedCloudCleanup() -> Bool { acknowledgedCloud }
    func setAcknowledgedCloudCleanup(_ acknowledged: Bool) { acknowledgedCloud = acknowledged }
}

/// The widget's level source, silent — this suite asserts nothing about the waveform.
private struct SilentLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}

private func keyEvent(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: false, timestamp: .zero)
}
