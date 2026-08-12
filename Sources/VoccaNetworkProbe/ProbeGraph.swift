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

import VoccaAudio

// The probe's half of the zero-network invariant for `VoccaAudio`.
//
// While `VoccaAudio` held a placeholder, naming `VoccaAudioPlaceholder` in the probe's module list
// was all the invariant could say about it. It now holds a capture graph, a ring, a converter and
// the `MicrophoneSource` conformance — and a metatype reference says nothing about any of them:
// the coverage guard in `ZeroNetworkTests` is at module granularity by construction, so it cannot
// tell a module that was *reached* from a module whose work was *run*.
//
// The shipped capture graph is the one file in this package CI cannot execute a line of
// (`AudioCaptureGraph.swift`'s header: no hosted runner has a microphone, and `AVAudioSinkNode`
// has no offline equivalent), so the probe stands a fake graph in its place — exactly as
// `MicrophoneSourceTests` does — and lets the **real** `MicrophoneSource`, the **real** ring and
// the **real** converter run against it. The graph is a ledger: every start and stop is counted,
// and the "mic opens" fact the cycle drive reports is read off this ledger, never off a believed
// call — the same custody discipline `ProbeMicrophone` applies one level up.

/// The capture graph, as the probe's scripted stand-in: a real ring behind the ``CaptureGraphSeam``.
///
/// `VoccaAudio`'s conformance is written against ``CaptureGraphSeam`` precisely so that this object
/// can exist: it satisfies the seam with a real ``AudioRingBuffer`` and the interchange format
/// (16 kHz mono — so the real ``AudioFormatConverter`` the `MicrophoneSource` builds runs as an
/// identity conversion, exactly the `MicrophoneSourceTests` shape), and the realtime producer is
/// replaced by ``deliver(_:)``, which writes whole blocks into the ring the way the interleaver's
/// sink callback would.
///
/// Everything the cycle drive reports about the microphone is read off this object's ledger:
/// ``starts``, ``stops`` and ``isRunning`` are the seam's own answers to "did the microphone open
/// and is it open now" — the release-before-return obligation `MicrophoneSource` discharges by
/// calling ``stop()`` first is observable here because ``stop()`` is synchronous and counted.
final class ProbeGraph: CaptureGraphSeam {

    /// The frames the drive's one scripted utterance consists of.
    ///
    /// **Known amplitudes and a known duration.** The amplitudes are the sample values `1, 2, 3`
    /// — the same values `StubEngine` (and the probe's own ``ProbeEngine``) transcribe into
    /// `"1 2 3"`, so the reported transcript is exact rather than a re-derivation; the duration is
    /// three frames at the seam's 16 kHz, which makes the hand-over's sample count a number a test
    /// can state. The values also exceed the 0...1 amplitude convention on purpose: nothing in the
    /// capture → transcribe path is allowed to care about the range, and a script that never
    /// exceeded it would not be able to say so.
    static let scriptedFrames: [Float] = [1, 2, 3]

    /// The ring the real `MicrophoneSource` drains at ``endCapture()``. Capacity eight: the
    /// scripted utterance fits whole, so the completeness link the drive reports is the honest 0.
    let ring: AudioRingBuffer

    /// The interchange format (16 kHz mono): the converter `MicrophoneSource` builds from this is
    /// an identity conversion, so the drive's reported frames are the ring's frames, unchanged.
    let captureFormat = CapturedAudioFormat.interchange

    /// The newest published input level — the `widget-live-states` surface of the seam. Fixed 0 in
    /// this ledger, for the same reason `MicrophoneSourceTests`' fake keeps it: the peak accounting
    /// is the interleaver's realtime body, which belongs to `MicrophoneLevelTests`, not to a probe
    /// that never runs a realtime callback.
    var levelPeak: Float = 0

    /// Whether the engine is running — the seam's own flag, written by ``start()``/``stop()``.
    private(set) var isRunning = false

    /// How many times the microphone was opened. The "mic opens" fact of the cycle report.
    private(set) var starts = 0

    /// How many times the microphone was closed. Read together with ``starts`` so that "the
    /// session ended" is distinguishable from "the device was released" (`ProbeMicrophone`'s
    /// ledger at one level up, spelled for the graph).
    private(set) var stops = 0

    /// - Parameter ringCapacity: the ring's capacity in samples. The scripted utterance is three
    ///   samples; the default's eight is plenty and keeps the ledger's numbers independent of it.
    init(ringCapacity: Int = 8) {
        self.ring = AudioRingBuffer(capacity: ringCapacity)
    }

    func start() throws {
        starts += 1
        isRunning = true
    }

    /// Close the microphone, and do not return until it is closed — the seam's release contract,
    /// which the real `MicrophoneSource`'s whole custody argument rests on.
    func stop() {
        stops += 1
        isRunning = false
    }

    /// The realtime producer, scripted: write `frames` into the ring whole, exactly as the
    /// interleaver's sink callback would (`MicrophoneSourceTests`' `write` helper, in probe form).
    ///
    /// - Returns: whether the block was accepted whole; a refused block is counted on the ring's
    ///   `refusedSampleCount`, which is how a script can make the completeness link non-zero.
    @discardableResult
    func deliver(_ frames: [Float]) -> Bool {
        frames.withUnsafeBufferPointer { pointer in
            ring.write(pointer.baseAddress!, count: pointer.count)
        }
    }
}
