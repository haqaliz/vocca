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
import XCTest

// The two stateful doubles the session machine is driven through, shared by
// `SessionMachineTests` and `SessionWatchdogTests`.
//
// Shared rather than copied, because copying is how this repository ended up with five
// near-identical `packageRoot` walkers and a rule in `spec.md` about not writing a sixth. The small
// POD fixtures — a key code, a chord, an `event(...)` builder — stay file-private in each suite,
// where they already were in two: they are three lines each, they carry no behaviour, and a shared
// one would make every test's inputs one indirection further from the test.
//
// These two are the opposite: `RecordingSource` is a ledger with semantics that took a review round
// to settle (the begin hook fires on both outcomes; both hooks are one-shot), and a second copy that
// drifted from this one would let a watchdog test pass against a microphone that behaves differently
// from the one the machine's own tests use.

/// A clock the test moves by hand. Instant, deterministic, and monotonic unless a test says
/// otherwise — several of them deliberately run it backwards.
final class TestClock: MonotonicClock {
    var now: Duration = .zero
}

/// The microphone, as the session machine is allowed to know it: open it, close it, take what it
/// captured.
///
/// It is a **ledger**, and that is the point. "The session ended" is not "the microphone was
/// released" — `project-skeleton`'s final review earned that distinction with a defect that shipped
/// past a green suite — so every assertion about custody or about a hot mic is made against what
/// this recorded, never against a call the machine is believed to have made.
///
/// Each buffer it hands out is unique (`session:` is the close count), so an outcome carrying "a"
/// buffer and an outcome carrying **this session's** buffer are distinguishable. Without that, a
/// machine that swapped in a fresh empty buffer would pass every custody test in the suite.
final class RecordingSource: SessionAudioSource {
    struct Buffer: CapturedAudio, Equatable {
        let session: Int
        let frames: [Int]
    }

    private(set) var isOpen = false
    private(set) var beginCount = 0
    private(set) var endCount = 0
    /// `beginCapture()` while already open. B1's "0 overlapping", measured rather than assumed.
    private(set) var overlappingBegins = 0
    /// `endCapture()` while closed — a close with no open, which is the other half of "0 orphaned".
    private(set) var closesWithoutOpen = 0
    private(set) var handedOut: [Buffer] = []

    /// What the next `beginCapture()` reports. The microphone can genuinely refuse to open.
    var nextStart: CaptureStart = .opened

    /// Run from *inside* `endCapture()`, while the machine is mid-handoff. This is how re-entrancy
    /// is tested: stopping a real engine can pump a run loop and deliver a queued key event straight
    /// back into the machine.
    ///
    /// Fired once and then cleared, like ``duringBeginCapture``. Both hooks are one-shot for the
    /// same measured reason: a machine that honours a stop while `.ending` re-enters this method
    /// from inside itself, and with a repeating hook that is an unbounded recursion — the suite goes
    /// red with `signal 11` instead of naming the invariant that broke.
    var duringEndCapture: (() -> Void)?

    /// The same, for the other transition. `AVAudioEngine.start()` is the one that actually takes
    /// milliseconds, so it is the likelier of the two to have an event arrive underneath it. Fired
    /// once and then cleared, because a hook that re-enters the call it is inside of would recurse
    /// forever if the machine let it — which is the failure being tested, not a way to test it.
    var duringBeginCapture: (() -> Void)?

    func beginCapture() -> CaptureStart {
        if isOpen { overlappingBegins += 1 }

        // Fired before the outcome is decided, and on **both** paths. An engine that fails to start
        // still spent the time trying, and events still arrive underneath it — a hook that only ran
        // on success made the leak test vacuous, and a mutation that let a deferred stop outlive its
        // opening survived because of it.
        let hook = duringBeginCapture
        duringBeginCapture = nil
        hook?()

        guard nextStart == .opened else { return .unavailable }
        beginCount += 1
        isOpen = true
        return .opened
    }

    func endCapture() -> Buffer {
        if !isOpen { closesWithoutOpen += 1 }
        endCount += 1
        isOpen = false
        let hook = duringEndCapture
        duringEndCapture = nil
        hook?()
        let buffer = Buffer(session: endCount, frames: Array(repeating: endCount, count: 3))
        handedOut.append(buffer)
        return buffer
    }
}

// MARK: - The physical keyboard, and the seam that reads it

/// The physical keyboard, as a **fact**.
///
/// The distinction the watchdog turns on: what the hardware is doing is one thing, what Vocca has
/// been *told* is another, and the gap between them is the defect. A hot-mic meter reads this; the
/// watchdog only ever reads it through the injected seam. That is what lets a test hand the watchdog
/// a seam that lies and still measure the truth.
///
/// Shared with `HotkeyEventSourceTests` for the same reason ``RecordingSource`` is: a session driven
/// through the `HotkeyEventSource` seam is polled by the same watchdog against the same keyboard, and
/// a second copy that drifted from this one would let a seam test pass against a keyboard that
/// behaves differently from the one the watchdog's own tests use.
final class Keyboard {
    private(set) var held: Set<UInt16> = []

    /// The modifiers physically held, which is a fact about the same keyboard and is therefore
    /// modelled here rather than on the reader. `CGEventSourceFlagsState` reports the word, not the
    /// individual keys, so there is nothing to be gained from modelling left and right separately —
    /// and something to be lost, because the seam cannot express the difference either.
    ///
    /// Defaults to empty, so a test that starts a session with a chord and never says the user is
    /// holding it ends that session on the first wake. That is deliberate: a keyboard whose modifiers
    /// defaulted to "whatever the binding needs" could never fail, which is the shape of double this
    /// suite exists to avoid.
    var heldModifiers: ModifierSet = []

    func press(_ keyCode: UInt16) { held.insert(keyCode) }
    func release(_ keyCode: UInt16) { held.remove(keyCode) }
    func isHeld(_ keyCode: UInt16) -> Bool { held.contains(keyCode) }

    /// Hold the whole binding: the key and its chord, together, because that is what a user does.
    func hold(_ configuration: HotkeyConfiguration) {
        press(configuration.keyCode)
        heldModifiers = configuration.modifiers
    }
}

/// A reader that counts, so that "the poll ran and ended nothing" is distinguishable from "the poll
/// stopped running" — which are the same green suite otherwise.
protocol CountingKeyStateReader: PhysicalKeyStateReader {
    var reads: Int { get }
    var keysAsked: Set<UInt16> { get }

    /// Counted separately from ``reads``, because the two do **not** happen the same number of
    /// times: `SessionWatchdog.theBindingIsStillHeld` short-circuits, so the chord is asked for only
    /// on the wakes where the key was still down. One combined counter would make "the chord read
    /// happens" and "the chord read is skipped once the key is up" the same number.
    var modifierReads: Int { get }
}

/// The seam, reading the keyboard truthfully. What `hotkey-source` implements over
/// `CGEventSourceKeyState` and `CGEventSourceFlagsState`.
final class TruthfulKeyState: CountingKeyStateReader {
    private let keyboard: Keyboard
    private(set) var reads = 0
    private(set) var keysAsked: Set<UInt16> = []
    private(set) var modifierReads = 0

    init(_ keyboard: Keyboard) { self.keyboard = keyboard }

    func isKeyDown(_ keyCode: UInt16) -> Bool {
        reads += 1
        keysAsked.insert(keyCode)
        return keyboard.isHeld(keyCode)
    }

    var physicalModifiers: ModifierSet {
        modifierReads += 1
        return keyboard.heldModifiers
    }
}

/// A seam that never reports a release — **the world before the watchdog**, and the positive
/// control.
///
/// Not a straw man: it is exactly what a poll that is never run, run against the wrong key code, or
/// answered from a stale event log looks like from the machine's side. Everything else about a
/// harness built on it is identical, so a measurement that cannot tell the two apart is measuring
/// nothing.
///
/// It reports **every** modifier held as well as every key, and it has to: with the chord now half of
/// what the poll reads, a control that reported an empty chord would end sessions rather than never
/// ending them — the opposite of the thing it is a control for.
final class KeyAlwaysReportedDown: CountingKeyStateReader {
    private(set) var reads = 0
    private(set) var keysAsked: Set<UInt16> = []
    private(set) var modifierReads = 0

    func isKeyDown(_ keyCode: UInt16) -> Bool {
        reads += 1
        keysAsked.insert(keyCode)
        return true
    }

    var physicalModifiers: ModifierSet {
        modifierReads += 1
        return [.control, .option, .shift, .command, .function, .capsLock]
    }
}

/// Milliseconds, for arithmetic `Duration` will not do directly.
func milliseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
}

/// How many wakes it takes to cover `duration` at the watchdog's cadence, rounded down.
func wakes(covering duration: Duration) -> Int {
    Int(milliseconds(duration) / milliseconds(WatchdogPolicy.pollInterval))
}

/// Unwraps the outcome of an effect that must have ended a session.
///
/// Shared for the same reason the ledger above is: both suites end sessions and both have to fail
/// the same way when one does not end.
func endedOutcome(
    _ effect: SessionEffect<RecordingSource.Buffer>, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) throws -> SessionOutcome<RecordingSource.Buffer> {
    switch effect {
    case .ended(let outcome):
        return outcome
    case .unchanged, .started, .captureUnavailable, .opening:
        XCTFail("Expected a session to end, got \(effect). \(message)", file: file, line: line)
        throw XCTSkip("no outcome")
    }
}
