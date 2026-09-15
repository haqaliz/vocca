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
import VoccaCore

// The probe's half of the zero-network invariant for the turn-taking loop's **default work**
// (`barge-in-loop/plan_20260915.md` Phase 5, G6): the loop driven over the fallback
// implementations only — `EnergyVAD` + `SilenceThresholdDetector` — with a probe stub
// synthesizer, a probe fake playback engine and a probe hand-moved clock. **No model
// artifact, no SDK, no network name is reachable** — this is the G6 pin: the loop's default
// work in the zero-network probe is the fallbacks and nothing else.
//
// The `SpeechDrive` shape: the drive's `moduleWitness` is minted *by* the call
// (`type(of: loop)`) — the second VoccaCore-derived entry in the probe's module list, so
// the loop's coverage can no longer be satisfied by a metatype reference.
//
// ## What this drive does
//
// One scripted conversation, deterministic over the injected clock: start → 0.4 s silence →
// 1.2 s speech (440 Hz) → 0.85 s silence (the first turn commits) → the stub reply plays one
// 440 Hz reference chunk (window open) → one 0.85-scaled echo frame (gated — the gate's
// discard) → two 880 Hz frames (the first seeds, the second flips the VAD and **barge-ins** —
// orthogonal to the reference, so the gate's residue path accepts it) → the interrupting
// utterance (0.3125 s) → 0.85 s silence (the second turn commits) → a second reply → stop.
// The pauses are 0.85 s because EnergyVAD's `minimumSilence` hold (0.20 s) delays the loop's
// pause accumulator by ~0.25 s — a 0.55 s pause would never reach the 0.5 s threshold (the
// plan's script number cannot hold against the shipped fallback's own hysteresis; recorded).
//
// Report fields (deterministic, space-separated `key=value`): `started=1`, `turnCommits=2`,
// `replies=2`, `bargeIns=1`, `gated=1`, `fed=61`, `state=idle`.

extension VoccaNetworkProbe {

    /// One pass over the turn loop's default-configuration surface, and the post-condition
    /// the zero-network suite reads.
    struct TurnLoopDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from which `VoccaCore`'s coverage entry for the
        /// loop is derived — the `SpeechDrive.moduleWitness` shape. The witness cannot be
        /// kept while the drive is deleted.
        let moduleWitness: Any.Type
    }

    /// **Drives the loop's fallback default work, and reports what happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every
    /// other drive gives: an assertion living in the observed process can be deleted by the
    /// same edit that breaks what it observes.
    ///
    /// The `SpeechDriveBox` bridge: `main()` is the process entry point and is already on
    /// the main thread, so the async round trip is handed to a Task and the loop is pumped
    /// until it lands — inside the observation window rather than after it.
    static func exerciseTurnLoop() -> TurnLoopDrive {
        let semaphore = DispatchSemaphore(value: 0)
        let box = TurnLoopDriveBox()
        Task {
            box.value = try? await runTurnRoundTrip()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary — the `CycleDriveBox`
    /// shape, written once by the Task and read once after the semaphore.
    private final class TurnLoopDriveBox: @unchecked Sendable {
        var value: TurnLoopDrive?
    }

    /// The probe's stub synthesizer: renders its script verbatim (no engine — the reply's
    /// known-output reference), `cancel` a safe no-op.
    private struct ProbeTurnSynthesizer: SpeechSynthesizer {
        let identity = VoiceIdentity(engineID: "probe-turn-stub", voiceName: nil)
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

    /// The probe's hand-moved clock — a final class (reference), so the loop's view and the
    /// drive's view are the same time base.
    private final class ProbeTurnClock: MonotonicClock {
        var now: Duration = .zero
    }

    /// The round trip itself.
    private static func runTurnRoundTrip() async throws -> TurnLoopDrive {
        let clock = ProbeTurnClock()
        let synth = ProbeTurnSynthesizer(
            script: [
                AudioChunk(
                    bytes: probeChunkBytes(amplitude: 0.4, frequency: 440, samples: 4000),
                    sampleRate: 16_000, channelCount: 1, duration: 0.25)
            ])

        var effects: [TurnEffect] = []
        var history: [TurnEffect] = []
        let loop = TurnTakingLoop(
            vad: EnergyVAD(
                configuration: VADConfiguration(
                    onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)),
            turnDetector: SilenceThresholdDetector(
                configuration: SilenceThresholdConfiguration(
                    commitAfterPause: 0.5, minimumUtteranceDuration: 0.2)),
            clock: clock,
            gate: EchoGate(),
            onEffect: { effect in
                effects.append(effect)
                history.append(effect)
            })

        let silence = AudioBuffer(
            samples: [Float](repeating: 0, count: 1000), sampleRate: 16_000)
        let speech440 = probeTone(amplitude: 0.4, frequency: 440, samples: 1000)
        let user880 = probeTone(amplitude: 0.4, frequency: 880, samples: 1000)
        // The 0.85-scaled echo, phase-aligned to the reference's tail: the reply chunk holds
        // 4000 samples (110 full 440 Hz cycles), and the gate tail-aligns over the last
        // 1000 — the echo must be those same samples scaled, or the correlation would be
        // phase-dependent (ρ = cos φ), not the pure-echo 1.0.
        let echo440 = AudioBuffer(
            samples: (0..<1000).map { index in
                0.4 * 0.85 * Float(sin(2 * Double.pi * 440 * Double(3000 + index) / 16_000))
            },
            sampleRate: 16_000)

        func drain() async throws {
            while !effects.isEmpty {
                let effect = effects.removeFirst()
                switch effect {
                case .turnCommitted:
                    loop.scheduleReply("hello")
                case .speakReply(let text):
                    for try await _ in synth.speak(text) {}
                    loop.reportPlaybackStarted()
                    for chunk in synth.script {
                        loop.reportPlaybackChunk(chunk)
                    }
                case .started, .stopped, .speechBegan, .bargeIn, .captureFailed:
                    break
                }
            }
        }

        loop.start()
        for _ in 0..<7 { loop.feed(silence) }        // 0.4 s of silence
        for _ in 0..<20 { loop.feed(speech440) }     // 1.2 s of speech → uttering
        for _ in 0..<14 { loop.feed(silence) }       // 0.85 s pause → first commit
        try await drain()                                // schedule + play the first reply (window open)

        loop.feed(echo440)                           // the loop's own output — gated
        loop.feed(user880)                           // accepted (orthogonal residue) — seed
        loop.feed(user880)                           // VAD flips → barge-in
        loop.reportPlaybackEnded()
        for _ in 0..<3 { loop.feed(user880) }        // the interrupting utterance
        for _ in 0..<14 { loop.feed(silence) }       // 0.85 s pause → second commit
        try await drain()                                // schedule + play the second reply (window open)
        loop.reportPlaybackEnded()

        loop.stop()

        let started = history.filter { $0 == .started }.count
        let commits = history.filter { effect in
            if case .turnCommitted = effect { return true } else { return false }
        }.count
        let replies = history.filter { effect in
            if case .speakReply = effect { return true } else { return false }
        }.count
        let bargeIns = history.filter { $0 == .bargeIn }.count

        return TurnLoopDrive(
            report: [
                "started=\(started)",
                "turnCommits=\(commits)",
                "replies=\(replies)",
                "bargeIns=\(bargeIns)",
                "gated=\(loop.gatedFrameCount)",
                "fed=\(loop.fedFrameCount)",
                "state=\(loop.state)",
            ].joined(separator: " "),
            moduleWitness: type(of: loop))
    }

    /// A 440/880 Hz tone frame at 16 kHz.
    private static func probeTone(amplitude: Float, frequency: Double, samples: Int) -> AudioBuffer {
        AudioBuffer(
            samples: (0..<samples).map { index in
                amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / 16_000))
            },
            sampleRate: 16_000)
    }

    /// Little-endian Float32 PCM bytes at 16 kHz.
    private static func probeChunkBytes(amplitude: Float, frequency: Double, samples: Int) -> [UInt8] {
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