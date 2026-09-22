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

// The probe's half of the zero-network invariant for the converse loop's **default work**
// (D7): the `ConverseLoopDriver` composed over the fallback implementations only — `EnergyVAD`
// + `SilenceThresholdDetector` — with the probe's ASR double, a recording probe cleanup
// provider, **the shipped minimal reply generator** (`EchoReplyGenerator` — the R7 seam's
// deterministic stand-in), the probe stub synthesizer, a probe fake playback engine and a
// probe clock. **No model artifact, no SDK, no network name is reachable** — the G7 pin: the
// converse default work in the zero-network probe is the fallbacks and nothing else.
//
// The `SpeechDrive`/`TurnLoopDrive` shape: the drive's `moduleWitness` is minted *by* the call
// (`type(of: driver)`) — the `VoccaBootstrap`-derived entry in the probe's module list, so the
// module's coverage can no longer be satisfied by the `AppBootstrap.self` metatype reference.
//
// ## What this drive does
//
// One scripted conversation, deterministic over the probe's hand-moved clock: start → 0.4 s
// silence → 1.2 s speech (440 Hz) → 0.85 s silence (the first turn commits — the pause's
// first four frames are the EnergyVAD's offset hold, the recorded hysteresis) → the pipeline
// runs (ASR → cleanup(`.conversing`) → `EchoReplyGenerator` → `scheduleReply`) → the stub
// reply plays one 440 Hz reference chunk (window open) → one 0.85-scaled echo frame (gated —
// the gate's discard) → two 880 Hz frames (the first seeds, the second flips the VAD and
// **barge-ins** — orthogonal to the reference, so the gate's residue path accepts it) → the
// interrupting utterance (0.3125 s) → 0.85 s silence (the second turn commits) → a second
// reply → stop.
//
// Report fields (deterministic, space-separated `key=value`): `started=1`, `turnCommits=2`,
// `replies=2`, `bargeIns=1`, `gated=1`, `asrTranscribes=2`, `cleanupMode=conversing`,
// `state=idle`.

extension VoccaNetworkProbe {

    /// One pass over the converse loop's default-configuration surface, and the post-condition
    /// the zero-network suite reads.
    struct ConverseLoopDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from which `VoccaBootstrap`'s coverage entry is
        /// derived — the `SpeechDrive.moduleWitness` shape. The witness cannot be kept while
        /// the drive is deleted.
        let moduleWitness: Any.Type
    }

    /// **Drives the converse loop's fallback default work, and reports what happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every
    /// other drive gives: an assertion living in the observed process can be deleted by the
    /// same edit that breaks what it observes.
    static func exerciseConverseLoop() -> ConverseLoopDrive {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ConverseLoopDriveBox()
        Task { @MainActor in
            box.value = await runConverseRoundTrip()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary — the `TurnLoopDriveBox`
    /// shape.
    private final class ConverseLoopDriveBox: @unchecked Sendable {
        var value: ConverseLoopDrive?
    }

    /// The probe's hand-moved clock — a **struct**: the driver requires `MonotonicClock &
    /// Sendable` (the cleanup race's watcher reads it from a task closure); the loop's own copy
    /// freezing at `.zero` changes nothing the report reads (no timing fields).
    private struct ProbeConverseClock: MonotonicClock {
        var now: Duration = .zero
    }

    /// The probe's stub synthesizer: renders its script verbatim (no engine — the reply's
    /// known-output reference), `cancel` a safe no-op.
    private struct ProbeConverseSynthesizer: SpeechSynthesizer {
        let identity = VoiceIdentity(engineID: "probe-converse-stub", voiceName: nil)
        let script: [AudioChunk]

        func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error> {
            AsyncThrowingStream { continuation in
                for chunk in script {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }

        func cancel() async {}
    }

    /// The probe's fake playback engine — an actor (the seam is `Sendable`; the ledger crosses
    /// the boundary honestly). Records the play and the barge-in halt.
    private actor ProbeConversePlayback: PlaybackEngine {
        private(set) var playCount = 0
        private(set) var haltCount = 0

        func play(_ stream: AsyncThrowingStream<AudioChunk, Error>) async throws {
            playCount += 1
            for try await _ in stream {}
        }

        func duck() async {}

        func cancelToSilence() async {
            haltCount += 1
        }

        nonisolated func tearDown() {}
    }

    /// The probe's recording cleanup provider — returns the raw transcript, reports the mode
    /// the driver cleaned under.
    private actor ProbeConverseCleanup: CleanupProvider {
        let identity = ProviderIdentity(
            id: "probe-converse-cleanup", displayName: "Probe converse cleanup")
        private(set) var modes: [SessionMode] = []

        func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String {
            modes.append(context.mode)
            return transcript.text
        }
    }

    /// The probe's capture fake — the test-driven push shape: the drive pushes the scripted
    /// conversation's frames; `stop()` ends the stream (the driver's normal terminal).
    private final class ProbeConverseCapture: ContinuousAudioSource {
        private var continuation: AsyncStream<AudioBuffer>.Continuation?

        func start() throws -> AsyncStream<AudioBuffer> {
            let (stream, continuation) = AsyncStream.makeStream(of: AudioBuffer.self)
            self.continuation = continuation
            return stream
        }

        func stop() {
            continuation?.finish()
            continuation = nil
        }

        func push(_ frames: [AudioBuffer]) {
            for frame in frames {
                continuation?.yield(frame)
            }
        }
    }

    /// The round trip itself — on the main actor, the driver's one isolation domain.
    @MainActor
    private static func runConverseRoundTrip() async -> ConverseLoopDrive {
        let engine = ProbeEngine()
        let cleanup = ProbeConverseCleanup()
        let capture = ProbeConverseCapture()
        let synth = ProbeConverseSynthesizer(
            script: [
                AudioChunk(
                    bytes: probeConverseChunkBytes(amplitude: 0.4, frequency: 440, samples: 4000),
                    sampleRate: 16_000, channelCount: 1, duration: 0.25)
            ])
        let playback = ProbeConversePlayback()

        let driver = ConverseLoopDriver(
            vad: EnergyVAD(
                configuration: VADConfiguration(
                    onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)),
            turnDetector: SilenceThresholdDetector(
                configuration: SilenceThresholdConfiguration(
                    commitAfterPause: 0.5, minimumUtteranceDuration: 0.2)),
            clock: ProbeConverseClock(),
            gate: EchoGate(),
            capture: capture,
            asrProvider: { engine },
            cleanupProvider: { cleanup },
            // The intent step is unwired in the probe — the composed default resolves
            // nothing (PRD R7: `intentResolved=0`), so the fallback default work still
            // echoes. The closures are explicit, not the driver's defaults, so the drive
            // names the types it deliberately does not wire.
            intentProvider: { (_: String) async -> IntentResolution? in nil },
            intentActionHandler: { (_: ActionInvocation) async -> String? in nil },
            replyGenerator: EchoReplyGenerator(),
            synthesizer: { synth },
            playback: playback,
            onStateChange: { _ in },
            failureSink: { _ in })

        let silence = AudioBuffer(
            samples: [Float](repeating: 0, count: 1000), sampleRate: 16_000)
        let speech440 = probeConverseTone(amplitude: 0.4, frequency: 440, samples: 1000)
        let user880 = probeConverseTone(amplitude: 0.4, frequency: 880, samples: 1000)
        // The 0.85-scaled echo, phase-aligned to the reference's tail: the reply chunk holds
        // 4000 samples (110 full 440 Hz cycles), and the gate tail-aligns over the last
        // 1000 — the echo must be those same samples scaled, or the correlation would be
        // phase-dependent (ρ = cos φ), not the pure-echo 1.0.
        let echo440 = AudioBuffer(
            samples: (0..<1000).map { index in
                0.4 * 0.85 * Float(sin(2 * Double.pi * 440 * Double(3000 + index) / 16_000))
            },
            sampleRate: 16_000)

        func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
            for _ in 0..<10_000 {
                if await condition() { return }
                await Task.yield()
            }
        }

        try? driver.start()
        for _ in 0..<7 { capture.push([silence]) }        // 0.4 s of silence
        for _ in 0..<20 { capture.push([speech440]) }     // 1.2 s of speech → uttering
        for _ in 0..<14 { capture.push([silence]) }       // 0.85 s pause → the first commit
        await waitUntil { await playback.playCount == 1 }  // the pipeline drained and played

        capture.push([echo440])                           // the loop's own output — gated
        capture.push([user880])                           // accepted (orthogonal residue) — seed
        capture.push([user880])                           // VAD flips → barge-in
        for _ in 0..<3 { capture.push([user880]) }        // the interrupting utterance
        for _ in 0..<14 { capture.push([silence]) }       // 0.85 s pause → the second commit
        await waitUntil { await playback.playCount == 2 }
        await driver.stop()

        let commits = driver.effects.filter { effect in
            if case .turnCommitted = effect { return true } else { return false }
        }.count
        let replies = driver.effects.filter { effect in
            if case .speakReply = effect { return true } else { return false }
        }.count

        return ConverseLoopDrive(
            report: [
                "started=\(driver.effects.filter { $0 == .started }.count)",
                "turnCommits=\(commits)",
                "replies=\(replies)",
                "bargeIns=\(driver.effects.filter { $0 == .bargeIn }.count)",
                "gated=\(driver.loop.gatedFrameCount)",
                "asrTranscribes=\(await engine.transcribeCalls)",
                "cleanupMode=\(await cleanup.modes.first.map { String(describing: $0) } ?? "none")",
                "state=\(driver.loop.state)",
            ].joined(separator: " "),
            moduleWitness: type(of: driver))
    }

    /// A 440/880 Hz tone frame at 16 kHz.
    private static func probeConverseTone(
        amplitude: Float, frequency: Double, samples: Int
    ) -> AudioBuffer {
        AudioBuffer(
            samples: (0..<samples).map { index in
                amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / 16_000))
            },
            sampleRate: 16_000)
    }

    /// Little-endian Float32 PCM bytes at 16 kHz.
    private static func probeConverseChunkBytes(
        amplitude: Float, frequency: Double, samples: Int
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(samples * 4)
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
}