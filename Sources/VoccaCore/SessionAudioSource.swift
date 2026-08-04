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
    func endCapture() -> Buffer
}
