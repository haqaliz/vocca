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

// The probe's half of the zero-network invariant for `VoccaCore`.
//
// While `VoccaCore` held a placeholder, naming one of its types in the probe's module list was all
// the invariant could say about it. It now holds a session state machine, a watchdog, a decision
// function and a clock seam, and a metatype reference says nothing about any of them: the coverage
// guard in `ZeroNetworkTests` is at module granularity by construction, so it cannot tell a module
// that was *reached* from a module whose work was *run*.
//
// So this file runs the work. `VoccaNetworkProbe.exerciseSessionLifecycle()` drives one complete
// session — press, capture, three watchdog wakes, release, custody — through the real
// `SessionMachine` and the real `SessionWatchdog`, and reports what it observed afterwards. The
// suite asserts that observation, not the call. Deleting the call takes the report with it and
// `ZeroNetworkTests` fails by name; that is the property the previous aspect learned the hard way,
// when deleting `AppBootstrap.configure(_:)` while keeping `AppBootstrap.self` in a list left the
// suite green.

// MARK: - The seams the lifecycle needs

/// What a probe session captured.
///
/// `VoccaCore` deliberately cannot name a real buffer type — ``CapturedAudio`` is an empty marker
/// precisely so the module never learns what a sample rate is — so the probe supplies one, as
/// `audio-capture` will later. The fields are what make custody *observable*: each buffer carries
/// the ordinal of the capture that produced it, so an outcome carrying **this session's** buffer is
/// distinguishable from an outcome carrying a freshly-minted empty one. Without that, a machine that
/// swapped in a new buffer on the way to the outcome would report exactly the same thing.
struct ProbeCapture: CapturedAudio, Equatable {
    /// Which capture this was: 1 for the first session of the process, 2 for the second.
    let ordinal: Int
    /// Stand-in for a sample count. Derived from ``ordinal`` so it, too, differs per session.
    let frames: Int
}

/// The microphone, as a ledger.
///
/// A ledger and not a stub, for the reason `SessionAudioSource` documents at length: *"the session
/// ended" is not "the microphone was released"*. The counters below are what the suite reads to tell
/// the two apart, and they are the same shape as `RecordingSource` in `Tests/HarnessTests` — which
/// this cannot simply reuse, because a test target's types are not visible to an executable target.
final class ProbeMicrophone: SessionAudioSource {
    private(set) var isOpen = false
    private(set) var opens = 0
    private(set) var closes = 0
    /// A `beginCapture()` arriving while already open. Recorded rather than assumed impossible.
    private(set) var overlappingOpens = 0
    /// An `endCapture()` arriving while closed — the other half of "no orphaned handles".
    private(set) var closesWithoutOpen = 0

    func beginCapture() -> CaptureStart {
        if isOpen { overlappingOpens += 1 }
        opens += 1
        isOpen = true
        return .opened
    }

    func endCapture() -> ProbeCapture {
        if !isOpen { closesWithoutOpen += 1 }
        closes += 1
        isOpen = false
        return ProbeCapture(ordinal: closes, frames: closes * 3)
    }
}

/// A clock the probe moves by hand.
///
/// Deterministic on purpose: the whole observation below is asserted as one exact line, and a
/// reading taken from a real clock would make `elapsed` a number no test could state. It advances by
/// ``VoccaNetworkProbe/clockStepPerWake`` between wakes, which is the probe's own constant rather
/// than `WatchdogPolicy.pollInterval` — tying the expected line to the shipped poll interval would
/// fail this suite for a change to a number that has nothing to do with networking.
final class ProbeClock: MonotonicClock {
    private(set) var now: Duration = .zero

    func advance(by delta: Duration) {
        now += delta
    }
}

/// The physical-key seam, recording **what was asked and how often**.
///
/// `PhysicalKeyStateReader` is class-bound so that this counter survives being handed to the
/// watchdog, and this is the use it was made class-bound for: "the poll ran three times, against the
/// configured key code" is the difference between a watchdog that watches and one that has quietly
/// stopped.
final class ProbeKeyState: PhysicalKeyStateReader {
    /// What the next read reports. The probe holds the key down for the whole session and releases
    /// it with a real key-up event, so this stays `true`.
    var isHeld = true
    private(set) var reads = 0
    private(set) var keyCodesRead: [UInt16] = []

    /// The chord the user is holding, physically. Set by the drive to the configured one, because
    /// the drive models a user who is holding the hotkey — a reader that answered `[]` here would be
    /// modelling a user who has let go, and the session would end on the first wake.
    var heldModifiers: ModifierSet = []

    /// How many times the chord was asked for, counted separately from ``reads``.
    ///
    /// Separate because the two are not read the same number of times and must not appear to be:
    /// `SessionWatchdog.theBindingIsStillHeld` short-circuits, so the chord is asked for only on the
    /// wakes where the key was still down. A single combined counter would hide that, and hiding it
    /// is how "the second read happens" and "the second read is skipped when the key is up" become
    /// indistinguishable.
    private(set) var modifierReads = 0

    func isKeyDown(_ keyCode: UInt16) -> Bool {
        reads += 1
        keyCodesRead.append(keyCode)
        return isHeld
    }

    var physicalModifiers: ModifierSet {
        modifierReads += 1
        return heldModifiers
    }
}

// MARK: - The drive

extension VoccaNetworkProbe {

    /// One session driven through the real machine, and the post-condition the suite asserts.
    struct SessionDrive {
        /// The observation, as one line of `key=value` fields. Asserted whole — see
        /// `ZeroNetworkTests.expectedSessionLifecycle`.
        let report: String

        /// A type minted **by this drive**, from which `VoccaCore`'s name is derived for the
        /// coverage list.
        ///
        /// This is why the module entry is not a metatype literal any more. `SessionState.self`
        /// sitting in that list satisfied the coverage guard whether or not a single line of
        /// `VoccaCore` ever ran; a witness that only exists because the machine was constructed and
        /// driven cannot be kept while the call is deleted.
        let moduleWitness: Any.Type
    }

    /// How far the clock moves between watchdog wakes.
    ///
    /// Any value below the ceiling would do — nothing here is testing the ceiling, which
    /// `SessionWatchdogTests` drives 800 wakes to reach. 100 ms is a plausible cadence and makes the
    /// reported elapsed time a round number.
    static let clockStepPerWake: Duration = .milliseconds(100)

    /// How many times the owner's timer is turned. Three rather than one, so that "the wake did
    /// something" is distinguishable from "the wake ran once and the machine remembered a single
    /// reading": `elapsed` must be three steps, and the physical key must have been read three
    /// times.
    static let wakeCount = 3

    /// The virtual key code for Space, as macOS numbers them. Only ever compared for equality
    /// against ``HotkeyConfiguration/keyCode``.
    static let spaceKeyCode: UInt16 = 49

    /// **Drives one complete session through the real state machine, and reports what happened.**
    ///
    /// Press → three watchdog wakes → release → custody, in hold-to-talk, which is the mode that
    /// exercises the most of the module: the start rule, the key claim, the physical-key poll, the
    /// clock accumulation, a stop rule, the single custody funnel, and the watchdog's own schedule.
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the same reason
    /// `AppBootstrap`'s activation policy is reported rather than checked in-process: an assertion
    /// that lives in the observed process can be deleted in the same edit that breaks what it
    /// observes, and its failure would arrive as an exit status rather than as a named expectation.
    ///
    /// It also makes no network call, which is the point of running it here at all. Every type it
    /// touches is `VoccaCore`'s, and `CoreBoundaryTests` already holds that module to an import
    /// allow-list with no Foundation, Darwin or Dispatch in it — but "cannot import a networking
    /// framework" is not "makes no connection", and this is the mechanism that says the second
    /// thing.
    static func exerciseSessionLifecycle() -> SessionDrive {
        let clock = ProbeClock()
        let microphone = ProbeMicrophone()
        let keyState = ProbeKeyState()

        let configuration = HotkeyConfiguration(
            keyCode: spaceKeyCode, modifiers: [.option], activation: .holdToTalk)

        // The user is holding the whole binding, chord included. Taken from the configuration rather
        // than written out, so that a drive whose binding changed cannot silently become one where
        // the chord is not held and every wake ends the session.
        keyState.heldModifiers = configuration.modifiers
        let machine = SessionMachine(
            configuration: configuration,
            ceiling: SessionCeiling.default,
            clock: clock,
            audioSource: microphone)
        let watchdog = SessionWatchdog(machine: machine, keyState: keyState)

        // Every input goes through the watchdog, which is how a session owner is meant to drive
        // this — see `SessionWatchdog.observe(_:)`. Routing the key events straight to the machine
        // would exercise the same rules while skipping the wrapper the app will actually hold.
        let press = watchdog.observe(
            keyEvent(.keyDown, configuration: configuration, at: clock.now))

        var wakeEffects: [String] = []
        for _ in 0..<wakeCount {
            clock.advance(by: clockStepPerWake)
            wakeEffects.append(describe(watchdog.wake()))
        }

        // Read while the session is still running: both are false-if-idle, so reading them after
        // the release would report the idle answer and prove nothing.
        let elapsedDuringSession = machine.elapsed
        let ceilingWasNear = watchdog.ceilingIsNear
        let scheduleDuringSession = describe(watchdog.schedule)

        let release = watchdog.observe(
            keyEvent(.keyUp, configuration: configuration, at: clock.now))

        let fields = [
            "press=\(describe(press.effect))",
            "press.propagation=\(describe(press.eventPropagation))",
            "wakes=\(wakeEffects.count)",
            "wake.effects=\(wakeEffects.joined(separator: ","))",
            "wake.keyReads=\(keyState.reads)",
            "wake.keyCodesRead=\(describe(keyCodes: keyState.keyCodesRead))",
            "wake.modifierReads=\(keyState.modifierReads)",
            "elapsed=\(milliseconds(elapsedDuringSession))ms",
            "ceilingNear=\(ceilingWasNear)",
            "scheduleWhileRecording=\(scheduleDuringSession)",
            "release=\(describe(release.effect))",
            "release.propagation=\(describe(release.eventPropagation))",
            "audio.ordinal=\(describe(ordinalOf: capturedAudio(in: release.effect)))",
            "audio.frames=\(describe(framesOf: capturedAudio(in: release.effect)))",
            "mic.open=\(microphone.isOpen)",
            "mic.opens=\(microphone.opens)",
            "mic.closes=\(microphone.closes)",
            "mic.overlappingOpens=\(microphone.overlappingOpens)",
            "mic.closesWithoutOpen=\(microphone.closesWithoutOpen)",
            "state=\(describe(machine.state))",
            "schedule=\(describe(watchdog.schedule))",
        ]

        return SessionDrive(report: fields.joined(separator: " "), moduleWitness: type(of: machine))
    }

    /// One keyboard event carrying the configured chord.
    ///
    /// Plain data, as `RawKeyEvent` documents: no `CGEvent`, no event tap and no Accessibility grant
    /// is involved, which is what lets the whole lifecycle run inside a headless probe at all.
    private static func keyEvent(
        _ kind: RawKeyEvent.Kind, configuration: HotkeyConfiguration, at timestamp: Duration
    ) -> RawKeyEvent {
        RawKeyEvent(
            kind: kind,
            keyCode: configuration.keyCode,
            modifiers: configuration.modifiers,
            isAutorepeat: false,
            timestamp: timestamp)
    }

    // MARK: - Spelling the observation

    // Every `describe` below is an exhaustive switch written out by hand rather than
    // `String(describing:)`, for the reason `name(of:)` gives for activation policies: the markers
    // the suite matches on are this package's own vocabulary, so they cannot change under it when a
    // compiler or a framework relabels something. Exhaustiveness is the second half — a case added
    // to any of these enums fails to compile here until someone says what the probe should report
    // for it, rather than falling into a `default:` that reads as a clean run.

    private static func describe(_ effect: SessionEffect<ProbeCapture>) -> String {
        switch effect {
        case .unchanged: return "unchanged"
        case .started: return "started"
        case .captureUnavailable: return "captureUnavailable"
        case .ended(let outcome): return "ended(\(describe(outcome)))"
        }
    }

    private static func describe(_ outcome: SessionOutcome<ProbeCapture>) -> String {
        switch outcome.content {
        case .completed(let reason, _, _): return "completed(\(describe(reason)))"
        case .cancelled: return "cancelled"
        }
    }

    private static func describe(_ reason: RetainedEndReason) -> String {
        switch reason {
        case .keyUp: return "keyUp"
        case .modifierReleased: return "modifierReleased"
        case .tapDisabled: return "tapDisabled"
        case .ceilingReached: return "ceilingReached"
        case .pollDetectedRelease: return "pollDetectedRelease"
        case .toggledOff: return "toggledOff"
        case .systemEvent(let trigger): return "systemEvent(\(describe(trigger)))"
        }
    }

    private static func describe(_ trigger: SystemTrigger) -> String {
        switch trigger {
        case .willSleep: return "willSleep"
        case .screensDidSleep: return "screensDidSleep"
        case .sessionDidResignActive: return "sessionDidResignActive"
        case .audioConfigurationChanged: return "audioConfigurationChanged"
        case .secureInputEnabled: return "secureInputEnabled"
        }
    }

    private static func describe(_ propagation: EventPropagation) -> String {
        switch propagation {
        case .passThrough: return "passThrough"
        case .swallow: return "swallow"
        }
    }

    private static func describe(_ state: SessionState) -> String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .ending: return "ending"
        }
    }

    /// **Without the interval, deliberately.** What this drive has to show is the lifecycle fact —
    /// the owner's timer is armed while a session records and stopped once it ends. The cadence is a
    /// policy number that `SessionWatchdogTests` owns and `WatchdogPolicy.pollInterval` documents at
    /// length; spelling it into the expected line here would put a second copy of it in a test about
    /// networking, which would then fail for a deliberate change to a number it has no opinion on.
    private static func describe(_ schedule: WatchdogSchedule) -> String {
        switch schedule {
        case .stopped: return "stopped"
        case .wake: return "wake"
        }
    }

    private static func describe(keyCodes: [UInt16]) -> String {
        keyCodes.isEmpty ? "none" : keyCodes.map(String.init).joined(separator: ",")
    }

    /// The buffer an effect handed to custody, if it handed one over at all.
    ///
    /// `nil` covers both "no session ended" and "the session was cancelled", which are different
    /// facts — but the field that reports the effect itself already distinguishes them, and this one
    /// only has to say whether a buffer travelled.
    private static func capturedAudio(in effect: SessionEffect<ProbeCapture>) -> ProbeCapture? {
        switch effect {
        case .unchanged, .started, .captureUnavailable:
            return nil
        case .ended(let outcome):
            switch outcome.content {
            case .completed(_, let audio, _): return audio
            case .cancelled: return nil
            }
        }
    }

    private static func describe(ordinalOf capture: ProbeCapture?) -> String {
        capture.map { String($0.ordinal) } ?? "none"
    }

    private static func describe(framesOf capture: ProbeCapture?) -> String {
        capture.map { String($0.frames) } ?? "none"
    }

    /// A `Duration` in whole milliseconds.
    ///
    /// Written out rather than taken from `Duration`'s own description, which is a standard-library
    /// spelling this package does not control — the same reason every `describe` above is written by
    /// hand.
    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
