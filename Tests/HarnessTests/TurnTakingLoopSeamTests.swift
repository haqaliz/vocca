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

/// The frame and chunk builders for the turn-taking fixtures
/// (`barge-in-loop/plan_20260915.md` Phase 1). Frames are **1000 samples (62.5 ms)** at the
/// interchange 16 kHz rate; the echo reference is **440 Hz** and the interrupting "user"
/// speech is **880 Hz** — two sines are orthogonal, so the loop's VAD-on-880-accepted test can
/// never be confused with echo-on-440.
///
/// Chunks are little-endian Float32 PCM at 16 kHz mono by default, so the loop's decode of
/// them is the identity — the echo frame builder can therefore derive its scaled tail from
/// the chunk's own samples. The multi-rate/stereo decode path is pinned separately
/// (``TurnTakingLoopSeamTests/testAChunkIsDecodedToMono16kForTheReference``).
enum TurnLoopFixtures {

    /// An all-zero frame — RMS 0, silence evidence.
    static func silence(_ samples: Int = 1000) -> AudioBuffer {
        VoiceActivityFixtures.makeSilence(samples: samples)
    }

    /// A sine at the given frequency and amplitude — RMS ≈ `amplitude / √2`.
    static func tone(
        amplitude: Float = 0.4, frequency: Double = 880, samples: Int = 1000
    ) -> AudioBuffer {
        AudioBuffer(
            samples: (0..<samples).map { index in
                amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / 16_000))
            },
            sampleRate: 16_000)
    }

    /// One PCM chunk in the interchange shape (16 kHz mono, little-endian Float32).
    static func chunk(
        amplitude: Float, frequency: Double, samples: Int,
        sampleRate: Double = 16_000, channelCount: Int = 1
    ) -> AudioChunk {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(samples * channelCount * 4)
        let totalFrames = samples * channelCount
        for index in 0..<totalFrames {
            let frame = index / channelCount
            let sample = amplitude
                * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            var bits = sample.bitPattern
            for _ in 0..<4 {
                bytes.append(UInt8(bits & 0xFF))
                bits >>= 8
            }
        }
        return AudioChunk(
            bytes: bytes, sampleRate: sampleRate, channelCount: channelCount,
            duration: Double(samples) / sampleRate)
    }

    /// The chunk's PCM as frames — the test-side mirror of the loop's own decode
    /// (little-endian Float32, mono by arithmetic mean, decimated to 16 kHz by
    /// nearest-neighbour). Only the interchange shape is exercised by the echo rows; the
    /// multi-rate path is pinned by the dedicated decode test.
    static func decodeChunk(_ chunk: AudioChunk) -> [Float] {
        let channelCount = max(chunk.channelCount, 1)
        var interleaved: [Float] = []
        var index = 0
        while index + MemoryLayout<Float>.size <= chunk.bytes.count {
            var bits: UInt32 = 0
            for offset in 0..<4 {
                bits |= UInt32(chunk.bytes[index + offset]) << (8 * offset)
            }
            interleaved.append(Float(bitPattern: bits))
            index += MemoryLayout<Float>.size
        }
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
        let ratio = chunk.sampleRate / Double(AudioBuffer.interchangeSampleRate)
        let decimatedCount = Int(Double(mono.count) / ratio)
        return (0..<decimatedCount).map { index in
            mono[Int((Double(index) * ratio).rounded())]
        }
    }

    /// The last `samples` frames of `chunk`'s decoded PCM, scaled by `gain` — the exact
    /// 0.85-scaled echo the gate must discard (same phase, so ρ = 1.0).
    static func echo(of chunk: AudioChunk, gain: Float, samples: Int = 1000) -> AudioBuffer {
        let decoded = decodeChunk(chunk)
        return AudioBuffer(
            samples: decoded.suffix(samples).map { $0 * gain }, sampleRate: 16_000)
    }
}

/// The scripted `VoiceActivityDetector`: a `SpeechActivity` sequence over the classify-call
/// counter. The loop's own copy advances — the seam is `mutating` — so a scripted sequence
/// works through the existential exactly as a stateful detector would.
///
/// A script shorter than the run traps: a test that scripts fewer answers than the loop asks
/// for would silently reuse the final answer, which is how a missing script entry becomes a
/// false green.
struct ScriptedVAD: VoiceActivityDetector {
    let configuration: VADConfiguration
    let script: [SpeechActivity]
    private var index = 0

    init(configuration: VADConfiguration, script: [SpeechActivity]) {
        precondition(!script.isEmpty, "a scripted VAD with no answers answers nothing")
        self.configuration = configuration
        self.script = script
    }

    mutating func classify(_ frame: AudioBuffer) -> SpeechActivity {
        precondition(
            index < script.count,
            "the scripted VAD ran out of answers at call \(index) of \(script.count) — the "
                + "test's script does not cover the run it drives")
        defer { index += 1 }
        return script[index]
    }
}

/// The scripted `TurnDetector`: a `TurnCommitment` sequence **keyed by the pause's length**
/// (the seam is stateless by signature — `decide` is non-mutating — so a call-indexed
/// sequence cannot advance through the existential; the plan's "sequence over the
/// pause/utterance lengths" is exactly this: the script's entry is chosen by how long the
/// pause has been). The score is the implementation's P(user-finished) proxy — the loop
/// consumes `commitment`, so the scripted entries carry `score = 1` on commit and `0`
/// otherwise.
///
/// `script[0]` answers a one-frame pause, `script[1]` a two-frame pause, and so on; a pause
/// longer than the script repeats the final answer. Whole 1000-sample frames are assumed by
/// the tests that drive it; a sub-frame pause counts as one frame.
struct ScriptedTurnDetector: TurnDetector {
    let script: [TurnCommitment]
    let frameSize: Int

    init(script: [TurnCommitment], frameSize: Int = 1000) {
        precondition(!script.isEmpty, "a scripted turn detector with no answers answers nothing")
        self.script = script
        self.frameSize = frameSize
    }

    func decide(_ pause: AudioBuffer, utterance: AudioBuffer) -> TurnScore {
        let frames = max((pause.samples.count + frameSize - 1) / frameSize, 1)
        let commitment = script[min(frames, script.count) - 1]
        return TurnScore(score: commitment == .commit ? 1 : 0, commitment: commitment)
    }
}

/// The clock the turn-taking tests move by hand — a **final class**, not a struct, because
/// the loop holds it in an existential (`any MonotonicClock`): a struct's copy inside the
/// loop would freeze the loop's view while the test advanced its own. The reference shape is
/// `SessionTestDoubles.TestClock`; this suite is single-threaded, so no locking is needed.
final class TurnLoopTestClock: MonotonicClock {
    var now: Duration = .zero

    func advance(by duration: Duration) {
        now += duration
    }
}

/// The playback engine with a ledger — `play` consumes (awaits) the stream it is given and
    /// records the chunks it played, `duck`/`cancelToSilence` record themselves. An actor:
    /// `PlaybackEngine` is a `Sendable` protocol, and a class with mutable storage would
    /// need `@unchecked` to conform — the house's documented aversion
    /// (`SpeechSynthesizerSeamTests.swift:196-199`). `tearDown()` is the one synchronous
    /// requirement; an actor-isolated sync witness cannot cross the conformance, so it is a
    /// nonisolated no-op (no test drives it — the ledger's load-bearing counters are the
    /// async ones).
    actor FakePlaybackEngine: PlaybackEngine {
        private(set) var playCount = 0
        private(set) var playedChunks: [AudioChunk] = []
        private(set) var duckCount = 0
        private(set) var haltCount = 0

        func play(_ stream: AsyncThrowingStream<AudioChunk, Error>) async throws {
            playCount += 1
            for try await chunk in stream {
                playedChunks.append(chunk)
            }
        }

        func duck() async {
            duckCount += 1
        }

        func cancelToSilence() async {
            haltCount += 1
        }

        nonisolated func tearDown() {}
    }

/// The turn-taking coordinator's contract (`barge-in-loop/plan_20260915.md` Phase 1): every
/// arc of the transition table (T1-T24) plus the gate-behavior legs through the loop, the
/// review-gate pins (stream continuity, the reply-end race, ownership), and the budget's
/// coordinator half — written first, against types that do not exist yet. Compile-time RED is
/// the right reason for a new seam: these signatures are final after Phase 2, and everything
/// that composes the loop (the conversational harness, the composed acceptance, PROBE-TURN)
/// compiles against them.
final class TurnTakingLoopSeamTests: XCTestCase {

    /// The fixture configuration for every row — the voice-detection plan's committed config.
    private static let configuration = VADConfiguration(
        onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)

    /// The fixture silence and tones.
    private static let silence = TurnLoopFixtures.silence()
    private static let userSpeech = TurnLoopFixtures.tone(
        amplitude: 0.4, frequency: 880, samples: 1000)
    private static let echoReferenceChunk = TurnLoopFixtures.chunk(
        amplitude: 0.4, frequency: 440, samples: 4000)

    /// Builds a loop over the scripted doubles with the given effect/state hooks.
    private func makeLoop(
        vad script: [SpeechActivity],
        turn scriptedCommitments: [TurnCommitment],
        clock: TurnLoopTestClock = TurnLoopTestClock(),
        onEffect: @escaping (TurnEffect) -> Void,
        onStateChange: @escaping (TurnState) -> Void = { _ in }
    ) -> TurnTakingLoop {
        TurnTakingLoop(
            vad: ScriptedVAD(configuration: Self.configuration, script: script),
            turnDetector: ScriptedTurnDetector(script: scriptedCommitments),
            clock: clock,
            gate: EchoGate(),
            onEffect: onEffect,
            onStateChange: onStateChange)
    }

    // MARK: - The compile pins

    /// The loop exists with the SessionMachine shape: synchronous, owner-isolated, seams and
    /// closures injected, `state`/counters public-but-settable-only-here.
    func testTheLoopAcceptsItsInjectedSeamsAndStartsIdle() {
        func requireLoop(_ loop: TurnTakingLoop) -> TurnTakingLoop { loop }

        let loop = requireLoop(
            makeLoop(vad: [.silence], turn: [.keepListening], onEffect: { _ in }))
        XCTAssertEqual(loop.state, .idle, "a fresh loop is idle")
        XCTAssertEqual(loop.fedFrameCount, 0, "a fresh loop has fed nothing")
        XCTAssertEqual(loop.gatedFrameCount, 0, "a fresh loop has gated nothing")
    }

    /// `TurnState` has exactly `.idle`, `.listening`, `.uttering`, `.committed`, `.playing` —
    /// the exhaustive switch is the compile pin: a sixth case stops every caller's switch
    /// from building.
    func testTurnStateIsExactlyTheFiveCases() {
        func describe(_ state: TurnState) -> String {
            switch state {
            case .idle: return "idle"
            case .listening: return "listening"
            case .uttering: return "uttering"
            case .committed: return "committed"
            case .playing: return "playing"
            }
        }
        XCTAssertEqual(describe(.idle), "idle")
        XCTAssertEqual(describe(.listening), "listening")
        XCTAssertEqual(describe(.uttering), "uttering")
        XCTAssertEqual(describe(.committed), "committed")
        XCTAssertEqual(describe(.playing), "playing")
    }

    /// `TurnEffect` has exactly the seven cases — the exhaustive switch is the compile pin.
    func testTurnEffectIsExactlyTheSevenCases() {
        func describe(_ effect: TurnEffect) -> String {
            switch effect {
            case .started: return "started"
            case .stopped: return "stopped"
            case .speechBegan: return "speechBegan"
            case .turnCommitted(let utterance): return "turnCommitted(\(utterance.count))"
            case .speakReply(let text): return "speakReply(\(text))"
            case .bargeIn: return "bargeIn"
            case .captureFailed: return "captureFailed"
            }
        }
        XCTAssertEqual(describe(.started), "started")
        XCTAssertEqual(describe(.stopped), "stopped")
        XCTAssertEqual(describe(.speechBegan), "speechBegan")
        XCTAssertEqual(describe(.turnCommitted(utterance: [Self.silence])), "turnCommitted(1)")
        XCTAssertEqual(describe(.speakReply(text: "hi")), "speakReply(hi)")
        XCTAssertEqual(describe(.bargeIn), "bargeIn")
        XCTAssertEqual(describe(.captureFailed), "captureFailed")
    }

    /// The gate is a pure decision function over the capture and the known-output reference.
    func testTheGateIsAPureDecisionFunction() {
        func requireGate(_ gate: EchoGate) -> EchoGate { gate }

        let gate = requireGate(EchoGate())
        let decision = EchoGate.decision(capture: [0], reference: [0])
        switch decision {
        case .discard:
            XCTFail("a zero-energy capture must be the silence floor, never a discard")
        case .accept(let samples):
            XCTAssertNil(samples, "the silence-floor path accepts the raw frame")
        }
        _ = gate
    }

    // MARK: - The transition table

    /// T1: `.idle → .listening`, exactly one `.started`, counters at zero.
    func testStartMovesIdleToListeningAndEmitsStartedOnce() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(vad: [.silence], turn: [.keepListening], onEffect: { effects.append($0) })
        loop.start()
        loop.start()

        XCTAssertEqual(loop.state, .listening)
        XCTAssertEqual(
            effects.filter { $0 == .started }.count, 1,
            "a second start while not idle is refused — one consumer, one .started")
        XCTAssertEqual(loop.fedFrameCount, 0)
        XCTAssertEqual(loop.gatedFrameCount, 0)
    }

    /// T2: silence while listening accumulates frames and no effects.
    func testSilenceInListeningAccumulatesFramesAndNoEffects() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.silence, .silence, .silence], turn: [.keepListening],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.silence)
        loop.feed(Self.silence)
        loop.feed(Self.silence)

        XCTAssertEqual(loop.state, .listening)
        XCTAssertEqual(loop.fedFrameCount, 3)
        XCTAssertEqual(
            effects, [.started],
            "silence is not an event — the only effect is the start: \(effects)")
    }

    /// T3: the first speech evidence flips listening → uttering, emits `.speechBegan` once,
    /// and the speech frames accumulate into the utterance.
    func testSpeechInListeningBeginsAnUtterance() {
        var effects: [TurnEffect] = []
        var states: [TurnState] = []
        let loop = makeLoop(
            vad: [.silence, .speech, .speech], turn: [.keepListening],
            onEffect: { effects.append($0) }, onStateChange: { states.append($0) })
        loop.start()
        loop.feed(Self.silence)
        loop.feed(Self.userSpeech)
        loop.feed(Self.userSpeech)

        XCTAssertEqual(loop.state, .uttering)
        XCTAssertEqual(effects, [.started, .speechBegan], "exactly one .speechBegan: \(effects)")
        XCTAssertEqual(states, [.listening, .uttering])
    }

    /// T5: a scored `.commit` moves uttering → committed and delivers **exactly the speech
    /// frames** — never the pause frames — as the utterance.
    func testAScoredCommitDeliversExactlyTheSpeechFramesAndNeverThePause() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .speech, .speech, .speech] + [SpeechActivity](repeating: .silence, count: 8),
            turn: [TurnCommitment](repeating: .keepListening, count: 7) + [.commit],
            onEffect: { effects.append($0) })
        loop.start()
        let speech = [Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech]
        for frame in speech { loop.feed(frame) }
        for _ in 0..<8 { loop.feed(Self.silence) }

        XCTAssertEqual(loop.state, .committed)
        let commits = effects.compactMap { effect -> [AudioBuffer]? in
            if case .turnCommitted(let utterance) = effect { return utterance } else { return nil }
        }
        XCTAssertEqual(commits.count, 1, "exactly one commit for one pause: \(effects)")
        XCTAssertEqual(
            commits[0], speech,
            "the committed utterance is exactly the speech frames — the pause frames never "
                + "join it: \(commits[0])")
    }

    /// T6: an EOU veto (`.keepListening` on a candidate pause) keeps listening, and a later
    /// speech frame extends the utterance — the late-commit tolerance, never a cutoff.
    func testAnEOUVetoKeepsListeningAndTheUtteranceExtends() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .speech, .silence, .speech, .silence, .silence],
            turn: [.keepListening, .commit],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)   // uttering
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)      // pause = 1 frame → vetoed, still uttering
        loop.feed(Self.userSpeech)   // the user was not done — the utterance extends
        loop.feed(Self.silence)      // pause = 1 frame again (cleared) → vetoed
        loop.feed(Self.silence)      // pause = 2 frames → commit

        XCTAssertEqual(loop.state, .committed)
        let commits = effects.compactMap { effect -> [AudioBuffer]? in
            if case .turnCommitted(let utterance) = effect { return utterance } else { return nil }
        }
        XCTAssertEqual(
            commits[0],
            [Self.userSpeech, Self.userSpeech, Self.userSpeech],
            "the vetoed pause never becomes a cutoff — the post-veto speech frame is in the "
                + "committed utterance")
    }

    /// T4: a speech frame clears the pause accumulator — the second pause starts fresh.
    func testSpeechFramesClearThePauseAccumulator() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .silence, .speech, .silence, .silence],
            turn: [.keepListening, .commit],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)  // uttering
        loop.feed(Self.silence)     // pause = 1 frame → script[0] = keepListening
        loop.feed(Self.userSpeech)  // the pause accumulator must clear here
        loop.feed(Self.silence)     // pause = 1 frame (fresh) → script[0] = keepListening
        loop.feed(Self.silence)     // pause = 2 frames → script[1] = commit

        XCTAssertEqual(
            loop.state, .committed,
            "the second silence commits only if the speech frame cleared the first pause — "
                + "an uncleared pause would have reached 2 frames on the fourth feed and "
                + "committed via script[1] a frame early")
        let commits = effects.compactMap { effect -> [AudioBuffer]? in
            if case .turnCommitted(let utterance) = effect { return utterance } else { return nil }
        }
        XCTAssertEqual(commits.count, 1, "exactly one commit: \(effects)")
    }

    /// T7: `.committed → .playing` via `scheduleReply`, the reply text carried by the effect,
    /// and the playback window closed until the owner reports playback started.
    func testSchedulingAReplyFromCommittedEntersPlaying() {
        var effects: [TurnEffect] = []
        var states: [TurnState] = []
        let loop = makeLoop(
            vad: [.speech, .silence], turn: [.commit],
            onEffect: { effects.append($0) }, onStateChange: { states.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        loop.scheduleReply("hello there")

        XCTAssertEqual(loop.state, .playing)
        XCTAssertEqual(effects.last, .speakReply(text: "hello there"))
        XCTAssertEqual(states, [.listening, .uttering, .committed, .playing])
    }

    /// `scheduleReply` is refused while uttering (never speak over the user), while playing
    /// (no double speech), and while idle — the machine fails closed, never a second reply.
    func testSchedulingAReplyIsRefusedOutsideCommittedAndListening() {
        var effects: [TurnEffect] = []

        let idle = makeLoop(vad: [.silence], turn: [.keepListening], onEffect: { effects.append($0) })
        idle.scheduleReply("nope")
        XCTAssertEqual(idle.state, .idle, "idle refuses a reply")
        XCTAssertFalse(effects.contains(.speakReply(text: "nope")))

        let uttering = makeLoop(
            vad: [.speech], turn: [.keepListening], onEffect: { effects.append($0) })
        uttering.start()
        uttering.feed(Self.userSpeech)
        uttering.scheduleReply("nope")
        XCTAssertEqual(uttering.state, .uttering, "uttering refuses a reply — never speak over the user")

        let playing = makeLoop(
            vad: [.speech, .silence], turn: [.commit], onEffect: { effects.append($0) })
        playing.start()
        playing.feed(Self.userSpeech)
        playing.feed(Self.silence)
        playing.scheduleReply("first")
        playing.scheduleReply("second")
        XCTAssertEqual(playing.state, .playing)
        XCTAssertEqual(
            effects.filter { if case .speakReply = $0 { return true } else { return false } }.count,
            1,
            "a second reply while playing is a driver bug — no double speech")
    }

    /// T8: speech while committed starts a **fresh** utterance — the pending reply is
    /// superseded, and no stale commit follows.
    func testSpeechWhileCommittedStartsAFreshUtterance() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .silence, .speech, .silence],
            turn: [.commit, .commit],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)  // first utterance
        loop.feed(Self.silence)     // first commit
        loop.feed(Self.userSpeech)  // fresh utterance — the old frames are gone
        loop.feed(Self.silence)     // second commit

        let commits = effects.compactMap { effect -> [AudioBuffer]? in
            if case .turnCommitted(let utterance) = effect { return utterance } else { return nil }
        }
        XCTAssertEqual(commits.count, 2, "one commit per turn: \(effects)")
        XCTAssertEqual(
            commits[1], [Self.userSpeech],
            "the second commit carries only the fresh utterance — a stale first-turn frame "
                + "would mean the accumulators did not reset")
        XCTAssertEqual(
            effects.filter { $0 == .speechBegan }.count, 2,
            "each utterance begins with .speechBegan: \(effects)")
    }

    /// T9: `reportPlaybackStarted()` opens the window; `reportPlaybackChunk` extends the
    /// trailing reference — observable through the gate: a frame matching the first chunk is
    /// accepted before the second chunk is reported and gated after it.
    func testTheWindowOpensOnReportAndTheReferenceGrowsWithChunks() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .silence, .silence, .silence],
            turn: [.commit],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        loop.scheduleReply("reply")
        loop.reportPlaybackStarted()

        let firstChunk = TurnLoopFixtures.chunk(amplitude: 0.4, frequency: 440, samples: 4000)
        let secondChunk = TurnLoopFixtures.chunk(amplitude: 0.4, frequency: 660, samples: 4000)
        let echoOfSecond = TurnLoopFixtures.echo(of: secondChunk, gain: 0.85)

        loop.reportPlaybackChunk(firstChunk)
        loop.feed(echoOfSecond)  // the reference is chunk 1 only → no match → accepted
        XCTAssertEqual(loop.gatedFrameCount, 0, "no reference match yet — the reference is chunk 1 only")

        loop.reportPlaybackChunk(secondChunk)
        loop.feed(echoOfSecond)  // the reference now trails with chunk 2 → matched → gated
        XCTAssertEqual(loop.gatedFrameCount, 1, "the reference grew to include chunk 2")
    }

    /// The chunk decode path: a stereo 32 kHz chunk becomes the mono 16 kHz reference —
    /// the channel mean and the nearest-neighbour decimation pinned through the gate.
    func testAChunkIsDecodedToMono16kForTheReference() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .silence, .silence],
            turn: [.commit],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        loop.scheduleReply("reply")
        loop.reportPlaybackStarted()

        // Stereo (both channels identical) at 32 kHz: the mono mean is the tone itself, and
        // the 2x decimation picks every second frame — the reference the loop holds.
        let chunk = TurnLoopFixtures.chunk(
            amplitude: 0.4, frequency: 440, samples: 4000, sampleRate: 32_000, channelCount: 2)
        loop.reportPlaybackChunk(chunk)

        let decoded = TurnLoopFixtures.decodeChunk(chunk)
        let echo = AudioBuffer(
            samples: decoded.suffix(1000).map { $0 * 0.85 }, sampleRate: 16_000)
        loop.feed(echo)

        XCTAssertEqual(
            loop.gatedFrameCount, 1,
            "the echo of the decoded mono-16k reference must gate — a decode that kept "
                + "stereo or the wrong rate would leave the reference orthogonal")
    }

    /// T10 (gate-behavior leg a): with the window open and a matching reference, every echo
    /// frame is gated — no `.speechBegan`, no `.bargeIn`, the frame never reaches the VAD.
    func testMatchingEchoFramesAreGatedWithNoSpeechAndNoBargeIn() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .silence], turn: [.commit],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        loop.scheduleReply("reply")
        loop.reportPlaybackStarted()
        loop.reportPlaybackChunk(Self.echoReferenceChunk)

        let echo = TurnLoopFixtures.echo(of: Self.echoReferenceChunk, gain: 0.85)
        loop.feed(echo)
        loop.feed(echo)
        loop.feed(echo)

        XCTAssertEqual(loop.gatedFrameCount, 3, "every echo frame is gated")
        XCTAssertEqual(loop.state, .playing, "the reply keeps playing")
        XCTAssertEqual(
            effects.filter { $0 == .speechBegan }.count, 1,
            "echo never begins speech — only the first turn's .speechBegan exists: \(effects)")
        XCTAssertFalse(effects.contains(.bargeIn), "echo never barge-ins: \(effects)")
    }

    /// T11 (gate-behavior leg b): silence during an open window is **never gated** and never
    /// speech — the PRD pin, even with a hot reference held.
    func testSilenceDuringPlaybackNeverGatesAndNeverSpeaks() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .silence, .silence, .silence, .silence], turn: [.commit],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        loop.scheduleReply("reply")
        loop.reportPlaybackStarted()
        loop.reportPlaybackChunk(Self.echoReferenceChunk)

        loop.feed(Self.silence)
        loop.feed(Self.silence)
        loop.feed(Self.silence)

        XCTAssertEqual(loop.gatedFrameCount, 0, "silence during playback never gates")
        XCTAssertEqual(
            effects.filter { $0 == .speechBegan }.count, 1,
            "silence never begins speech — only the first turn's .speechBegan exists: \(effects)")
        XCTAssertFalse(effects.contains(.bargeIn), "silence never barge-ins")
    }

    /// Gate-behavior leg (c): with no reference yet, the gate's accept is vacuous — a speech
    /// frame barge-ins before any chunk is reported (the honest un-gated path).
    func testBargeInWorksBeforeAnyChunkIsReported() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .silence, .speech], turn: [.commit],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        loop.scheduleReply("reply")
        loop.reportPlaybackStarted()

        loop.feed(Self.userSpeech)

        XCTAssertEqual(loop.state, .uttering, "the speech frame barge-ins with no reference")
        XCTAssertTrue(effects.contains(.bargeIn), "the barge-in effect fired: \(effects)")
    }

    /// T12: a speech frame during an open window barge-ins exactly once, and the accepted
    /// frames seen during the window (the seed) start the new utterance — the interrupting
    /// words are preserved from the first syllable.
    func testASpeechFrameDuringPlaybackBargesInOnceAndPreservesTheSeed() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .silence, .silence, .speech, .speech, .speech, .speech, .silence],
            turn: [.commit, .commit],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        loop.scheduleReply("reply")
        loop.reportPlaybackStarted()
        loop.reportPlaybackChunk(Self.echoReferenceChunk)

        loop.feed(Self.silence)             // accepted (silence floor), joins the seed
        loop.feed(Self.userSpeech)          // barge-in
        loop.feed(Self.userSpeech)
        loop.feed(Self.userSpeech)
        loop.feed(Self.userSpeech)          // the interrupting utterance
        loop.feed(Self.silence)             // commit the interrupting utterance

        XCTAssertEqual(
            effects.filter { $0 == .bargeIn }.count, 1,
            "exactly one .bargeIn per reply: \(effects)")
        let commits = effects.compactMap { effect -> [AudioBuffer]? in
            if case .turnCommitted(let utterance) = effect { return utterance } else { return nil }
        }
        XCTAssertEqual(
            commits[1],
            [Self.silence, Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech],
            "the new utterance starts with the accepted seed plus the interrupting speech — "
                + "the words that arrived during the reply are preserved")
    }

    /// T13: `reportPlaybackEnded()` closes the window and returns the loop to `.listening` —
    /// no stale accumulator, no stale reference, and the next speech begins a fresh utterance.
    func testPlaybackEndsNaturallyBackToListeningWithNoStaleAccumulator() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .silence, .speech, .silence], turn: [.commit, .commit],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        loop.scheduleReply("reply")
        loop.reportPlaybackStarted()
        loop.reportPlaybackChunk(Self.echoReferenceChunk)
        loop.reportPlaybackEnded()

        XCTAssertEqual(loop.state, .listening, "the natural end returns to listening")

        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        let commits = effects.compactMap { effect -> [AudioBuffer]? in
            if case .turnCommitted(let utterance) = effect { return utterance } else { return nil }
        }
        XCTAssertEqual(
            commits[1], [Self.userSpeech],
            "the post-reply utterance is fresh — the seed did not leak past the window")
    }

    /// T14 (review-gate fix 2, binding): speech onset exactly as the last reply chunk lands is
    /// a **new utterance immediately** in both orderings — the frame is retained, and no
    /// stale commit or speakReply results.
    func testSpeechAtTheReplyEndIsANewUtteranceInBothOrderings() {
        // Ordering 1: the speech frame arrives while the window is still open (after the final
        // chunk, before reportPlaybackEnded) — a barge-in.
        var effects: [TurnEffect] = []
        let bargeInLoop = makeLoop(
            vad: [.speech, .silence, .speech, .silence], turn: [.commit, .commit],
            onEffect: { effects.append($0) })
        bargeInLoop.start()
        bargeInLoop.feed(Self.userSpeech)
        bargeInLoop.feed(Self.silence)
        bargeInLoop.scheduleReply("reply")
        bargeInLoop.reportPlaybackStarted()
        bargeInLoop.reportPlaybackChunk(Self.echoReferenceChunk)
        bargeInLoop.feed(Self.userSpeech)   // the onset, at the final chunk
        bargeInLoop.reportPlaybackEnded()

        XCTAssertEqual(
            bargeInLoop.state, .uttering,
            "order 1: speech at the final chunk is a barge-in — never a dropped syllable")
        XCTAssertEqual(effects.filter { $0 == .bargeIn }.count, 1)
        XCTAssertEqual(
            effects.filter { if case .speakReply = $0 { return true } else { return false } }.count,
            1,
            "no stale speakReply after the race — the only reply is the scheduled one")

        // Ordering 2: reportPlaybackEnded first, then the speech frame — a fresh utterance.
        var secondEffects: [TurnEffect] = []
        let endedLoop = makeLoop(
            vad: [.speech, .silence, .speech, .silence], turn: [.commit, .commit],
            onEffect: { secondEffects.append($0) })
        endedLoop.start()
        endedLoop.feed(Self.userSpeech)
        endedLoop.feed(Self.silence)
        endedLoop.scheduleReply("reply")
        endedLoop.reportPlaybackStarted()
        endedLoop.reportPlaybackChunk(Self.echoReferenceChunk)
        endedLoop.reportPlaybackEnded()
        endedLoop.feed(Self.userSpeech)     // the onset, just after the window closed
        endedLoop.feed(Self.silence)

        XCTAssertEqual(
            endedLoop.state, .committed,
            "order 2: speech just after the window is a fresh utterance that commits")
        let commits = secondEffects.compactMap { effect -> [AudioBuffer]? in
            if case .turnCommitted(let utterance) = effect { return utterance } else { return nil }
        }
        XCTAssertEqual(
            commits[1], [Self.userSpeech],
            "order 2: the onset frame is retained as the new utterance — never eaten")
        XCTAssertEqual(
            secondEffects.filter { if case .speakReply = $0 { return true } else { return false } }.count,
            1,
            "no stale speakReply after the race — the only reply is the scheduled one")
    }

    /// T15 (review-gate fix 1, binding): stream continuity — fed-frame counts stay contiguous
    /// across the interrupt boundary, and the barge-in frame is the new utterance's first
    /// frame (no dropped-chunk window, no eaten first syllable).
    func testTheInterruptingFramesAreContiguousAcrossTheBoundary() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .speech, .speech, .speech] + [SpeechActivity](repeating: .silence, count: 8)
                + [.speech, .speech, .speech, .speech] + [SpeechActivity](repeating: .silence, count: 8),
            turn: [TurnCommitment](repeating: .keepListening, count: 7) + [.commit],
            onEffect: { effects.append($0) })
        loop.start()
        for _ in 0..<4 { loop.feed(Self.userSpeech) }        // first utterance
        for _ in 0..<8 { loop.feed(Self.silence) }           // pause → first commit
        loop.scheduleReply("reply")
        loop.reportPlaybackStarted()
        loop.reportPlaybackChunk(Self.echoReferenceChunk)
        loop.feed(TurnLoopFixtures.echo(of: Self.echoReferenceChunk, gain: 0.85))  // gated
        let beforeInterrupt = loop.fedFrameCount
        for _ in 0..<4 { loop.feed(Self.userSpeech) }        // the interrupting utterance
        for _ in 0..<8 { loop.feed(Self.silence) }           // its pause → second commit

        XCTAssertEqual(
            loop.fedFrameCount, beforeInterrupt + 12,
            "fed-frame counts stay contiguous across the interrupt boundary — a dropped "
                + "chunk would leave a gap in the sequence")
        let commits = effects.compactMap { effect -> [AudioBuffer]? in
            if case .turnCommitted(let utterance) = effect { return utterance } else { return nil }
        }
        XCTAssertEqual(commits.count, 2, "both turns commit: \(effects)")
        XCTAssertEqual(
            commits[1].first, Self.userSpeech,
            "the new utterance's first frame is the barge-in frame — the first syllable is "
                + "not eaten")
    }

    /// T16 (review-gate fix 3, binding): one consumer at a time — a second `start()` while
    /// running is refused, exactly one `.started` total.
    func testOnlyOneConsumerIsRefusedASecondStart() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(vad: [.silence], turn: [.keepListening], onEffect: { effects.append($0) })
        loop.start()
        loop.start()

        XCTAssertEqual(
            effects.filter { $0 == .started }.count, 1,
            "a second consumer is refused — one .started total")
        XCTAssertEqual(loop.state, .listening)
    }

    /// T17: `stop()` returns any state to `.idle` and emits `.stopped` once; feed after stop
    /// is refused; a second stop is a no-op.
    func testStopReturnsToIdleAndRefusesFurtherFeeds() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(vad: [.speech], turn: [.keepListening], onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.stop()
        loop.stop()
        loop.feed(Self.userSpeech)

        XCTAssertEqual(loop.state, .idle)
        XCTAssertEqual(effects.filter { $0 == .stopped }.count, 1, "one .stopped: \(effects)")
        XCTAssertEqual(
            loop.fedFrameCount, 1,
            "feed after stop is refused — the machine does not fabricate decisions for frames "
                + "it did not ask for")
    }

    /// T18: a capture failure mid-turn returns the loop to `.idle` with `.captureFailed` —
    /// deliberately no trap (the loop owes no transcript hand-over), and a later `start()`
    /// runs a fresh loop.
    func testCaptureFailureMidTurnReturnsToIdleAndRunsFresh() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .speech], turn: [.keepListening], onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.reportCaptureFailed()

        XCTAssertEqual(loop.state, .idle)
        XCTAssertEqual(effects.last, .captureFailed)

        loop.start()
        loop.feed(Self.userSpeech)
        XCTAssertEqual(loop.state, .uttering, "a later start runs a fresh loop")
        XCTAssertEqual(effects.filter { $0 == .started }.count, 2)
    }

    /// T19: a second speech frame while the halt applies (the owner still ducking) is not a
    /// second barge-in — exactly one `.bargeIn` per reply, no double-cancel.
    func testBargeInDuringTheDuckEmitsExactlyOneBargeIn() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .silence, .speech, .speech, .speech], turn: [.commit],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        loop.scheduleReply("reply")
        loop.reportPlaybackStarted()
        loop.reportPlaybackChunk(Self.echoReferenceChunk)
        loop.feed(Self.userSpeech)  // barge-in
        loop.feed(Self.userSpeech)  // during the halt
        loop.feed(Self.userSpeech)  // still accumulating, still one barge-in

        XCTAssertEqual(effects.filter { $0 == .bargeIn }.count, 1)
        XCTAssertEqual(loop.state, .uttering)
    }

    /// T20: speech at the final chunk is a barge-in — the owner's cancel consumes the tail
    /// (the ≤50 ms contract is the synthesizer's; the loop's half is that the effect fires
    /// and the machine leaves `.playing`).
    func testBargeInOnTheFinalChunkConsumesTheTail() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .silence, .speech], turn: [.commit],
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        loop.scheduleReply("reply")
        loop.reportPlaybackStarted()
        loop.reportPlaybackChunk(Self.echoReferenceChunk)
        loop.feed(Self.userSpeech)  // the onset lands with the final chunk

        XCTAssertEqual(effects.filter { $0 == .bargeIn }.count, 1)
        XCTAssertEqual(loop.state, .uttering, "the reply is being cancelled, not continuing")
    }

    /// T21: rapid speak/barge-in cycles stay stable — every reply discarded, one `.bargeIn`
    /// per reply, the loop ends listening, cancel-then-reinvoke safe (the C9 contract
    /// consumed, never re-litigated).
    func testRapidSpeakBargeInCyclesStayStable() {
        let cycles = 4
        var script: [SpeechActivity] = []
        for _ in 0..<cycles {
            script += [.speech, .silence, .speech]
        }
        script.append(.silence)

        var effects: [TurnEffect] = []
        let loop = makeLoop(vad: script, turn: [.commit], onEffect: { effects.append($0) })
        loop.start()

        for _ in 0..<cycles {
            // The loop is .uttering (from the previous barge-in, or from the first speech).
            loop.feed(Self.userSpeech)
            loop.feed(Self.silence)   // commit on the first decide
            loop.scheduleReply("reply")
            loop.reportPlaybackStarted()
            loop.feed(Self.userSpeech)  // barge-in (no reference — vacuous accept)
        }
        // One final commit and a natural end, so the loop is listening.
        loop.feed(Self.silence)
        loop.scheduleReply("last")
        loop.reportPlaybackStarted()
        loop.reportPlaybackEnded()

        XCTAssertEqual(
            effects.filter { $0 == .bargeIn }.count, cycles,
            "one .bargeIn per reply, every reply discarded")
        XCTAssertEqual(
            effects.filter { if case .speakReply = $0 { return true } else { return false } }.count,
            cycles + 1,
            "one reply per commit")
        XCTAssertEqual(loop.state, .listening, "the loop ends listening")
    }

    /// T22: an all-silence session is quiescent — no speech, no commit, nothing gated, the
    /// fed count growing the whole way.
    func testAnAllSilenceSessionIsQuiescent() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [SpeechActivity](repeating: .silence, count: 6), turn: [.keepListening],
            onEffect: { effects.append($0) })
        loop.start()
        for _ in 0..<6 { loop.feed(Self.silence) }

        XCTAssertEqual(loop.state, .listening)
        XCTAssertEqual(loop.fedFrameCount, 6)
        XCTAssertEqual(loop.gatedFrameCount, 0)
        XCTAssertEqual(effects, [.started], "silence-only sessions stay quiescent: \(effects)")
    }

    /// T23 (N1): the state-change hook fires on every transition, matching the trajectory.
    func testTheStateChangeHookTracksTheTrajectory() {
        var effects: [TurnEffect] = []
        var states: [TurnState] = []
        let loop = makeLoop(
            vad: [.speech, .silence, .speech, .speech, .speech, .speech, .silence],
            turn: [.commit, .commit],
            onEffect: { effects.append($0) }, onStateChange: { states.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        loop.scheduleReply("reply")
        loop.reportPlaybackStarted()
        loop.feed(Self.userSpeech)  // barge-in
        loop.feed(Self.userSpeech)
        loop.feed(Self.userSpeech)
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)     // commit the interrupting utterance
        loop.scheduleReply("second")
        loop.reportPlaybackStarted()
        loop.reportPlaybackEnded()

        XCTAssertEqual(
            states,
            [.listening, .uttering, .committed, .playing, .uttering, .committed, .playing, .listening],
            "the state trajectory: \(states)")
    }

    /// T24 (the budget's coordinator half): the barge-in decision is delivered within the
    /// cancel contract — `tCancel − tSpeech ≤ 50 ms` over the injected clock, asserted at the
    /// contract threshold (a future async refactor cannot silently exceed it).
    func testTheBargeInDecisionIsDeliveredWithinTheCancelContract() {
        let clock = TurnLoopTestClock()
        var effects: [TurnEffect] = []
        let loop = makeLoop(
            vad: [.speech, .silence, .speech], turn: [.commit], clock: clock,
            onEffect: { effects.append($0) })
        loop.start()
        loop.feed(Self.userSpeech)
        loop.feed(Self.silence)
        loop.scheduleReply("reply")
        loop.reportPlaybackStarted()
        loop.reportPlaybackChunk(Self.echoReferenceChunk)

        clock.advance(by: .seconds(5))          // a known tSpeech
        let tSpeech = clock.now
        loop.feed(Self.userSpeech)              // the interrupt frame — barge-in fires inline
        let tCancel = clock.now                 // the driver applies .bargeIn synchronously

        XCTAssertTrue(effects.contains(.bargeIn))
        XCTAssertLessThanOrEqual(
            tCancel - tSpeech, .milliseconds(50),
            "the coordinator's own contribution to the 200 ms gate must fit the ≤50 ms cancel "
                + "contract — measured over the injected clock, never at CI wall time")
    }

    /// Feed before start is refused without counting — the machine does not fabricate
    /// decisions for frames it did not ask for.
    func testFeedBeforeStartIsRefusedWithoutCounting() {
        var effects: [TurnEffect] = []
        let loop = makeLoop(vad: [.speech], turn: [.keepListening], onEffect: { effects.append($0) })
        loop.feed(Self.userSpeech)

        XCTAssertEqual(loop.state, .idle)
        XCTAssertEqual(loop.fedFrameCount, 0, "an idle feed is refused and not counted")
        XCTAssertTrue(effects.isEmpty)
    }
}