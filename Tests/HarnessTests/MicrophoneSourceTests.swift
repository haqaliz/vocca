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

@testable import VoccaAudio

/// **The `SessionAudioSource` conformance over the capture graph — driven with a fake graph and a
/// real ring.**
///
/// This is Phase 5 of `audio-capture`, and its RED is the plan's three clauses, verbatim
/// (`plan_20260806.md` §Phase 5):
///
/// > a source whose ring refused samples hands over audio marked incomplete **and the number it
/// > carries equals the ring's `refusedSampleCount`**; a source that refused none hands over audio
/// > marked complete. All three clauses, because a one-bit flag satisfies "marked incomplete"
/// > exactly as written and throws away N — and *countable*, not merely *flagged*, is the entire
/// > justification for drop-newest. The negative case is there because "always incomplete" passes
/// > a one-sided test.
///
/// The conformance is written against ``CaptureGraphSeam`` — a protocol over `AudioCaptureGraph` —
/// precisely so that this file can execute it. The graph's own file is the one place
/// AVFoundation may be named and is executed by nothing in CI; the conformance names no
/// AVFoundation type, takes the graph through the seam, and so runs here for real, with a fake
/// graph in the engine's place and the **real** ring and the **real** converter in the path. The
/// fake graph is a ledger — "the device was released" is read off `stopCalls`, never off a
/// believed call, the way `project-skeleton`'s review demanded of every custody claim.
///
/// ## What the three clauses require of the design, and the tests that pin each
///
/// - **Clause 1 (refused → incomplete with the exact number)**:
///   ``testARingThatRefusedSamplesHandsOverAudioMarkedIncompleteWithTheExactCount``, and its
///   multi-channel form ``testARefusedBlockIsCarriedVerbatimInTheRingsOwnUnits``.
/// - **Clause 2 (the number is the count, not a flag)** is the *same* assertion — `missingSampleCount`
///   must equal the ring's counter, which a one-bit flag cannot.
/// - **Clause 3 (refused none → complete)**:
///   ``testARingThatRefusedNothingHandsOverAudioMarkedComplete`` — the negative case that fails an
///   "always incomplete" implementation — and its cross-session form
///   ``testRefusalsInOneSessionNeverMarkTheNextSessionIncomplete``, which pins that the count
///   carried is **this session's** refusal count and not the ring's lifetime total (the ring's
///   counter is cumulative since creation, so a naive pass-through marks every later session
///   incomplete after the first overrun).
final class MicrophoneSourceTests: XCTestCase {

    // MARK: - The three clauses, verbatim

    /// **Clause 1 + 2.** A ring that refused samples hands over audio that is short by exactly
    /// that many — the count, not a flag.
    func testARingThatRefusedSamplesHandsOverAudioMarkedIncompleteWithTheExactCount() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange)
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)

        write([0, 1, 2, 3, 4, 5, 6, 7], to: graph.ring)
        write([100, 101], to: graph.ring)
        XCTAssertEqual(graph.ring.refusedSampleCount, 2, "precondition: the second block was refused")

        let buffer = source.endCapture()

        XCTAssertEqual(
            buffer.missingSampleCount, 2,
            """
            The ring refused two samples and the hand-over must carry exactly that number — a count \
            that only says "incomplete" throws away N, which is the entire justification for \
            drop-newest being acceptable at all.
            """)
        XCTAssertEqual(buffer.samples, [0, 1, 2, 3, 4, 5, 6, 7], "the audio itself must be untouched")
        XCTAssertEqual(graph.stopCalls, 1, "the device must be released before the hand-over returns")
        XCTAssertFalse(graph.isRunning)
    }

    /// **Clause 3, the negative case.** A ring that refused nothing hands over audio marked
    /// complete — an implementation that marks everything incomplete passes the one-sided test
    /// and fails here.
    func testARingThatRefusedNothingHandsOverAudioMarkedComplete() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange)
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)
        write([0, 1, 2, 3, 4, 5, 6, 7], to: graph.ring)

        let buffer = source.endCapture()

        XCTAssertEqual(graph.ring.refusedSampleCount, 0, "precondition: nothing was refused")
        XCTAssertEqual(buffer.missingSampleCount, 0)
        XCTAssertEqual(buffer.samples, [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(buffer.sampleRate, AudioBuffer.interchangeSampleRate)
    }

    /// **Clause 3, across sessions.** The ring's refusal counter is cumulative since the ring was
    /// created, so a conformance that reads it once at `endCapture()` marks *every later* session
    /// incomplete after the first overrun. The hand-over must carry **this session's** refusals.
    func testRefusalsInOneSessionNeverMarkTheNextSessionIncomplete() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange)
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)
        write([0, 1, 2, 3, 4, 5, 6, 7], to: graph.ring)
        write([100, 101], to: graph.ring)
        XCTAssertEqual(graph.ring.refusedSampleCount, 2)
        XCTAssertEqual(source.endCapture().missingSampleCount, 2, "the short session reports short")

        XCTAssertEqual(source.beginCapture(), .opened)
        write([200, 201, 202, 203], to: graph.ring)
        let second = source.endCapture()

        XCTAssertEqual(
            second.missingSampleCount, 0,
            """
            The second session refused nothing and must hand over audio marked complete. The ring's \
            counter still says 2 — a hand-over built from the lifetime total would fail this clause.
            """)
        XCTAssertEqual(second.samples, [200, 201, 202, 203])
    }

    // MARK: - The rest of the seam's contract

    /// An empty press is a legitimate answer (`SessionAudioSource.endCapture()`), and it is
    /// **complete** — nothing was captured, so nothing was lost.
    func testAnEmptyPressHandsOverAnEmptyCompleteBuffer() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange)
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)
        let buffer = source.endCapture()

        XCTAssertTrue(buffer.samples.isEmpty)
        XCTAssertEqual(buffer.missingSampleCount, 0)
        XCTAssertEqual(graph.stopCalls, 1)
    }

    /// `AVAudioEngine.start()` can throw, and a session that believes it is recording while
    /// nothing is captured is a lie. The conformance maps it to `.unavailable` and touches nothing
    /// else — no stop is owed for an open that never happened.
    func testAnEngineThatRefusesToStartIsUnavailableAndStaysClosed() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange)
        graph.nextStart = .failure(StartRefused())
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .unavailable)
        XCTAssertEqual(graph.startAttempts, 1)
        XCTAssertFalse(graph.isRunning)
        XCTAssertEqual(graph.stopCalls, 0, "a start that failed owes no teardown")
    }

    // MARK: - A8 at the seam boundary

    /// **A8.** The seam boundary is 16 kHz mono Float32. A 48 kHz **stereo** capture — the ordinary
    /// built-in-input case — must arrive at the other side as 16 kHz mono, and the assertion that
    /// reads the rate off the *data* is the sample count: one second in, 16 000 samples out.
    func testTheHandOverAtTheSeamBoundaryIsExactlyTheInterchangeFormat() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 1 << 17),
            captureFormat: CapturedAudioFormat(sampleRate: 48_000, channelCount: 2))
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)
        write(Array(repeating: 0.5, count: 96_000), to: graph.ring)

        let buffer = source.endCapture()

        XCTAssertTrue(
            AudioBuffer.isValidFormat(sampleRate: buffer.sampleRate, channelCount: 1),
            "the hand-over must be exactly 16 kHz mono: got \(buffer.sampleRate) Hz")
        XCTAssertEqual(buffer.sampleRate, AudioBuffer.interchangeSampleRate)
        XCTAssertEqual(
            buffer.samples.count, 16_000,
            """
            one second at 48 kHz stereo must arrive as 16 000 mono frames — a rate or channel \
            regression changes this number and nothing else
            """)
        XCTAssertEqual(buffer.missingSampleCount, 0)
    }

    /// **The plan's clause 1, verbatim, at a non-trivial rate.** The number the hand-over carries
    /// *equals the ring's `refusedSampleCount`* — in the ring's own units, raw interleaved samples
    /// at the hardware rate. At 48 kHz stereo the ring counts 96 000 samples per second, and a
    /// refused block travels as that many raw samples, not a rescaling nobody has defined.
    func testARefusedBlockIsCarriedVerbatimInTheRingsOwnUnits() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 1 << 17),
            captureFormat: CapturedAudioFormat(sampleRate: 48_000, channelCount: 2))
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)
        write(Array(repeating: 0.5, count: 96_000), to: graph.ring)
        // A block larger than the remaining room: refused whole, so the drain still yields exactly
        // the 96 000 accepted samples — and the refused count is the block's own.
        write(Array(repeating: 0.25, count: 1 << 17), to: graph.ring)
        XCTAssertEqual(
            graph.ring.refusedSampleCount, 1 << 17, "precondition: the second block was refused")

        let buffer = source.endCapture()

        XCTAssertEqual(
            buffer.missingSampleCount, graph.ring.refusedSampleCount,
            "the plan's clause 1: the carried number equals the ring's counter, verbatim")
        XCTAssertEqual(buffer.samples.count, 16_000)
    }

    // MARK: - The machine holds it

    /// **The seam's own point, end to end:** `SessionMachine` holds this conformance as its
    /// `SessionAudioSource`, the hand-over it produces travels out of the machine's single custody
    /// funnel as a `VoccaCore.AudioBuffer` — the ASR seam's buffer, completeness link included —
    /// and the device is released before the machine goes `.idle`. This is the C1→C2 bridge the
    /// C2 seam recorded as gated on this merge.
    func testASessionThroughTheRealMachineCarriesTheCompletenessCountAndReleasesTheDevice() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange)
        let source = try MicrophoneSource(graph: graph)
        let machine = SessionMachine(
            configuration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: TestClock(),
            audioSource: source)

        XCTAssertEqual(machine.observe(Self.keyEvent(.keyDown, at: .zero)).effect, .started)
        write([0, 1, 2, 3, 4, 5, 6, 7], to: graph.ring)
        write([100, 101], to: graph.ring)

        let audio = try Self.endedAudio(
            machine.observe(Self.keyEvent(.keyUp, at: .zero)).effect)

        XCTAssertEqual(audio.missingSampleCount, 2)
        XCTAssertEqual(audio.samples, [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(audio.sampleRate, AudioBuffer.interchangeSampleRate)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(graph.stopCalls, 1, "the machine's funnel must have released the device")
        XCTAssertFalse(graph.isRunning, "the machine went idle over a live microphone")
    }

    // MARK: - Helpers

    /// The graph, as a **ledger**. It uses a real `AudioRingBuffer`, because the conformance's
    /// end-to-end path — drain, convert, counter — is only real if the ring is; and it records
    /// every start and stop so that custody is asserted off the ledger, never off a believed call.
    private final class FakeCaptureGraph: CaptureGraphSeam {
        let ring: AudioRingBuffer
        let captureFormat: CapturedAudioFormat
        private(set) var startAttempts = 0
        private(set) var stopCalls = 0
        private(set) var isRunning = false
        var nextStart: Result<Void, Error> = .success(())

        init(ring: AudioRingBuffer, captureFormat: CapturedAudioFormat) {
            self.ring = ring
            self.captureFormat = captureFormat
        }

        func start() throws {
            startAttempts += 1
            switch nextStart {
            case .success:
                isRunning = true
            case .failure(let error):
                throw error
            }
        }

        func stop() {
            stopCalls += 1
            isRunning = false
        }
    }

    private struct StartRefused: Error {}

    /// Write `samples` into `ring` the way the realtime producer would — whole blocks, refused
    /// whole when there is no room.
    private func write(_ samples: [Float], to ring: AudioRingBuffer) {
        _ = samples.withUnsafeBufferPointer { pointer in
            ring.write(pointer.baseAddress!, count: pointer.count)
        }
    }

    private static func keyEvent(_ kind: RawKeyEvent.Kind, at timestamp: Duration) -> RawKeyEvent {
        RawKeyEvent(
            kind: kind, keyCode: 49, modifiers: [.option], isAutorepeat: false, timestamp: timestamp)
    }

    /// The audio an ended session handed to custody, or a test failure.
    private static func endedAudio(_ effect: SessionEffect<AudioBuffer>) throws -> AudioBuffer {
        switch effect {
        case .ended(let outcome):
            switch outcome.content {
            case .completed(_, let audio, _):
                return audio
            case .cancelled:
                XCTFail("a key-up is not a cancellation: the audio it captured is owed downstream")
                throw XCTSkip("no audio")
            }
        case .unchanged, .started, .captureUnavailable, .opening:
            XCTFail("expected the session to end, got \(effect)")
            throw XCTSkip("no outcome")
        }
    }
}
