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

/// The shared frame builders for the voice-activity fixtures (`plan_20260915.md` Phase 1 file
/// 1). Frames are **1000 samples (62.5 ms)** at the interchange 16 kHz rate, and the sine is
/// 440 Hz — 27.5 cycles per frame, an integer number of half-cycles, so a tone's RMS is
/// exactly `amplitude / √2` and every fixture's margin against its boundaries is the plan's.
///
/// The builders live here (a plain internal enum in the harness module) so that the seam tests
/// and the `VoiceActivityFixtureSuite` leg construct the same bytes; the `sdk-adapters` aspect
/// reuses them for its env-gated real leg.
enum VoiceActivityFixtures {

    /// An all-zero frame — RMS 0, silence evidence.
    static func makeSilence(samples: Int) -> AudioBuffer {
        AudioBuffer(samples: [Float](repeating: 0, count: samples), sampleRate: 16_000)
    }

    /// A 440 Hz sine at the given amplitude — RMS ≈ `amplitude / √2`.
    static func makeTone(amplitude: Float, samples: Int) -> AudioBuffer {
        let frames = (0..<samples).map { index in
            amplitude * Float(sin(2 * Double.pi * 440 * Double(index) / 16_000))
        }
        return AudioBuffer(samples: frames, sampleRate: 16_000)
    }

    /// A constant-amplitude frame — RMS is exactly `value`.
    static func makeConstant(_ value: Float, samples: Int) -> AudioBuffer {
        AudioBuffer(samples: [Float](repeating: value, count: samples), sampleRate: 16_000)
    }

    /// One tone frame per entry of `amplitudes` — the "ramp" is the sequence of increasing
    /// amplitudes, each frame a constant-amplitude tone (RMS `amplitude / √2`).
    static func makeRamp(amplitudes: [Float], samples: Int = 1000) -> [AudioBuffer] {
        amplitudes.map { makeTone(amplitude: $0, samples: samples) }
    }
}

/// The VAD seam: the protocol `ARCHITECTURE.md:262-263` specifies, as code, with the
/// synchronous per-frame contract and the stateful hysteresis (S1) pinned.
///
/// Where ``ASREngineSeamTests`` pinned the ASR seam's shape and behaviour, this suite pins the
/// VAD seam's — against the only `VoiceActivityDetector` a hosted runner can ever run,
/// ``EnergyVAD``. The real `SileroVAD` (FluidAudio adapter) needs a model file a hosted runner
/// has neither; everything here is a claim about the seam as the adapters will find it:
///
/// - the seam carries its ``VADConfiguration`` and classifies frames through a `mutating`
///   call — hysteresis (S1) is inherently stateful, and a struct keeps the state `Sendable`
///   honestly (no `@unchecked` anywhere);
/// - ``SpeechActivity`` has exactly `.silence` and `.speech` — a caller's switch is exhaustive
///   today and breaks at compile time if the vocabulary grows;
/// - the committed fixture table classifies as written by hand (every row carries ≥10%
///   amplitude margin against every boundary it crosses — Float-ulp territory is deliberately
///   not pinned);
/// - hysteresis: the dead zone `[offsetRMS, onsetRMS)` freezes evidence accumulation, and a
///   flip resets both accumulators;
/// - the decision is over the present samples only (`missingSampleCount` never changes it),
///   is chunk-shape-invariant (hold times are duration-based), retains the state on empty and
///   non-finite frames, and callers never branch on implementation.
final class VoiceActivitySeamTests: XCTestCase {

    /// The fixture configuration for every row (`plan_20260915.md` §Testing strategy):
    /// `onsetRMS 0.05`, `offsetRMS 0.02`, `minimumSpeech 0.10 s` (1600 samples),
    /// `minimumSilence 0.20 s` (3200 samples).
    private static let configuration = VADConfiguration(
        onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)

    /// The seam exists, carries its configuration, and classifies a frame — the compile pin
    /// `ASREngineSeamTests` applies: if the protocol's shape is ever weakened or renamed, this
    /// stops compiling rather than coercing.
    func testTheSeamCarriesConfigurationAndClassifiesFrames() {
        func requireDetector(_ detector: any VoiceActivityDetector) -> any VoiceActivityDetector {
            detector
        }

        var detector: any VoiceActivityDetector = requireDetector(
            EnergyVAD(configuration: Self.configuration))
        XCTAssertEqual(
            detector.configuration, Self.configuration,
            "the configuration is carried by the seam — callers tune the VAD through it, never around it")
        XCTAssertEqual(
            detector.classify(VoiceActivityFixtures.makeSilence(samples: 1000)), .silence,
            "a silence frame classifies as silence through the existential, not through a concrete type")
    }

    /// ``SpeechActivity`` has exactly `.silence` and `.speech` — the exhaustive switch is the
    /// compile pin: a third case stops this test (and every caller's switch) from building.
    func testSpeechActivityIsExactlySilenceOrSpeech() {
        func describe(_ activity: SpeechActivity) -> String {
            switch activity {
            case .silence: return "silence"
            case .speech: return "speech"
            }
        }
        XCTAssertEqual(describe(.silence), "silence")
        XCTAssertEqual(describe(.speech), "speech")
    }

    /// ``VADConfiguration`` is plain data (S1): the four fields the composition root tunes,
    /// carried by value and `Sendable` — the compile pin for "hysteresis carried as plain
    /// data, not buried in an implementation".
    func testVADConfigurationIsPlainDataAndSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        let configuration = requireSendable(Self.configuration)
        XCTAssertEqual(configuration.onsetRMS, 0.05)
        XCTAssertEqual(configuration.offsetRMS, 0.02)
        XCTAssertEqual(configuration.minimumSpeech, 0.10)
        XCTAssertEqual(configuration.minimumSilence, 0.20)
    }

    /// `all-silence`: four zero frames stay silence throughout — absence of evidence never
    /// flips.
    func testAllSilenceStaysSilentThroughout() {
        var detector: any VoiceActivityDetector = EnergyVAD(configuration: Self.configuration)
        let frames = (0..<4).map { _ in VoiceActivityFixtures.makeSilence(samples: 1000) }

        let classifications = frames.map { detector.classify($0) }

        XCTAssertEqual(
            classifications, [.silence, .silence, .silence, .silence],
            "an all-silence run never flips — a VAD that invents speech from silence is a VAD that cannot be trusted")
    }

    /// `tone-burst`: 2 zeros + 6 tones @ 0.4 (RMS ≈ 0.283 — 5.6× the onset, margin by design).
    /// Speech evidence needs 1600 samples; it accumulates at 1000 per frame and flips during
    /// frame 4.
    func testToneBurstFlipsToSpeechAfterTheSpeechHold() {
        var detector: any VoiceActivityDetector = EnergyVAD(configuration: Self.configuration)
        var frames: [AudioBuffer] = (0..<2).map { _ in VoiceActivityFixtures.makeSilence(samples: 1000) }
        frames += (0..<6).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1000) }

        let classifications = frames.map { detector.classify($0) }

        XCTAssertEqual(
            classifications, [.silence, .silence, .silence, .speech, .speech, .speech, .speech, .speech],
            "speech evidence accumulates in samples (1000/frame) and flips when it reaches the 1600-sample hold")
    }

    /// `onset-offset-hysteresis`: 2 zeros + 2 tones @ 0.4 + 3 tones @ 0.035 (RMS ≈ 0.0247 —
    /// dead zone `[0.02, 0.05)`, 24% above the offset, state retained) + 4 tones @ 0.01
    /// (RMS ≈ 0.0071 — 2.8× below the offset). Silence evidence needs 3200 samples; the dead
    /// zone freezes both accumulators and the flip lands during frame 11.
    func testOnsetOffsetHysteresisRetainsSpeechThroughTheDeadZone() {
        var detector: any VoiceActivityDetector = EnergyVAD(configuration: Self.configuration)
        var frames: [AudioBuffer] = (0..<2).map { _ in VoiceActivityFixtures.makeSilence(samples: 1000) }
        frames += (0..<2).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1000) }
        frames += (0..<3).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.035, samples: 1000) }
        frames += (0..<4).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.01, samples: 1000) }

        let classifications = frames.map { detector.classify($0) }

        XCTAssertEqual(
            classifications, [.silence, .silence, .silence, .speech, .speech, .speech, .speech,
                .speech, .speech, .speech, .silence],
            "the dead zone freezes evidence accumulation — the 3 mid-level frames neither advance "
                + "speech nor shorten the 3200-sample silence hold")
    }

    /// `amplitude-ramp`: 6 ramp frames (amplitudes 0, 0.08, 0.16, 0.24, 0.32, 0.4 → RMS 0,
    /// 0.057 — 13% above onset, 0.113, …) + 4 tones @ 0.4 + 4 zeros. Evidence starts at frame
    /// 2, flips during frame 3; the silence evidence is 3000 < 3200 by frame 13 and flips
    /// during frame 14.
    func testAmplitudeRampFlipsWithTheEvidenceAndNeedsTheFullSilenceHold() {
        var detector: any VoiceActivityDetector = EnergyVAD(configuration: Self.configuration)
        var frames: [AudioBuffer] = VoiceActivityFixtures.makeRamp(
            amplitudes: [0, 0.08, 0.16, 0.24, 0.32, 0.4])
        frames += (0..<4).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1000) }
        frames += (0..<4).map { _ in VoiceActivityFixtures.makeSilence(samples: 1000) }

        let classifications = frames.map { detector.classify($0) }

        XCTAssertEqual(
            classifications, [.silence, .silence, .speech, .speech, .speech, .speech, .speech,
                .speech, .speech, .speech, .speech, .speech, .speech, .silence],
            "the flip to silence needs the full 3200-sample hold — 3000 samples by frame 13 do not flip")
    }

    /// `constant-at-margin`: 3 × constant 0.06 (RMS = 0.06 — 20% above onset) — constant runs
    /// classify stably at the configured level. Boundary equality is Float-ulp territory and
    /// is deliberately not pinned; the margin is what is pinned.
    func testConstantAmplitudeAtMarginClassifiesStably() {
        var detector: any VoiceActivityDetector = EnergyVAD(configuration: Self.configuration)
        let frames = (0..<3).map { _ in VoiceActivityFixtures.makeConstant(0.06, samples: 1000) }

        let classifications = frames.map { detector.classify($0) }

        XCTAssertEqual(
            classifications, [.silence, .speech, .speech],
            "a constant run at 20% above onset flips once the 1600-sample hold is met and stays flipped")
    }

    /// The dead zone freezes **both** accumulators: mid-level frames between speech evidence
    /// and silence evidence neither advance speech nor shorten the silence hold.
    ///
    /// The `onset-offset-hysteresis` row pins this through the full 11-frame script; this test
    /// pins the mechanism in isolation — after a flip to speech, two dead-zone frames add
    /// nothing, and the three silence frames (3000 samples) still do not flip.
    func testTheDeadZoneFreezesEvidenceAccumulation() {
        var detector: any VoiceActivityDetector = EnergyVAD(configuration: Self.configuration)
        var frames: [AudioBuffer] = (0..<2).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1000) }
        frames += (0..<2).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.035, samples: 1000) }
        frames += (0..<3).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.01, samples: 1000) }
        frames.append(VoiceActivityFixtures.makeTone(amplitude: 0.01, samples: 1000))

        let classifications = frames.map { detector.classify($0) }

        XCTAssertEqual(
            classifications, [.silence, .speech, .speech, .speech, .speech, .speech, .speech, .silence],
            "two dead-zone frames contribute no evidence — the silence hold still needs all 3200 samples")
    }

    /// The decision is over the present samples only: a buffer with `N` missing samples
    /// classifies identically to the same samples with `0` (`AudioBuffer.swift:50-58`).
    /// Completeness is the ASR seam's concern, not VAD's.
    func testMissingSamplesDoNotChangeTheDecision() {
        func classify(script: [AudioBuffer]) -> [SpeechActivity] {
            var detector: any VoiceActivityDetector = EnergyVAD(configuration: Self.configuration)
            return script.map { detector.classify($0) }
        }

        let complete: [AudioBuffer] = [
            VoiceActivityFixtures.makeSilence(samples: 1000),
            VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1000),
            VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1000),
        ]
        let incomplete: [AudioBuffer] = complete.map {
            AudioBuffer(
                samples: $0.samples, sampleRate: $0.sampleRate, missingSampleCount: 480)
        }

        XCTAssertEqual(
            classify(script: complete), classify(script: incomplete),
            "missingSampleCount must not reach the VAD decision — the decision is over the present samples only")
    }

    /// Chunk-shape invariance: hold times are duration-based (converted to samples at init), so
    /// any chunking of the same waveform flips at the same cumulative sample count. One
    /// 1600-sample frame and four 400-sample frames both flip when 1600 samples of speech
    /// evidence have accumulated — and an oversize single frame flips on its own.
    func testChunkingDoesNotChangeWhenSpeechStarts() {
        func cumulativeSamplesAtFirstSpeech(_ script: [AudioBuffer]) -> Int {
            var detector: any VoiceActivityDetector = EnergyVAD(configuration: Self.configuration)
            var seen = 0
            for frame in script {
                seen += frame.samples.count
                if detector.classify(frame) == .speech { break }
            }
            return seen
        }

        let merged = [VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1600)]
        let split = (0..<4).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 400) }
        let oversize = [VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 4000)]

        XCTAssertEqual(
            cumulativeSamplesAtFirstSpeech(merged), 1600,
            "a single 1600-sample frame satisfies the 1600-sample hold on its own")
        XCTAssertEqual(
            cumulativeSamplesAtFirstSpeech(split), 1600,
            "four 400-sample frames flip at the same cumulative sample count — the hold is in samples, not frames")
        XCTAssertEqual(
            cumulativeSamplesAtFirstSpeech(oversize), 4000,
            "an oversize frame flips on its own — the first classify sees 4000 ≥ 1600 samples of evidence")
    }

    /// An empty frame carries no evidence, accumulates nothing, and returns the current state —
    /// pinned from silence (the initial state) and from speech (after a flip).
    func testEmptyFramesRetainTheStateWithoutAccumulating() {
        var detector: any VoiceActivityDetector = EnergyVAD(configuration: Self.configuration)

        XCTAssertEqual(
            detector.classify(VoiceActivityFixtures.makeSilence(samples: 0)), .silence,
            "an empty frame from the initial silence state stays silence")

        let tone = VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1000)
        _ = detector.classify(tone)
        XCTAssertEqual(detector.classify(tone), .speech, "two tone frames flip to speech")

        XCTAssertEqual(
            detector.classify(VoiceActivityFixtures.makeSilence(samples: 0)), .speech,
            "an empty frame from the speech state retains speech — no evidence, no accumulation, no flip")
    }

    /// Non-finite samples are producer-bug territory (the producer's -1.0…1.0 contract,
    /// `AudioBuffer.swift:43-45`): a NaN/±inf RMS satisfies neither comparison, falls in the
    /// dead zone, and the state is retained. Pinned once so the behaviour is explicit, not
    /// accidental.
    func testNonFiniteSamplesRetainTheState() {
        var detector: any VoiceActivityDetector = EnergyVAD(configuration: Self.configuration)
        let nan = AudioBuffer(samples: [.nan, .nan], sampleRate: 16_000)
        let positiveInfinity = AudioBuffer(samples: [.infinity], sampleRate: 16_000)

        XCTAssertEqual(detector.classify(nan), .silence, "NaN RMS is in the dead zone — silence is retained")
        XCTAssertEqual(
            detector.classify(positiveInfinity), .silence,
            "an RMS that satisfies neither comparison accumulates nothing — the state is retained, not flipped")

        let tone = VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1000)
        _ = detector.classify(tone)
        XCTAssertEqual(detector.classify(tone), .speech)
        XCTAssertEqual(
            detector.classify(nan), .speech,
            "from the speech state a non-finite frame retains speech — the dead zone freezes, it never flips")
    }

    /// Callers never branch on implementation: the driver below is written against the seam's
    /// existential alone — the concrete fallback is invisible to it — and the stub double
    /// proves the protocol (not the fallback) is what the driver speaks. A caller that names
    /// `EnergyVAD` at a decision point would not satisfy this shape.
    func testCallersDriveTheSeamThroughTheProtocolOnly() {
        struct FixedActivityVAD: VoiceActivityDetector {
            let configuration: VADConfiguration
            private var heardSpeech = false

            mutating func classify(_ frame: AudioBuffer) -> SpeechActivity {
                if !frame.samples.isEmpty { heardSpeech = true }
                return heardSpeech ? .speech : .silence
            }
        }

        func drive(_ detector: inout any VoiceActivityDetector, frames: [AudioBuffer])
            -> [SpeechActivity]
        {
            var classifications: [SpeechActivity] = []
            for frame in frames { classifications.append(detector.classify(frame)) }
            return classifications
        }

        var detector: any VoiceActivityDetector = FixedActivityVAD(configuration: Self.configuration)
        let frames: [AudioBuffer] = [
            VoiceActivityFixtures.makeSilence(samples: 1000),
            VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1000),
        ]

        XCTAssertEqual(
            drive(&detector, frames: frames), [.silence, .speech],
            "the driver's contract is the protocol — both answers flow through the existential, and "
                + "the caller never names the implementation")
    }
}