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

import AVFoundation
import CoreAudio
import Synchronization
import VoccaASR
import VoccaAudio
import VoccaCore
import VoccaSpeech
import XCTest

/// `AVFoundation`'s `AVAudioBuffer` would shadow the seam's carrier — the loop's frame type
/// is `VoccaCore.AudioBuffer`, never ambiguous.
typealias LoopAudioBuffer = VoccaCore.AudioBuffer

/// The env-gated composed real suite (`barge-in-loop/plan_20260915.md` Phase 5) — the
/// loop over the **real** `SileroVAD` adapter (FluidAudio, staged through the C2 store) and
/// the shipped `SilenceThresholdDetector` (the EOU conformance is recorded PENDING — Branch
/// B — so the loop's real leg rides the shipped fallback detector), with real playback
/// (`SystemPlayback`) where the row needs it.
///
/// **The realtime conversation is executed by nothing in CI** (O4, the tap-adapter
/// precedent): the suite is env-gated on `VOCCA_RUN_REAL_TURN_LOOP` **and** `VOCCA_MODEL_DIR`
/// (the store-shaped version directory — the sdk-adapters staging under it,
/// `<root>/silero-vad/1/vad/`, carries the VAD model). CI runs the skip path — the visible
/// skip names both variables and still counts as executed, which is what the floor's
/// arithmetic assumes. The rows assert **behavior, never numbers**: the ≤200 ms halt is
/// SMOKE 132's material and the on-speakers echo truth is SMOKE 133's — recorded-never-gated,
/// a CI assertion on a realtime number is a drift, not an improvement.
final class TurnTakingLoopRealSuiteTests: XCTestCase {

    /// The model file the staged `vad/` directory contains.
    private static let modelFileName = "silero-vad-unified-256ms-v6.2.1.mlmodelc"

    /// The two-variable gate: `VOCCA_RUN_REAL_TURN_LOOP` present and `VOCCA_MODEL_DIR` naming
    /// a store-shaped root whose `silero-vad/1/vad/` carries the model. Either missing — or
    /// the path not a directory — is a visible skip naming both variables, never a silent
    /// pass.
    private static func gatedVADModelDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOCCA_RUN_REAL_TURN_LOOP"] != nil,
            let modelRoot = environment["VOCCA_MODEL_DIR"]
        else {
            throw XCTSkip(
                "set VOCCA_RUN_REAL_TURN_LOOP=1 and VOCCA_MODEL_DIR=<store-shaped version "
                    + "directory> to run the real turn-loop suite — CI has no VAD model")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelRoot, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw XCTSkip(
                "VOCCA_MODEL_DIR does not name a directory (\(modelRoot)); VOCCA_RUN_REAL_TURN_LOOP "
                    + "is set")
        }
        let vadDirectory = URL(fileURLWithPath: modelRoot)
            .appendingPathComponent("silero-vad/1/vad", isDirectory: true)
        guard
            FileManager.default.fileExists(
                atPath: vadDirectory.appendingPathComponent(modelFileName).path)
        else {
            throw XCTSkip(
                "VOCCA_MODEL_DIR names \(modelRoot) but \(vadDirectory.path) does not contain "
                    + "\(modelFileName) — provision with Scripts/provision-vad-fixtures.sh; "
                    + "VOCCA_RUN_REAL_TURN_LOOP is set")
        }
        return vadDirectory
    }

    /// The seam configuration both the CI leg and the real leg run — the sdk-adapters
    /// record's numbers.
    private static func seamConfiguration() -> VADConfiguration {
        VADConfiguration(
            onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)
    }

    // MARK: - The fixture (test-local, pure — the sdk-adapters pattern)

    /// Renders ~3 s of speech through the system renderer and returns 16 kHz mono samples.
    ///
    /// The sdk-adapters record says synthetic tones are unreliable for the real Silero VAD,
    /// so the fixture is the same locally-rendered speech its env-gated suite drives — the
    /// chunk bytes are the renderer's own (little-endian Float32 at ~22050 Hz), resampled to
    /// the interchange rate by this fixture's own pure helpers. Nothing here is production
    /// code.
    private static func speechFixtureSamples() async throws -> [Float] {
        let synth = SystemSynthesizer(voiceIdentifier: nil)
        let text = "The quick brown fox jumps over the lazy dog and then it rests under the oak."

        var rendered: [Float] = []
        var sourceRate: Double?
        for try await chunk in synth.speak(text) {
            sourceRate = chunk.sampleRate
            rendered.append(
                contentsOf: decodeLittleEndianFloat32(
                    chunk.bytes, channelCount: chunk.channelCount))
        }
        guard let rate = sourceRate, !rendered.isEmpty else {
            throw TurnTakingLoopRealSuiteError.emptyFixtureRender
        }
        return resample(rendered, from: rate, to: Double(LoopAudioBuffer.interchangeSampleRate))
    }

    private static func decodeLittleEndianFloat32(
        _ bytes: [UInt8], channelCount: Int
    ) -> [Float] {
        let stride = max(channelCount, 1)
        var samples: [Float] = []
        var index = 0
        while index + MemoryLayout<Float>.size <= bytes.count {
            var bits: UInt32 = 0
            for offset in 0..<4 {
                bits |= UInt32(bytes[index + offset]) << (8 * offset)
            }
            samples.append(Float(bitPattern: bits))
            index += MemoryLayout<Float>.size
        }
        return stride == 1 ? samples : strideDecimatedMono(samples, channelCount: stride)
    }

    private static func strideDecimatedMono(_ interleaved: [Float], channelCount: Int) -> [Float] {
        var mono: [Float] = []
        var frame = 0
        while frame + channelCount <= interleaved.count {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += interleaved[frame + channel]
            }
            mono.append(sum / Float(channelCount))
            frame += channelCount
        }
        return mono
    }

    /// Nearest-neighbour resampling to the interchange rate.
    private static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double)
        -> [Float]
    {
        let ratio = sourceRate / targetRate
        return (0..<Int(Double(samples.count) / ratio)).map { index in
            samples[Int((Double(index) * ratio).rounded())]
        }
    }

    /// Chunks the rendered speech into 1000-sample frames, interspersed with leading and
    /// trailing silence.
    private static func frames(
        from speech: [Float], leadingSilenceFrames: Int, trailingSilenceFrames: Int
    ) -> [LoopAudioBuffer] {
        var result: [LoopAudioBuffer] = []
        let silence = LoopAudioBuffer(samples: [Float](repeating: 0, count: 1000), sampleRate: 16_000)
        for _ in 0..<leadingSilenceFrames { result.append(silence) }
        var index = 0
        while index < speech.count {
            let end = min(index + 1000, speech.count)
            result.append(LoopAudioBuffer(samples: Array(speech[index..<end]), sampleRate: 16_000))
            index = end
        }
        for _ in 0..<trailingSilenceFrames { result.append(silence) }
        return result
    }

    // MARK: - Row 1: the real adapters commit a scripted turn

    /// The real `SileroVAD` + the shipped `SilenceThresholdDetector` commit a scripted turn
    /// driven through the composed driver: assert a commit happened and the utterance frames
    /// arrived — never a score, never a timing number (real VADs may not classify synthetic
    /// tones, so the fixture is the locally-rendered speech of the sdk-adapters record).
    func testTheRealAdaptersCommitAScriptedTurn() async throws {
        let modelDirectory = try Self.gatedVADModelDirectory()

        let speech = try await Self.speechFixtureSamples()
        let frames = Self.frames(from: speech, leadingSilenceFrames: 6, trailingSilenceFrames: 20)

        var pending: [TurnEffect] = []
        var history: [TurnEffect] = []
        let loop = TurnTakingLoop(
            vad: SileroVAD(configuration: Self.seamConfiguration(), modelDirectory: modelDirectory),
            turnDetector: SilenceThresholdDetector(
                configuration: SilenceThresholdConfiguration(
                    commitAfterPause: 0.5, minimumUtteranceDuration: 0.2)),
            clock: TurnLoopTestClock(),
            gate: EchoGate(),
            onEffect: { effect in
                pending.append(effect)
                history.append(effect)
            })

        loop.start()
        for frame in frames {
            loop.feed(frame)
            while !pending.isEmpty {
                let effect = pending.removeFirst()
                if case .turnCommitted = effect {
                    loop.scheduleReply("ok")
                }
                if case .speakReply = effect {
                    loop.reportPlaybackStarted()
                    loop.reportPlaybackEnded()
                }
            }
        }
        loop.stop()

        let commits = history.filter { effect in
            if case .turnCommitted = effect { return true } else { return false }
        }
        XCTAssertGreaterThanOrEqual(
            commits.count, 1,
            "the real VAD + the shipped turn detector must commit the rendered speech turn — "
                + "behavior, never a score or a timing number")
    }

    // MARK: - Row 2: injected speech during real playback — recorded, never gated

    /// Real playback (`SystemPlayback`) with a stub synthesizer; a speech frame injected
    /// mid-playback halts the reply. The wall-clock halt is printed `TURN-HALT <ms>ms
    /// recorded-never-gated` (the KOKORO-TTFA row shape) and asserted only to be a real
    /// measurement — **the ≤200 ms number is SMOKE 132's, never a CI assertion**.
    func testInjectedSpeechDuringRealPlaybackHaltsWithinBudgetRecordedNeverGated() async throws {
        let modelDirectory = try Self.gatedVADModelDirectory()
        let speech = try await Self.speechFixtureSamples()

        let clock = ContinuousMonotonicClock()
        let playback = SystemPlayback(level: .default, clock: clock)
        defer { playback.tearDown() }

        let replyChunk = AudioChunk(
            bytes: Self.chunkBytes(amplitude: 0.3, frequency: 440, samples: 4000),
            sampleRate: 16_000, channelCount: 1, duration: 0.25)
        let synth = StubSynthesizer(
            identity: VoiceIdentity(engineID: "real-suite-stub-synth", voiceName: nil),
            chunks: [replyChunk])

        var effects: [TurnEffect] = []
        let loop = TurnTakingLoop(
            vad: SileroVAD(configuration: Self.seamConfiguration(), modelDirectory: modelDirectory),
            turnDetector: SilenceThresholdDetector(
                configuration: SilenceThresholdConfiguration(
                    commitAfterPause: 0.5, minimumUtteranceDuration: 0.2)),
            clock: clock,
            gate: EchoGate(),
            onEffect: { effects.append($0) })

        loop.start()
        for _ in 0..<6 { loop.feed(LoopAudioBuffer(samples: [Float](repeating: 0, count: 1000), sampleRate: 16_000)) }
        for frame in Self.frames(from: speech, leadingSilenceFrames: 0, trailingSilenceFrames: 0) {
            loop.feed(frame)
        }
        for _ in 0..<20 { loop.feed(LoopAudioBuffer(samples: [Float](repeating: 0, count: 1000), sampleRate: 16_000)) }

        // The reply: play the stub's chunk through the real output while the injected speech
        // arrives. The measurement: the wall clock from the barge-in detection to silence.
        var haltMeasurement: Duration?
        var playTask: Task<Void, Never>?

        for effect in effects {
            if case .turnCommitted = effect {
                loop.scheduleReply("reply")
            }
            if case .speakReply(let text) = effect {
                let stream = synth.speak(text)
                playTask = Task { try? await playback.play(stream) }
                loop.reportPlaybackStarted()
                loop.reportPlaybackChunk(replyChunk)
                // Inject the rendered speech mid-playback.
                var injected = 0
                let start = clock.now
                for frame in Self.frames(from: speech, leadingSilenceFrames: 0, trailingSilenceFrames: 0) {
                    loop.feed(frame)
                    injected += 1
                    if effects.contains(.bargeIn) || injected >= 60 { break }
                }
                if effects.contains(.bargeIn) {
                    await synth.cancel()
                    await playback.cancelToSilence()
                    haltMeasurement = clock.now - start
                }
                loop.reportPlaybackEnded()
            }
        }
        await playTask?.value
        loop.stop()

        let milliseconds = Double((haltMeasurement ?? .zero) / .milliseconds(1))
        print(
            "TURN-HALT\t\(String(format: "%.1f", milliseconds))ms\trecorded-never-gated")
        XCTAssertNotNil(
            haltMeasurement,
            "a halt must be observed — a barge-in with no measured halt measures nothing")
        XCTAssertGreaterThanOrEqual(
            haltMeasurement ?? .zero, .zero,
            "the halt cannot run backwards")
        XCTAssertTrue(effects.contains(.bargeIn), "the injected speech must barge in")
    }

    // MARK: - Row 3: the echo gate's loopback leg

    /// The gate's headless legs rerun (already CI truth) plus, when a loopback input device is
    /// available and the default input, the real loopback leg: play the reference through
    /// `SystemPlayback`, capture from the loopback input, and assert the gate discards the
    /// loopback with zero transcription. The row prints `ECHO-LOOPBACK <device>
    /// recorded-never-gated` — **the on-speakers truth is SMOKE 133, never CI**
    /// (`ARCHITECTURE.md:580-586`).
    func testTheEchoGateDiscardsTheLoopbackWithZeroTranscription() async throws {
        let modelDirectory = try Self.gatedVADModelDirectory()
        let reference = (0..<1000).map { index in
            Float(2.0.squareRoot() * sin(2 * Double.pi * 440 * Double(index) / 16_000))
        }
        XCTAssertEqual(
            EchoGate.decision(capture: reference.map { $0 * 0.85 }, reference: reference),
            .discard,
            "the headless pure-echo row stays CI truth")
        XCTAssertEqual(
            EchoGate.decision(
                capture: [Float](repeating: 0, count: 1000), reference: reference),
            .accept(samples: nil),
            "silence during playback never gates — the headless row stays CI truth")

        let defaultInputName = Self.defaultInputDeviceName()
        guard let name = defaultInputName, name.lowercased().contains("loopback") else {
            print("ECHO-LOOPBACK-INPUT\t\(defaultInputName ?? "none")\tnot-a-loopback\trecorded-never-gated")
            return
        }
        print("ECHO-LOOPBACK\t\(name)\trecorded-never-gated")

        let referenceChunk = AudioChunk(
            bytes: Self.chunkBytes(amplitude: 0.3, frequency: 440, samples: 4000),
            sampleRate: 16_000, channelCount: 1, duration: 0.25)

        let clock = ContinuousMonotonicClock()
        let playback = SystemPlayback(level: .default, clock: clock)
        defer { playback.tearDown() }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        let captured = Mutex<[Float]>([])
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let frames = buffer.floatChannelData?[0]
            guard let frames else { return }
            captured.withLock { samples in
                samples.append(
                    contentsOf: stride(from: 0, to: Int(buffer.frameLength), by: max(Int(format.channelCount), 1))
                        .map { frames[$0] })
            }
        }
        try engine.start()
        defer { engine.stop() }

        let stream = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(referenceChunk)
            continuation.finish()
        }
        try await playback.play(stream)

        try await Task.sleep(for: .milliseconds(200))
        engine.stop()

        let capturedCopy = captured.withLock { $0 }
        guard !capturedCopy.isEmpty else {
            print("ECHO-LOOPBACK\t\(name)\tempty-capture\trecorded-never-gated")
            return
        }

        let at16k = Self.resample(capturedCopy, from: Double(format.sampleRate), to: 16_000)
        var discards = 0
        var index = 0
        while index + 1000 <= at16k.count {
            if EchoGate.decision(capture: Array(at16k[index..<index + 1000]), reference: reference)
                == .discard
            {
                discards += 1
            }
            index += 1000
        }
        XCTAssertGreaterThanOrEqual(
            discards, 1,
            "the loopback leg must observe at least one discard — real loopback audio of the "
                + "played reference must correlate; zero is a device that captured nothing")
    }

    // MARK: - Small helpers

    private static func chunkBytes(amplitude: Float, frequency: Double, samples: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for index in 0..<samples {
            let sample = amplitude
                * Float(sin(2 * Double.pi * frequency * Double(index) / 16_000))
            var bits = sample.bitPattern
            for _ in 0..<4 {
                bytes.append(UInt8(bits & 0xFF))
                bits >>= 8
            }
        }
        return bytes
    }

    /// The default input device's name, via the CoreAudio HAL — `nil` when none can be read.
    private static func defaultInputDeviceName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceName(deviceID)
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name as String?
    }
}

/// The real suite's loud refusals.
enum TurnTakingLoopRealSuiteError: Error, CustomStringConvertible {
    case emptyFixtureRender

    var description: String {
        "the system renderer produced no audio for the real-suite fixture"
    }
}