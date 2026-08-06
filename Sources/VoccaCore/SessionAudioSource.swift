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

/// Whether the microphone opened.
///
/// A two-case enum rather than a `Bool` for the reason every other enum in this module is one: it is
/// switched exhaustively and without a `default:`, so a third answer — "opened, but degraded", say —
/// is a compile error at the one place that has to decide what it means, rather than something that
/// quietly inherits the failure branch.
public enum CaptureStart: Sendable, Hashable, CaseIterable {
    /// Audio is being captured from here until ``SessionAudioSource/endCapture()``.
    case opened

    /// The microphone did not open. `AVAudioEngine.start()` throws for a device that vanished
    /// between the press and the start, and a session that believes it is recording while nothing
    /// is captured is the widget lying about a hot mic in the harmless direction — still a lie.
    case unavailable
}

/// The microphone, as the session machine is permitted to know it: **open it, close it, take what it
/// captured.**
///
/// Three methods' worth of surface reduced to two, deliberately. This is not the `AudioCapture` seam
/// of `ARCHITECTURE.md` §5 and must not grow into it — formats, ring-buffer capacity, conversion and
/// the realtime discipline all belong to the `audio-capture` aspect, below this line. What is here
/// is the part the *lifecycle* owns, sized so that the machine cannot do anything to the microphone
/// except the two things custody depends on.
///
/// ## Why the machine holds this at all
///
/// It could have been the caller's job: the machine returns "you should stop", the caller closes the
/// microphone and passes the buffer somewhere. That shape cannot enforce either invariant. "A
/// transcript is never lost" then depends on a caller remembering to route the buffer, and "the
/// microphone is not open while the widget says nothing is happening" depends on a caller
/// remembering to close it — which is precisely the class of defect this aspect exists to remove.
/// With the seam here, every terminal path *is* a close, because there is exactly one funnel and it
/// closes the microphone itself.
///
/// It is also what makes the acceptance tests meaningful: `project-skeleton`'s final review earned
/// the rule "assert the effect, never the reference", and its worked example is this one — *"`stop()`
/// was called" is not "the microphone was released"*. A test drives the machine and reads the
/// **source's** ledger.
///
/// ## Why it is class-bound
///
/// Capturing audio is stateful, and the implementations are reference types: `AVAudioEngine` behind
/// the real one, a ledger behind the test one. A value-typed conformance would be copied into the
/// machine, and every mutation it made would be invisible to the object the caller still holds — so
/// "the microphone was released" would be unobservable from outside, which is the one thing this
/// seam exists to make observable.
public protocol SessionAudioSource<Buffer>: AnyObject {
    /// What a session captured. Constrained to ``CapturedAudio`` for the reason that protocol
    /// documents: it is what stops the *absence* of a buffer from satisfying the obligation to
    /// produce one.
    associatedtype Buffer: CapturedAudio

    /// Open the microphone. Called at most once per session, and never while already open.
    ///
    /// ## It is allowed to be slow, and it is measured
    ///
    /// **`AVAudioEngine.start()`: 114 ms median, 119 ms p99, 127 ms worst**, over 120 verified
    /// sessions on an M4 Max — `Scripts/measure-engine-start.sh`, tabulated on ``CaptureStartTiming``.
    /// A conformance is not expected to beat that and must not cut corners to try: it may not return
    /// before the microphone is open, because the machine takes the return as the open and goes
    /// `.recording` on it.
    ///
    /// **It is not called from the tap callback**, and that is what makes the cost affordable.
    /// ``CaptureStartTiming/whenTheOwnerAsks`` is the shipped timing, so this runs on a later turn of
    /// the run loop with the callback already returned. See ``HotkeyEventSink/receive(_:)``.
    ///
    /// Everything a caller may do *during* this call is settled and tested: a second start is
    /// refused, and a stop — a key-up, an Escape, a tap death — is held and applied the instant the
    /// session exists. At 114 ms those are not edge cases. A hotkey tapped for less than that ends
    /// its session on the same run-loop turn it starts it, with whatever audio the opening caught.
    func beginCapture() -> CaptureStart

    /// Close the microphone and hand over what was captured.
    ///
    /// Called **exactly once** for every ``beginCapture()`` that returned ``CaptureStart/opened``,
    /// including on cancellation — discarding a transcript and leaving the microphone open are
    /// different things, and only the first is ever the user's instruction.
    ///
    /// An empty buffer is a legitimate answer: a 20 ms press captured almost nothing, and that is
    /// still a real session that ended for a real reason. It is not a way to say "nothing was
    /// captured", because there is no such thing to say — see ``CapturedAudio``.
    ///
    /// ## This must not return until the input device is released
    ///
    /// Read that as the obligation it is, before writing a conformance. Returning is the **only**
    /// thing this method can do — there is no failure case in the signature and deliberately no
    /// error to throw — so a conformance whose teardown fails has no way to say so. The machine
    /// takes the return as the close, goes `.idle`, and from that instant the widget shows idle over
    /// a live microphone: the exact state `PRODUCT_SPEC.md:11` exists to make impossible, arrived at
    /// silently.
    ///
    /// Nothing upstream catches it either, and it is worth knowing why rather than assuming someone
    /// will. `.idle` is a claim about *this call having returned*, not about the device; the
    /// watchdog's schedule is `.stopped` in `.idle` and its `wake()` returns before reading
    /// anything, so **no mechanism in this aspect ever looks again**. The whole defence is the
    /// conformance author knowing this before they write the conformance.
    ///
    /// So: **a conformance that can fail to release the input must trap rather than return.** A
    /// crash naming this line is a bad outcome; an open microphone the user cannot see is a worse
    /// one, and it is the one this project promised would not happen.
    func endCapture() -> Buffer
}
