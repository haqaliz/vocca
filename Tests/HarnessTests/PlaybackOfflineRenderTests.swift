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
import Synchronization
import VoccaCore
import XCTest

@testable import VoccaAudio

/// **The real adapter, executed headlessly: `SystemPlaybackOutput` through manual-rendering
/// mode.** (`playback-ducking` of `turn-taking-barge-in`, plan
/// `docs/planning/turn-taking-barge-in/playback-ducking/plan_20260915.md`, Vetted fact 3.)
///
/// `AVAudioSinkNode` is unsupported in manual rendering mode on the capture side — that is the
/// *input* direction. The *output* direction is what manual rendering mode is for (offline
/// processing, the engine disconnected from audio hardware), and `AVAudioSourceNode`'s render
/// block is documented to run on the **non-realtime thread** there. So these three tests drive
/// the real adapter — source node, ring, render-block envelope — headlessly, the strongest CI
/// evidence the output path can have:
///
/// 1. A 1 s, 1 kHz, 22050 Hz mono sine renders **sample-for-sample** — the frame count is
///    exact and the recovered frequency (zero-crossing estimate) is 1 kHz: the
///    `AudioFormatConverterTests` two-measure discipline (count + signal).
/// 2. A duck mid-play and a halt land as **ramps, not cuts**: the pre-duck audio is at full
///    gain, the reconstructed envelope gain is monotone non-increasing to zero over exactly
///    `rampDuration × rate` frames, and **no sample after the ramp exceeds the silence floor**
///    — the "no leaked tail" claim, asserted on rendered audio.
/// 3. A 3 s clip — larger than the ring's ~1.5 s capacity — renders whole with the signal
///    intact: the producer's wait-for-room backpressure engages and never drops a frame.
///
/// ## The recorded fallback (binding, plan Vetted fact 3)
///
/// If `enableManualRenderingMode`/`start()`/`renderOffline` proves unavailable on the CI
/// runner, these tests are **removed with the environmental failure recorded** — never skipped
/// and passed, never silently deleted — the state-machine suite above the seam becomes the
/// whole headless proof, and SMOKE 132 (`barge-in-loop`) is the output path's first real
/// execution. This file's presence is that claim's record: it ships only with the fallback's
/// reason recorded in the plan's execution notes.
final class PlaybackOfflineRenderTests: XCTestCase {

    /// **The count + signal discipline, on rendered audio.** A 1 s 1 kHz sine at 22050 Hz mono
    /// plays through the real adapter in manual-rendering mode: the first 22050 rendered frames
    /// match the input sample-for-sample (within 1e-6), the recovered frequency is 1 kHz via
    /// the zero-crossing estimate, and everything after the clip is exact silence (the render
    /// block's zero-fill, never a leaked or invented tail).
    func testOfflinePlaybackRendersKnownChunksSampleForSample() async throws {
        let sine = Self.sine(frequency: 1000, sampleRate: 22_050, frames: 22_050)
        let (rendered, output) = try await Self.render(
            stream: Self.stream([Self.chunk(frames: sine)]))

        XCTAssertGreaterThanOrEqual(
            rendered.count, 22_050,
            "the full clip must render — the drain poll returns only after every frame is rendered")

        let maxDelta = zip(rendered.prefix(22_050), sine).reduce(Float(0)) { partial, pair in
            max(partial, abs(pair.0 - pair.1))
        }
        XCTAssertLessThan(
            maxDelta, 1e-6,
            "the rendered clip must equal the input sample-for-sample, max |delta| = \(maxDelta)")

        XCTAssertTrue(
            rendered[22_050...].allSatisfy { $0 == 0 },
            "the rendered tail beyond the clip is exact silence — the ring's zero-fill, nothing invented")

        let frequency = Self.zeroCrossingFrequency(
            frames: Array(rendered.prefix(22_050)), sampleRate: 22_050)
        XCTAssertEqual(
            frequency, 1000, accuracy: 5,
            "the recovered frequency must be 1 kHz — count plus signal, not count alone")
    }

    /// **A duck and a halt are ramps, not cuts — asserted on the rendered audio.** A third of the
    /// clip plays at full gain; `duck()` then a third at the duck target; `cancelToSilence()`
    /// then the halt. The reconstructed envelope gain (sample ÷ known sine, where the sine is
    /// strong) is monotone non-increasing to zero over exactly `rampDuration × rate` frames —
    /// the frame-quantized twin of the clock-axis contract — intermediate gains exist (a cut
    /// would jump straight to zero), and **no sample after the ramp exceeds the silence floor**:
    /// the tail after the ramp's end is exactly zero, nothing leaks past the halt.
    ///
    /// The clip is the same 24576-frame-quantum-aligned shape as the backpressure test — a
    /// ~3.3 s clip — because the duck and the cancel must land mid-clip with margin: the pump's
    /// render passes are 4096 frames, so a 1 s clip's "thirds" collide with the clip's end (the
    /// ring would drain before the cancel). With one render quantum of slack on each side, the
    /// segments land exactly as the plan's "a third, duck, a third, cancel" describes.
    func testOfflinePlaybackDucksAndHaltsWithARampNotACut() async throws {
        let chunkFrames = 6 * 4_096
        let clipFrames = 3 * chunkFrames
        let sine = Self.sine(frequency: 1000, sampleRate: 22_050, frames: clipFrames)
        let chunks = [
            Self.chunk(frames: Array(sine[0..<chunkFrames])),
            Self.chunk(frames: Array(sine[chunkFrames..<(2 * chunkFrames)])),
            Self.chunk(frames: Array(sine[(2 * chunkFrames)..<clipFrames])),
        ]
        let real = SystemPlaybackOutput(manualRendering: true)
        let output = HaltObservingOutput(wrapping: real)
        let engine = SystemPlayback(level: .default, clock: OfflineClock(), output: output)
        let done = CompletionFlag()
        let playTask = Self.playToCompletion(engine, Self.stream(chunks), done)
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let isDone = { done.isDone }

        // A third at full gain, then the duck.
        var rendered = try await Self.pump(real, format: format, target: chunkFrames, done: isDone)
        await engine.duck()

        // A third at the duck target — the target is each pump call's own local count, so this
        // segment renders one more third, not two.
        rendered += try await Self.pump(real, format: format, target: chunkFrames, done: isDone)

        // The last third renders **while the halt runs**. Two rendezvous make it deterministic:
        // first the producer's completion (the whole clip's frames observed through the seam —
        // the cancel must never land between the producer's chunks, or the last chunk is
        // correctly refused and the ramp has nothing to ride on), then the halt's `setGain(0)`
        // (the ramp is armed before the first render that drains the remaining audio). The
        // halt's 20 ms clock wait is then the window in which the pump renders the ramp.
        try await Self.waitUntil("the producer's whole clip") {
            output.enqueuedFrameCount >= clipFrames
        }
        let cancelTask = Task { await engine.cancelToSilence() }
        try await Self.waitUntil("the halt's setGain(0)") { output.haltArmed.isDone }
        rendered += try await Self.pump(real, format: format, target: .max, done: isDone)
        await cancelTask.value
        try await playTask.value

        let duckPoint = chunkFrames
        let cancelPoint = 2 * chunkFrames
        let rampFrames = 441  // 20 ms × 22050 Hz, the shipped default

        let preDuckDelta = zip(rendered.prefix(duckPoint), sine.prefix(duckPoint))
            .reduce(Float(0)) { partial, pair in max(partial, abs(pair.0 - pair.1)) }
        XCTAssertLessThan(
            preDuckDelta, 1e-6,
            "the pre-duck audio is at full gain — the duck has not touched it yet")

        // The duck's flat region: between the duck's ramp end (one buffer of slack) and the
        // cancel, the gain is exactly the duck target.
        let duckFlatStart = duckPoint + 4_096 + rampFrames
        if duckFlatStart < cancelPoint {
            let duckDelta = zip(rendered[duckFlatStart..<cancelPoint], sine[duckFlatStart..<cancelPoint])
                .reduce(Float(0)) { partial, pair in max(partial, abs(pair.0 - pair.1 * 0.5)) }
            XCTAssertLessThan(
                duckDelta, 1e-6,
                "between the duck's ramp and the halt the gain is exactly the 0.5 duck target")
        }

        // The envelope gain, reconstructed where the sine is strong: rendered ÷ known sine.
        let gains = (duckPoint..<min(rendered.count, sine.count)).compactMap { index -> Float? in
            guard abs(sine[index]) > 0.5 else { return nil }
            return rendered[index] / sine[index]
        }
        XCTAssertFalse(gains.isEmpty, "the envelope must be measurable across the duck and the halt")
        var last = Float(2)
        var violations = 0
        for gain in gains {
            if gain > last + 1e-6 { violations += 1 }
            last = min(last, gain)
        }
        XCTAssertEqual(
            violations, 0,
            "the envelope gain must be monotone non-increasing to zero — \(violations) rises")

        // The ramp is a ramp: intermediate gains exist between the duck target and zero.
        let rampRegion = gains.filter { $0 > 0.05 && $0 < 0.45 }
        XCTAssertFalse(
            rampRegion.isEmpty,
            "the halt must duck through intermediate gains — a cut would jump 0.5 → 0")

        // The ramp's length: the ramp begins where the gain first leaves the 0.5 duck target,
        // and ends where the gain is zero and stays zero.
        let rampStart = Self.firstBelowThreshold(
            in: rendered, from: cancelPoint, sine: sine, threshold: 0.499)
        let firstZero = Self.firstZeroGain(in: rendered, from: cancelPoint, sine: sine)
        XCTAssertLessThanOrEqual(
            rampStart, cancelPoint + 4_096,
            "the ramp begins at the first render pass after the cancel — never later")
        XCTAssertGreaterThanOrEqual(
            firstZero, cancelPoint,
            "the halt's ramp starts no earlier than the cancel")
        XCTAssertLessThanOrEqual(
            firstZero, cancelPoint + 4_096 + rampFrames + 2,
            "the ramp ends within one render buffer of its budget")
        XCTAssertEqual(
            firstZero - rampStart, rampFrames - 1, accuracy: 2,
            "the ramp is exactly rampDuration × rate frames — the frame-quantized contract")

        // No leaked tail: everything after the ramp is exact silence.
        XCTAssertTrue(
            rendered[firstZero...].allSatisfy { $0 == 0 },
            "no sample after the ramp exceeds the silence floor — the halt leaves no tail")
    }

    /// **The backpressure, proven on real audio:** a ~3.3 s clip (three 24576-frame chunks —
    /// each a whole multiple of the 4096-frame render quantum, so a render pass never ends
    /// mid-chunk and the clip's alignment with the input is exact) is larger than the ring's
    /// capacity (the smallest power of two ≥ the session rate — 32768 frames, ~1.5 s), so the
    /// producer must wait for the renderer to make room — and the wait never drops a frame: the
    /// full clip renders with the signal intact.
    func testOfflinePlaybackDrainsAcrossRingCapacityWithoutDroppingFrames() async throws {
        let chunkFrames = 6 * 4_096  // 24576 — a whole number of render quanta
        let clipFrames = 3 * chunkFrames
        let sine = Self.sine(frequency: 1000, sampleRate: 22_050, frames: clipFrames)
        let chunks = [
            Self.chunk(frames: Array(sine[0..<chunkFrames])),
            Self.chunk(frames: Array(sine[chunkFrames..<(2 * chunkFrames)])),
            Self.chunk(frames: Array(sine[(2 * chunkFrames)..<clipFrames])),
        ]
        let (rendered, _) = try await Self.render(
            stream: Self.stream(chunks))

        XCTAssertGreaterThanOrEqual(
            rendered.count, clipFrames,
            "the clip must render whole — the ring's capacity must not cost a frame")

        let maxDelta = zip(rendered.prefix(clipFrames), sine).reduce(Float(0)) { partial, pair in
            max(partial, abs(pair.0 - pair.1))
        }
        XCTAssertLessThan(
            maxDelta, 1e-6,
            "the clip's signal is intact sample-for-sample — the wait-for-room backpressure never drops")

        XCTAssertTrue(
            rendered[clipFrames...].allSatisfy { $0 == 0 },
            "the tail beyond the clip is exact silence")
    }

    // MARK: - Helpers

    /// A play that marks the completion flag when it returns — the `Task` closure lives here
    /// once (the region-based isolation checker's budget: the same pattern inlines fine in
    /// small files, but this suite's play tasks are many).
    private static func playToCompletion(
        _ engine: SystemPlayback,
        _ stream: AsyncThrowingStream<AudioChunk, Error>,
        _ completion: CompletionFlag
    ) -> Task<Void, Error> {
        Task { try await engine.play(stream); completion.mark() }
    }

    /// A play over the real manual-rendering output, pumped to completion.
    private static func render(
        stream: AsyncThrowingStream<AudioChunk, Error>
    ) async throws -> (rendered: [Float], output: SystemPlaybackOutput) {
        let output = SystemPlaybackOutput(manualRendering: true)
        let engine = SystemPlayback(level: .default, clock: OfflineClock(), output: output)
        let done = CompletionFlag()
        let playTask = Self.playToCompletion(engine, stream, done)
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let rendered = try await Self.pump(
            output, format: format, target: .max, done: { done.isDone })
        try await playTask.value
        return (rendered, output)
    }

    /// Polls `condition` on a 1 ms tick until it holds — the rendezvous wait for the observing
    /// seam's halt mark (bounded so a broken probe fails loudly instead of hanging).
    private static func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                throw WaitTimeout()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Drives `renderOffline` in 4096-frame passes until `target` frames have accumulated or
    /// `done` — the play task's completion. Waits out the window before the session starts (the
    /// source node does not exist until the first chunk), tolerates
    /// `.cannotDoInCurrentContext` (retry), and ends on a render error — the offline fallback's
    /// rule is the test file's, not the pump's.
    ///
    /// The pump suspends after every pass and on every gate wait — it is the test's *only* actor
    /// while it runs, so without those suspensions the concurrent tasks it must cooperate with
    /// (the play task's drain, a racing `cancelToSilence()`) would starve on the cooperative
    /// executor.
    private static func pump(
        _ output: SystemPlaybackOutput,
        format: AVAudioFormat,
        target: Int,
        done: @escaping () -> Bool
    ) async throws -> [Float] {
        var rendered: [Float] = []
        while rendered.count < target && !done() {
            // Nothing to render yet: wait out the window before the session's first chunk
            // enqueues (the output starts at `start()`, the producer's first write lands a
            // moment later — rendering into that window would push empty buffers ahead of the
            // clip), and the same gate holds once the clip has fully drained (the play task's
            // completion then ends the loop).
            if !output.isRunning || output.isDrained {
                try await Task.sleep(for: .milliseconds(1))
                continue
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                break
            }
            buffer.frameLength = 4096
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try output.renderOffline(into: buffer)
            } catch {
                break
            }
            switch status {
            case .success:
                if let channel = buffer.floatChannelData?[0] {
                    rendered.append(
                        contentsOf: UnsafeBufferPointer(
                            start: channel, count: Int(buffer.frameLength)))
                }
            case .cannotDoInCurrentContext:
                try await Task.sleep(for: .milliseconds(1))
            case .insufficientDataFromInputNode, .error:
                break
            @unknown default:
                break
            }
            try await Task.yield()
        }
        return rendered
    }

    /// The first index at or after `from` whose envelope gain is below `threshold` — the ramp
    /// has left the flat duck target.
    private static func firstBelowThreshold(
        in rendered: [Float], from: Int, sine: [Float], threshold: Float
    ) -> Int {
        var index = from
        while index < min(rendered.count, sine.count) {
            if abs(sine[index]) > 0.5, rendered[index] / sine[index] < threshold {
                return index
            }
            index += 1
        }
        return index
    }

    /// The first index at or after `from` whose rendered sample is zero — and whose whole tail
    /// is zero — measured on the envelope gain so the ramp's exact end is found, not a sine
    /// zero-crossing.
    private static func firstZeroGain(
        in rendered: [Float], from: Int, sine: [Float]
    ) -> Int {
        var index = from
        while index < min(rendered.count, sine.count) {
            let isZero: Bool
            if abs(sine[index]) > 0.5 {
                isZero = abs(rendered[index] / sine[index]) < 1e-6
            } else {
                isZero = abs(rendered[index]) < 1e-6
            }
            if isZero && rendered[(index + 1)...].allSatisfy({ $0 == 0 }) {
                return index
            }
            index += 1
        }
        return index
    }

    /// A synthetic sine — the `AudioFormatConverterTests` fixture.
    private static func sine(frequency: Double, sampleRate: Double, frames: Int) -> [Float] {
        (0..<frames).map { index in
            Float(sin(2.0 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    /// A chunk whose bytes are the native-endian Float32 encoding of `frames`.
    private static func chunk(frames: [Float], sampleRate: Double = 22_050) -> AudioChunk {
        var bytes = [UInt8]()
        bytes.reserveCapacity(frames.count * MemoryLayout<Float>.size)
        for value in frames {
            var bits = value.bitPattern
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        return AudioChunk(
            bytes: bytes,
            sampleRate: sampleRate,
            channelCount: 1,
            duration: Double(frames.count) / sampleRate)
    }

    private static func stream(_ chunks: [AudioChunk]) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    /// The zero-crossing estimate: sign changes over the clip, exact zeros skipped.
    private static func zeroCrossingFrequency(frames: [Float], sampleRate: Double) -> Double {
        var crossings = 0
        var lastSign = 0
        for sample in frames {
            let sign = sample > 0 ? 1 : (sample < 0 ? -1 : 0)
            if sign != 0 {
                if lastSign != 0 && sign != lastSign { crossings += 1 }
                lastSign = sign
            }
        }
        return Double(crossings) / 2 * sampleRate / Double(frames.count)
    }
}

private struct WaitTimeout: Error {}

/// **The observing seam**: the real ``SystemPlaybackOutput`` behind a `PlaybackOutputSeam`
/// wrapper that records when the halt's `setGain(0)` lands. The duck/halt test needs the ramp
/// armed before the pump drains the remaining audio, and this is the rendezvous the injectable
/// seam exists for — the real adapter is still the thing executed, one forwarder deep.
private final class HaltObservingOutput: PlaybackOutputSeam, @unchecked Sendable {
    let wrapped: SystemPlaybackOutput
    let haltArmed = CompletionFlag()
    private let totalEnqueuedFrames = Mutex<Int>(0)

    /// The producer's completed writes, as observed through the seam — the test waits for the
    /// whole clip before issuing the halt, so the cancel can never land between the producer's
    /// chunks and drop the audio the ramp must ride on.
    var enqueuedFrameCount: Int { totalEnqueuedFrames.withLock { $0 } }

    init(wrapping wrapped: SystemPlaybackOutput) {
        self.wrapped = wrapped
    }

    var isRunning: Bool { wrapped.isRunning }
    var isDrained: Bool { wrapped.isDrained }

    func start(sampleRate: Double, channelCount: Int) throws {
        try wrapped.start(sampleRate: sampleRate, channelCount: channelCount)
    }

    func enqueue(frames: [Float]) {
        wrapped.enqueue(frames: frames)
        totalEnqueuedFrames.withLock { $0 += frames.count }
    }

    func setGain(_ gain: Float) {
        wrapped.setGain(gain)
        if gain == 0 { haltArmed.mark() }
    }

    func stop() {
        wrapped.stop()
    }
}

/// A copyable completion flag for the offline pump — `Mutex<Bool>` is noncopyable and cannot be
/// captured by the play task's escaping closure, so the flag is a box.
private final class CompletionFlag: @unchecked Sendable {
    private let lock = Mutex<Bool>(false)

    func mark() {
        lock.withLock { $0 = true }
    }

    var isDone: Bool {
        lock.withLock { $0 }
    }
}

/// A real `MonotonicClock` — `ContinuousClock` since a process-local origin, the
/// `ContinuousMonotonicClock` shape (that type lives in `VoccaASR`, which `VoccaAudio` may not
/// import; the tests need the halt's bounded poll to advance in real time).
private struct OfflineClock: MonotonicClock {
    private let origin = ContinuousClock.now

    var now: Duration { ContinuousClock.now - origin }
}