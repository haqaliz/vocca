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

import AVFAudio
import CoreAudioTypes
import VoccaCore
import XCTest

@testable import VoccaAudio

/// **The real input level: the `LiveLevelSource` conformance over the capture graph.**
///
/// `widget-live-states` Task 4 — the waveform's "it heard me" signal made real. The level is
/// computed in the capture graph's realtime callback (``AudioBufferListInterleaver/interleave``,
/// the `AVAudioSinkNode` block itself) over the just-written window and published to an atomic; the
/// main actor reads it through the seam. This file drives the **real** callback body — the same
/// shape `AudioBufferListInterleavingTests` uses, a hand-built `AudioBufferList` through the real
/// interleaver into a real ring — so the peak accounting and the publish path are executed by CI
/// even though the sink node itself never is. The graph's own file contributes nothing but the
/// forwarding (`AudioCaptureGraph.levelPeak`, `isRunning`), both reads of tested structures.
///
/// The two contracts pinned here:
///
/// - **`latestLevel()` tracks the peak.** The value is the greatest sample magnitude of the newest
///   callback — the honest reading of "how loud is the input right now" (`PRODUCT_SPEC.md:87`), and
///   deliberately *not* a lifetime maximum: a waveform that holds yesterday's shout while the user
///   whispers would be a lie about the current input.
/// - **`latestLevel()` is 0 when the graph is stopped or idle.** The engine only runs during
///   sessions (`AudioCaptureGraph`'s header: a warm engine lights the orange dot), so a stopped
///   graph has no callbacks and no level — the read answers 0 the moment the session ends, which is
///   the "decaying to 0" half of the seam's contract. The gate is the graph's own `isRunning`
///   (`AudioCaptureGraph.swift` reads it off the engine rather than remembering it), forwarded
///   through the seam so this file can drive it.
final class MicrophoneLevelTests: XCTestCase {

    // MARK: - The accounting (direct)

    /// The peak of a known window is the greatest magnitude, sign ignored — the level's definition
    /// is "how loud", and loudness does not care which side of zero the sample sat on.
    func testThePeakAccountingTracksTheGreatestAmplitudeIgnoringSign() {
        let samples: [Float] = [0.1, 0.4, -0.9, 0.2, -0.3]
        XCTAssertEqual(
            peak(of: samples), 0.9,
            "the level must be the greatest magnitude in the window, not the greatest signed value")
    }

    /// Silence is a zero level, not a crash and not a negative number: an empty window and an
    /// all-zero window both answer 0 — the waveform's silent-bars state is the honest rendering of
    /// a quiet microphone.
    func testThePeakAccountingIsZeroForSilenceAndEmptyWindows() {
        XCTAssertEqual(peak(of: []), 0)
        XCTAssertEqual(peak(of: [0, 0, 0, 0]), 0)
    }

    /// The accounting must never exceed 1.0 for input in range — a level that lies about the range
    /// makes the waveform lie about the voice (`LiveLevelSource.swift`'s contract).
    func testThePeakAccountingStaysInTheUnitRange() {
        XCTAssertEqual(peak(of: [0.5, 1.0, 0.25]), 1.0)
        XCTAssertEqual(peak(of: [-1.0, 0.5]), 1.0)
    }

    // MARK: - The conformance, end to end

    /// The published level tracks the **newest** callback's peak, not a lifetime maximum — the
    /// waveform must fall when the voice falls.
    func testThePublishedLevelTracksTheNewestCallbackNotALifetimeMaximum() throws {
        let (source, graph) = makeSource()

        try graph.start()
        feed([0.1, 0.9, -0.8, 0.2], into: graph)
        XCTAssertEqual(source.latestLevel(), 0.9, accuracy: 0.0001)

        feed([0.1, 0.1, 0.2, 0.15], into: graph)
        XCTAssertEqual(
            source.latestLevel(), 0.2, accuracy: 0.0001,
            "a quieter block must lower the level — a lifetime maximum would hold the 0.9 shout")

        feed([0.5, -0.5, 0.3], into: graph)
        XCTAssertEqual(source.latestLevel(), 0.5, accuracy: 0.0001)
    }

    /// The level is 0 while the graph is **stopped**, even if the callback published a peak while
    /// it was running — the seam's "decaying to 0 when the graph is stopped/idle" half. A session
    /// that ends must not leave a ghost level for the widget to draw.
    func testTheLevelIsZeroWhileTheGraphIsStopped() throws {
        let (source, graph) = makeSource()

        XCTAssertEqual(source.latestLevel(), 0, "idle before the first session: no level at all")

        try graph.start()
        feed([0.8, 0.7, 0.6], into: graph)
        XCTAssertEqual(source.latestLevel(), 0.8, accuracy: 0.0001)

        graph.stop()
        XCTAssertEqual(
            source.latestLevel(), 0,
            "a stopped graph must answer zero — the microphone is closed, so the widget must not "
                + "draw the last session's level over the next state")
    }

    /// Frames fed while the graph is stopped publish nothing: the callback only runs while the
    /// engine runs, so the gate must hold even if a late block arrives through the ring.
    func testFramesFedWhileStoppedDoNotWakeTheLevel() throws {
        let (source, graph) = makeSource()
        feed([0.9, 0.8], into: graph)
        XCTAssertEqual(source.latestLevel(), 0, "the graph never started — the block published nothing")
    }

    /// A full lifecycle: each session starts from silence, tracks its own input, and returns to
    /// silence on stop — the level must never carry one session's peak into the next.
    func testEachSessionPublishesItsOwnPeakAndStoppingReturnsToSilence() throws {
        let (source, graph) = makeSource()

        try graph.start()
        feed([0.6, 0.6], into: graph)
        XCTAssertEqual(source.latestLevel(), 0.6, accuracy: 0.0001)
        graph.stop()
        XCTAssertEqual(source.latestLevel(), 0)

        try graph.start()
        XCTAssertEqual(
            source.latestLevel(), 0,
            "a fresh session must start silent — the previous session's peak must not survive")
        feed([0.3, 0.3, 0.3], into: graph)
        XCTAssertEqual(source.latestLevel(), 0.3, accuracy: 0.0001)
        graph.stop()
        XCTAssertEqual(source.latestLevel(), 0)
    }

    // MARK: - Helpers

    /// A level source over a fake graph: a real ring and the **real interleaver** — the callback
    /// body whose peak accounting ships — driven by hand-built `AudioBufferList` values, exactly as
    /// `AudioBufferListInterleavingTests` drives the copy. The fake models the graph's two level
    /// surfaces: `levelPeak` forwards the interleaver's published peak, `isRunning` is a ledger of
    /// its own start/stop calls.
    private final class FakeLevelGraph: CaptureGraphSeam {
        let ring: AudioRingBuffer
        let interleaver: AudioBufferListInterleaver
        let captureFormat = CapturedAudioFormat.interchange
        private(set) var startAttempts = 0
        private(set) var stopCalls = 0
        private(set) var isRunning = false

        var levelPeak: Float { interleaver.levelPeak }

        init() {
            ring = AudioRingBuffer(capacity: 1 << 10)
            interleaver = AudioBufferListInterleaver(
                channelCount: 1, maximumFrameCount: 256, ring: ring)
        }

        func start() throws {
            startAttempts += 1
            isRunning = true
        }

        func stop() {
            stopCalls += 1
            isRunning = false
            // Mirrors AudioCaptureGraph.stop(): the engine is torn down first, then the published
            // level is cleared so a fresh session starts silent — never the previous session's peak.
            interleaver.resetPublishedLevel()
        }
    }

    private func makeSource() -> (source: MicrophoneLevelSource, graph: FakeLevelGraph) {
        let graph = FakeLevelGraph()
        return (MicrophoneLevelSource(graph: graph), graph)
    }

    private func peak(of samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { pointer in
            MicrophoneLevelSource.peak(of: pointer.baseAddress!, count: pointer.count)
        }
    }

    private func feed(_ samples: [Float], into graph: FakeLevelGraph) {
        withList([(channels: 1, samples: samples)]) { list in
            XCTAssertTrue(graph.interleaver.interleave(from: list, frameCount: samples.count))
        }
    }

    /// Runs `body` with a hand-built `AudioBufferList` — the `AudioBufferListInterleavingTests`
    /// helper, duplicated here so this file drives the callback body the same way that one drives
    /// the copy. The sample storage lives for the duration of the call and is freed on exit.
    private func withList<T>(
        _ buffers: [(channels: Int, samples: [Float]?)],
        _ body: (UnsafePointer<AudioBufferList>) throws -> T
    ) rethrows -> T {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        var storage: [UnsafeMutableRawPointer] = []
        for (index, buffer) in buffers.enumerated() {
            list[index].mNumberChannels = UInt32(buffer.channels)
            if let samples = buffer.samples {
                let memory = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
                memory.initialize(from: samples, count: samples.count)
                storage.append(UnsafeMutableRawPointer(memory))
                list[index].mData = storage.last
                list[index].mDataByteSize = UInt32(samples.count * MemoryLayout<Float>.size)
            } else {
                list[index].mData = nil
                list[index].mDataByteSize = 0
            }
        }
        defer {
            for memory in storage { memory.deallocate() }
        }
        return try body(UnsafePointer(list.unsafeMutablePointer))
    }
}
