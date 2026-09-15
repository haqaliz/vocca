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
import Synchronization
import VoccaCore
import XCTest

@testable import VoccaAudio

/// **The playback contract: the `PlaybackEngine` seam and the duck/halt state machine over the
/// injected clock and the fake output.**
///
/// `playback-ducking` of `turn-taking-barge-in` (C10 — the P3 voice loop), the plan
/// `docs/planning/turn-taking-barge-in/playback-ducking/plan_20260915.md`. The seam is new in
/// `VoccaCore` — four operations, no handle type: `play` (returns **after drain**, not after
/// enqueue — the reply's tail must not still be sounding when the loop goes back to listening),
/// `duck` (the N2 level knob, idempotent), `cancelToSilence` (halts to silence **at the ramp
/// end**, never a cut and never a hang), and `tearDown` (synchronous release; a later `play`
/// reopens). The duck/halt timing is a pure function of the injected ``MonotonicClock`` — that
/// is the whole headless proof, because the realtime device path (`SystemPlaybackOutput`'s
/// `AVAudioEngine`/`AVAudioSourceNode` render block) is executed by nothing in CI, exactly the
/// `AudioCaptureGraph`/tap-adapter precedent.
///
/// Everything here is driven over the two doubles that live in this file:
///
/// - ``FakePlaybackOutput`` — the `PlaybackOutputSeam` as a **ledger** (the `MicrophoneSource`
///   recipe): assertions are made against what it recorded — start format, enqueue order, gain
///   targets with clock stamps, stop count — never against a call believed to have happened.
///   `isDrained` is the renderer's consumption: the fake holds the enqueued frames until the
///   test consumes them, so "play returns only after the fake reports drained" is a state the
///   test drives, not a scheduling accident.
/// - ``PlaybackTestClock`` — a `Mutex`-guarded hand-moved clock, because the halt's bounded poll
///   observes `now` from the cancel task while the test advances it (the shared `TestClock` in
///   `SessionTestDoubles.swift` is not thread-safe and is deliberately not reused).
///
/// The suite pins, by name: the seam shape (a renamed or weakened member stops compiling), the
/// duck knob's numbers (`0.5` ≈ −6 dB, a 20 ms ramp — and the 20 ms ramp fits the recorded
/// barge-in decomposition `30 + 50 + 20 + margin ≤ 200`), the pure ``LevelRamp`` schedule, the
/// arithmetic-mean downmix (with the silent-channel-0 killer), the drain-return, the empty
/// stream, the idempotent duck, the halt at exactly `rampDuration` and not before, the
/// frozen-clock liveness bound, the no-op out-of-order calls, cancel-then-replay, the rapid
/// duck/halt/play hammer, the stream error and the format-change halt, teardown/reopen, and the
/// refused-start propagation.
final class PlaybackEngineSeamTests: XCTestCase {

    // MARK: - The seam shape

    /// **The seam, pinned as the `SpeechSynthesizerSeamTests` compile pin** (`requireEngine`
    /// existential + an annotated binding): four operations, no handle type, `play` taking an
    /// `AsyncThrowingStream<AudioChunk, Error>`, `tearDown` synchronous. Renaming or weakening
    /// any member stops compiling — the pin the `barge-in-loop` aspect compiles against.
    func testThePlaybackEngineSeamShapeIsPinned() {
        func requireEngine(_ engine: any PlaybackEngine) -> any PlaybackEngine { engine }

        let clock = PlaybackTestClock()
        let fake = FakePlaybackOutput(clock: clock)
        let engine = requireEngine(SystemPlayback(level: .default, clock: clock, output: fake))

        // The annotated binding: each operation pinned to its exact signature. Never invoked —
        // the pin is that this compiles as written.
        let play: (AsyncThrowingStream<AudioChunk, Error>) async throws -> Void = {
            try await engine.play($0)
        }
        let duck: () async -> Void = { await engine.duck() }
        let cancelToSilence: () async -> Void = { await engine.cancelToSilence() }
        let tearDown: () -> Void = { engine.tearDown() }
        _ = (play, duck, cancelToSilence, tearDown)
    }

    // MARK: - The N2 knob as plain data

    /// The defaults ARE the duck knob: `duckGain == 0.5` and `20·log10(0.5)` inside `[−7, −5]`
    /// dB — the PRD's "−6 dB-ish" pinned as a number, not a word — and a 20 ms ramp.
    func testPlaybackLevelDefaultsAreTheDuckKnob() {
        let level = PlaybackLevel.default

        XCTAssertEqual(level.duckGain, 0.5, "the duck target is the N2 −6 dB-ish level")
        XCTAssertEqual(level.rampDuration, .milliseconds(20), "the duck ramp is 20 ms")

        let decibels = 20 * log10(level.duckGain)
        XCTAssertGreaterThanOrEqual(decibels, -7)
        XCTAssertLessThanOrEqual(decibels, -5)
        XCTAssertEqual(decibels, -6.020599913279624, accuracy: 1e-9)
    }

    /// A level that cannot describe a gain is refused — the `isValidCaptureFormat` near-miss
    /// discipline: NaN, ±∞, negative, above 1, a zero ramp, a negative ramp. The default is
    /// valid.
    func testAPlaybackLevelThatCannotDescribeGainIsRefused() {
        XCTAssertTrue(PlaybackLevel.default.isValid, "the shipped default must be valid")

        let invalid: [(duckGain: Double, rampDuration: Duration)] = [
            (Double.nan, .milliseconds(20)),
            (Double.infinity, .milliseconds(20)),
            (-Double.infinity, .milliseconds(20)),
            (-0.01, .milliseconds(20)),
            (1.01, .milliseconds(20)),
            (0.5, .zero),
            (0.5, .milliseconds(-1)),
        ]
        for (gain, ramp) in invalid {
            XCTAssertFalse(
                PlaybackLevel(duckGain: gain, rampDuration: ramp).isValid,
                "a level with duckGain \(gain) and ramp \(ramp) must be refused")
        }

        let boundaries: [(duckGain: Double, rampDuration: Duration)] = [
            (0.0, .milliseconds(20)),
            (1.0, .milliseconds(1)),
        ]
        for (gain, ramp) in boundaries {
            XCTAssertTrue(
                PlaybackLevel(duckGain: gain, rampDuration: ramp).isValid,
                "the boundary values \(gain)/\(ramp) describe a real duck and must be accepted")
        }
    }

    /// The default ramp fits the recorded barge-in decomposition (`ARCHITECTURE.md:571`):
    /// VAD frame ~30 ms + `synthesizer.cancel()` ≤50 ms + the duck ramp + a stated margin
    /// ≥50 ms ≤ 200 ms. Pinned as arithmetic so an edit to the default cannot silently eat the
    /// composed gate — this aspect's term is `rampDuration` alone; the composed gate is
    /// `barge-in-loop`'s acceptance, and this test pins that the default does not consume it.
    func testTheDefaultRampFitsTheRecordedBargeInDecomposition() {
        let vadFrame = Duration.milliseconds(30)
        let synthesizerCancel = Duration.milliseconds(50)
        let margin = Duration.milliseconds(50)

        XCTAssertGreaterThanOrEqual(margin, .milliseconds(50), "the stated margin is ≥ 50 ms")
        XCTAssertLessThanOrEqual(
            PlaybackLevel.default.rampDuration, synthesizerCancel,
            "the duck ramp must not exceed the ≤50 ms cancel contract it rides on")

        let decomposition = vadFrame + synthesizerCancel + PlaybackLevel.default.rampDuration + margin
        XCTAssertLessThanOrEqual(
            decomposition, .milliseconds(200),
            "30 + 50 + rampDuration + margin must fit the composed 200 ms barge-in gate, got \(decomposition)")
    }

    // MARK: - The pure ramp schedule

    /// **The ramp schedule is a pure function of the clock.** Exact values at t0 / mid / end /
    /// beyond; clamped so it never overshoots; `isComplete` flips exactly at the end; a
    /// zero-duration ramp is complete at t0 and returns `toGain` (no divide-by-zero); a negative
    /// elapsed is not complete and returns `fromGain`; monotone non-increasing throughout.
    ///
    /// Kills: an envelope that is a step, one that overshoots or oscillates, and one that treats
    /// a negative elapsed as complete.
    func testTheRampScheduleIsAPureFunctionOfTheClock() {
        let t0 = Duration.seconds(100)
        var ramp = LevelRamp(fromGain: 1, toGain: 0.5, duration: .milliseconds(20), startedAt: t0)

        XCTAssertEqual(ramp.gain(at: t0), 1, "the ramp starts at fromGain")
        XCTAssertEqual(
            ramp.gain(at: t0 + .milliseconds(10)), 0.75,
            "halfway through a 1→0.5 ramp the gain is the arithmetic midpoint")
        XCTAssertEqual(ramp.gain(at: t0 + .milliseconds(20)), 0.5, "the ramp ends at toGain")
        XCTAssertEqual(
            ramp.gain(at: t0 + .seconds(1)), 0.5,
            "a finished ramp stays at toGain — clamped, never overshooting")
        XCTAssertEqual(
            ramp.gain(at: t0 - .milliseconds(10)), 1,
            "a negative elapsed is before the ramp — fromGain, not toGain")

        XCTAssertFalse(ramp.isComplete(at: t0), "the ramp is not complete before it starts")
        XCTAssertFalse(
            ramp.isComplete(at: t0 + .milliseconds(19)),
            "the ramp is not complete a frame before its end")
        XCTAssertTrue(
            ramp.isComplete(at: t0 + .milliseconds(20)),
            "the ramp is complete exactly at its end")
        XCTAssertFalse(
            ramp.isComplete(at: t0 - .milliseconds(1)),
            "a negative elapsed must not be treated as complete")

        // Monotone non-increasing over the whole schedule.
        var last = ramp.gain(at: t0)
        for step in 1...40 {
            let gain = ramp.gain(at: t0 + .milliseconds(Int64(step) / 2))
            XCTAssertLessThanOrEqual(gain, last, "the ramp must never rise")
            last = gain
        }

        // A zero-duration ramp is complete at t0 and returns toGain — no divide-by-zero.
        let instant = LevelRamp(fromGain: 1, toGain: 0.5, duration: .zero, startedAt: t0)
        XCTAssertTrue(instant.isComplete(at: t0), "a zero-duration ramp is complete at its start")
        XCTAssertEqual(instant.gain(at: t0), 0.5, "a zero-duration ramp is at toGain at t0")
        XCTAssertEqual(
            instant.gain(at: t0 + .seconds(5)), 0.5,
            "a zero-duration ramp stays at toGain")
    }

    // MARK: - The downmix

    /// **Chunk bytes are Float32 interleaved, and the mono frames are the arithmetic mean of the
    /// channels** — the `AudioFormatConverterTests` downmix discipline, including the exact
    /// killers: first-channel selection and the silent-channel-0 microphone. Plus a Float32
    /// round-trip pin: bytes → frames → the same values.
    func testMonoFramesAreTheArithmeticMeanOfTheChunkChannels() {
        let stereo = Self.chunk(frames: [1, 3, 5, 7], sampleRate: 22_050, channelCount: 2)
        XCTAssertEqual(
            SystemPlayback.monoFrames(from: stereo), [2, 6],
            "stereo frames (1,3) and (5,7) must average to 2 and 6 — [1,5] is first-channel selection")

        let quad = Self.chunk(frames: [1, 2, 3, 4], sampleRate: 22_050, channelCount: 4)
        XCTAssertEqual(
            SystemPlayback.monoFrames(from: quad), [2.5],
            "a four-channel frame must divide by four, not by a hardcoded two")

        let offsetMicrophone = Self.chunk(frames: [0, 1, 0, -1], sampleRate: 22_050, channelCount: 2)
        XCTAssertEqual(
            SystemPlayback.monoFrames(from: offsetMicrophone), [0.5, -0.5],
            """
            A microphone on channel 2 was lost. First-channel selection returns [0, 0] here and \
            reports success — silence shipped as a working playback.
            """)
        XCTAssertNotEqual(
            SystemPlayback.monoFrames(from: offsetMicrophone), [0, 0],
            "the downmix discarded every channel but the first")

        let roundTrip = Self.chunk(frames: [0.1, -0.25, 0.5], sampleRate: 22_050, channelCount: 1)
        XCTAssertEqual(
            SystemPlayback.monoFrames(from: roundTrip), [0.1, -0.25, 0.5],
            "a Float32 round-trip must recover the exact values — bytes → frames → same bits")
    }

    // MARK: - The session contract

    /// `play` starts the output once with the first chunk's rate/channels, enqueues the chunks
    /// in stream order with their exact frames, returns **only after the fake reports drained**
    /// — never before — and stops the output once after the drain.
    func testPlayDeliversChunksInOrderAndReturnsWhenDrained() async throws {
        let (engine, fake, clock) = Self.makeEngine()
        let script = [
            Self.chunk(frames: [0.1, 0.2, 0.3]),
            Self.chunk(frames: [0.4, 0.5]),
            Self.chunk(frames: [0.6]),
        ]
        let t0 = clock.now

        let playTask = Self.playTask(engine, Self.stream(script))
        try await Self.waitUntil { fake.enqueuedFrames.count == 3 }

        XCTAssertEqual(
            fake.startCalls, [FakePlaybackOutput.StartCall(sampleRate: 22_050, channelCount: 1)],
            "start() is called exactly once, with the first chunk's format")
        XCTAssertEqual(
            fake.enqueuedFrames, [[0.1, 0.2, 0.3], [0.4, 0.5], [0.6]],
            "the chunks arrive in stream order, undropped and unduplicated")
        XCTAssertTrue(fake.isRunning, "the session is active while it drains")
        XCTAssertEqual(
            fake.gainEvents.count, 0,
            "a session that neither ducks nor halts never touches the level")
        XCTAssertEqual(
            fake.stopEvents.count, 0,
            "play has not returned — the output is still draining and no stop has been recorded")
        XCTAssertEqual(clock.now, t0, "no clock advance happened — the drain was not clocked")

        fake.consumeAll()
        try await playTask.value

        XCTAssertEqual(
            fake.stopEvents.count, 1,
            "the drain ends the session with exactly one stop")
        XCTAssertEqual(
            fake.stopEvents.first?.at, t0,
            "the stop lands at the drained moment — the ledger stamps it with the clock")
        XCTAssertFalse(fake.isRunning, "a drained session is no longer running")
    }

    /// `play` of an empty stream returns, never throws, and never starts the output — the
    /// `speak("")` twin: nothing to play is an answer, not an error.
    func testAnEmptyStreamNeverStartsTheOutput() async throws {
        let (engine, fake, _) = Self.makeEngine()

        try await engine.play(Self.stream([]))

        XCTAssertEqual(fake.startCalls.count, 0, "an empty stream never starts the output")
        XCTAssertEqual(fake.enqueuedFrames.count, 0, "an empty stream enqueues nothing")
        XCTAssertEqual(fake.stopEvents.count, 0, "an empty stream never stops the output")
        XCTAssertFalse(fake.isRunning, "an empty stream leaves the output idle")
    }

    /// `duck()` mid-play ramps the level to the duck target and **keeps playing**: the target
    /// recorded on the output is the pure schedule's endpoint (`1 → 0.5`), no stop, the session
    /// still active — and the session still drains normally afterwards.
    func testDuckRampsTheLevelToTheDuckTargetAndKeepsPlaying() async throws {
        let (engine, fake, clock) = Self.makeEngine()
        let playTask = Self.playTask(engine, Self.stream(Self.threeChunks()))
        try await Self.waitUntil { fake.enqueuedFrames.count >= 1 }
        let t0 = clock.now

        await engine.duck()

        XCTAssertEqual(
            fake.gainEvents, [FakePlaybackOutput.GainEvent(gain: 0.5, at: t0)],
            "the duck tells the output exactly one target: the 0.5 endpoint of the 1→0.5 schedule")
        XCTAssertEqual(
            fake.gainEvents.first?.gain, Float(PlaybackLevel.default.duckGain),
            "the recorded target IS the N2 duck knob")
        XCTAssertEqual(fake.stopEvents.count, 0, "a duck is not a stop")
        XCTAssertTrue(fake.isRunning, "playback continues under the duck")

        fake.consumeAll()
        try await playTask.value
        XCTAssertEqual(fake.stopEvents.count, 1, "the ducked session still drains and stops once")
    }

    /// `duck(); duck()` is exactly one target transition: the second duck is a no-op, and
    /// advancing the clock between the two calls does not move the ramp's start — no
    /// discontinuity.
    func testDuckIsIdempotentAndDoesNotRestartTheRamp() async throws {
        let (engine, fake, clock) = Self.makeEngine()
        let playTask = Self.playTask(engine, Self.stream(Self.threeChunks()))
        try await Self.waitUntil { fake.enqueuedFrames.count >= 1 }
        let t0 = clock.now

        await engine.duck()
        clock.advance(by: .milliseconds(5))
        await engine.duck()

        XCTAssertEqual(
            fake.gainEvents.count, 1,
            "a second duck while already ducking must not start a new ramp")
        XCTAssertEqual(fake.gainEvents.first?.gain, 0.5)
        XCTAssertEqual(
            fake.gainEvents.first?.at, t0,
            "the ramp's start is the first duck's clock stamp — the second duck did not move it")

        fake.consumeAll()
        try await playTask.value
    }

    /// **The core timing pin: the halt is a duck, not a click.** `cancelToSilence()` parks the
    /// ramp (`setGain(0)` at the cancel's clock stamp), then **no stop yet** while the clock is
    /// still at t0; when the clock reaches `t0 + rampDuration` the stop lands, stamped exactly
    /// there, exactly once — and `play` returned after it.
    func testCancelToSilenceHaltsAtTheRampEndAndNotBefore() async throws {
        let (engine, fake, clock) = Self.makeEngine()
        let playTask = Self.playTask(engine, Self.stream(Self.threeChunks()))
        try await Self.waitUntil { fake.enqueuedFrames.count >= 1 }
        let t0 = clock.now

        let cancelTask = Task { await engine.cancelToSilence() }
        try await Self.waitUntil { fake.gainEvents.contains { $0.gain == 0 } }

        XCTAssertEqual(
            fake.gainEvents.last?.at, t0,
            "the ramp parks at the cancel's clock stamp")
        XCTAssertEqual(
            fake.stopEvents.count, 0,
            """
            with the clock still at t0 the halt must not have stopped — a cancel that cuts the \
            engine immediately is a click, and the ramp is the whole point of cancelToSilence
            """)
        XCTAssertTrue(fake.isRunning, "the session is still active during the ramp")

        clock.advance(by: .milliseconds(20))
        await cancelTask.value

        XCTAssertEqual(
            fake.stopEvents, [FakePlaybackOutput.StopEvent(at: t0 + .milliseconds(20))],
            "the stop lands exactly at the ramp end, exactly once, stamped by the clock")
        try await playTask.value
        XCTAssertEqual(
            fake.stopEvents.count, 1,
            "play returned after the halt's stop — a single stop across the whole halt")
        XCTAssertFalse(fake.isRunning)
    }

    /// A frozen clock must not hang the barge-in: `cancelToSilence` returns within the bounded
    /// poll ceiling and the stop is recorded — the `SessionWatchdogTests` discipline.
    func testAClockThatNeverAdvancesStillHalts() async throws {
        let (engine, fake, _) = Self.makeEngine()
        let playTask = Self.playTask(engine, Self.stream(Self.threeChunks()))
        try await Self.waitUntil { fake.enqueuedFrames.count >= 1 }

        let cancelTask = Task { await engine.cancelToSilence() }
        await cancelTask.value

        XCTAssertEqual(
            fake.stopEvents.count, 1,
            "the bounded poll must halt even with a clock that never advances")
        try await playTask.value
    }

    /// `cancelToSilence()` without a playback session is a no-op: no gain event, no stop, prompt
    /// return — the idempotent halt.
    func testCancelToSilenceWithoutAPlaybackSessionIsANoOp() async throws {
        let (engine, fake, _) = Self.makeEngine()

        await engine.cancelToSilence()

        XCTAssertEqual(fake.gainEvents.count, 0, "an idle halt never touches the level")
        XCTAssertEqual(fake.stopEvents.count, 0, "an idle halt never stops the output")
        XCTAssertFalse(fake.isRunning)
    }

    /// `duck()` before any play is a no-op **and leaves the next session clean**: no gain event
    /// is recorded on idle, and the following session starts at gain 1.0 — no cross-session
    /// state leak (the `AudioFormatConverter` contamination discipline).
    func testDuckBeforePlayIsANoOpAndLeavesTheNextSessionClean() async throws {
        let (engine, fake, _) = Self.makeEngine()

        await engine.duck()
        XCTAssertEqual(
            fake.gainEvents.count, 0,
            "a duck on an idle engine must record nothing — it never pre-arms the next session")

        let playTask = Self.playTask(engine, Self.stream(Self.threeChunks()))
        try await Self.waitUntil { fake.enqueuedFrames.count >= 1 }
        XCTAssertEqual(
            fake.gainEvents.count, 0,
            "the session started at gain 1.0 — the idle duck left nothing in the level state")

        fake.consumeAll()
        try await playTask.value
        XCTAssertEqual(fake.stopEvents.count, 1, "the clean session drains and stops once")
    }

    /// Cancel-then-replay is safe: the first session halts with exactly one stop, and the second
    /// `play` renders fully — the cancelled session's tail is never resumed.
    func testCancelThenReplayRendersFully() async throws {
        let (engine, fake, clock) = Self.makeEngine()
        let scriptA = [
            Self.chunk(frames: [0.1, 0.2]),
            Self.chunk(frames: [0.3]),
            Self.chunk(frames: [0.4]),
        ]
        let playTaskA = Self.playTask(engine, Self.stream(scriptA))
        try await Self.waitUntil { fake.enqueuedFrames.count >= 1 }

        let cancelTask = Task { await engine.cancelToSilence() }
        clock.advance(by: .milliseconds(20))
        await cancelTask.value
        try await playTaskA.value

        XCTAssertEqual(
            fake.stopEvents.count, 1,
            "the cancelled session halts with exactly one stop")
        let cancelledCount = fake.enqueuedFrames.count
        XCTAssertLessThanOrEqual(
            cancelledCount, 3,
            "the cancelled session enqueued at most its script — check-and-enqueue stops it at the cancel")

        let scriptB = [
            Self.chunk(frames: [0.7, 0.8]),
            Self.chunk(frames: [0.9]),
            Self.chunk(frames: [1.0]),
        ]
        let playTaskB = Self.playTask(engine, Self.stream(scriptB))
        try await Self.waitUntil { fake.enqueuedFrames.count == cancelledCount + 3 }

        XCTAssertEqual(
            Array(fake.enqueuedFrames.suffix(3)), [[0.7, 0.8], [0.9], [1.0]],
            """
            the second session renders ITS script verbatim — the cancelled session's tail is \
            never resumed (the generation mechanism, not a flag that a fresh play forgot to clear)
            """)
        fake.consumeAll()
        try await playTaskB.value
        XCTAssertEqual(
            fake.stopEvents.count, 2,
            "the replayed session drains and stops once — one stop per session, never more")
    }

    /// The barge-in hammer — rapid duck/cancel/play cycles over an advancing clock: the task
    /// graph completes within a bounded wall time (no deadlock — the re-entrancy pin), every
    /// halt records exactly one stop, and the final session plays fully.
    func testARapidDuckHaltPlayHammerLeavesAStableEngine() async throws {
        let (engine, fake, clock) = Self.makeEngine()
        let roundScripts = [
            [Self.chunk(frames: [0.1, 0.2]), Self.chunk(frames: [0.3])],
            [Self.chunk(frames: [0.4, 0.5]), Self.chunk(frames: [0.6])],
            [Self.chunk(frames: [0.7, 0.8]), Self.chunk(frames: [0.9])],
        ]
        var playTasks: [Task<Void, Error>] = []
        var base = 0

        for script in roundScripts {
            let playTask = Self.playTask(engine, Self.stream(script))
            playTasks.append(playTask)
            try await Self.waitUntil { fake.enqueuedFrames.count >= base + 1 }
            await engine.duck()
            let cancelTask = Task { await engine.cancelToSilence() }
            clock.advance(by: .milliseconds(20))
            await cancelTask.value
            base = fake.enqueuedFrames.count
        }
        for playTask in playTasks {
            try await playTask.value
        }
        XCTAssertEqual(
            fake.stopEvents.count, 3,
            "one stop per halt, across the three hammer rounds")

        let finalScript = [
            Self.chunk(frames: [0.11]),
            Self.chunk(frames: [0.22]),
            Self.chunk(frames: [0.33]),
        ]
        let finalTask = Self.playTask(engine, Self.stream(finalScript))
        try await Self.waitUntil { fake.enqueuedFrames.count == base + 3 }
        XCTAssertEqual(
            Array(fake.enqueuedFrames.suffix(3)), [[0.11], [0.22], [0.33]],
            "the final session plays fully — the hammer left a stable engine")
        fake.consumeAll()
        try await finalTask.value
        XCTAssertEqual(
            fake.stopEvents.count, 4,
            "the final drained session adds exactly one more stop")
    }

    /// A stream that throws mid-play: `play` throws the same error, and the halt path ran —
    /// `setGain(0)` at the failure's clock stamp, then `stop` exactly at the ramp end.
    func testAStreamErrorMidPlayHaltsAndThrows() async throws {
        let (engine, fake, clock) = Self.makeEngine()
        let throwingStream = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(Self.chunk(frames: [0.1]))
            continuation.yield(Self.chunk(frames: [0.2]))
            continuation.finish(throwing: StreamFailure())
        }
        let playTask = Self.playTask(engine, throwingStream)

        try await Self.waitUntil { fake.gainEvents.contains { $0.gain == 0 } }
        let haltStart = fake.gainEvents.last?.at
        XCTAssertEqual(fake.stopEvents.count, 0, "the halt is a ramp — no stop before the ramp end")
        clock.advance(by: .milliseconds(20))
        do {
            try await playTask.value
            XCTFail("play must rethrow the stream's error")
        } catch let error as StreamFailure {
            XCTAssertEqual(error, StreamFailure(), "play rethrows the SAME error, unwrapped")
        }
        XCTAssertEqual(
            fake.stopEvents, [FakePlaybackOutput.StopEvent(at: (haltStart ?? .zero) + .milliseconds(20))],
            "the halt path ran: setGain(0) then stop after the ramp")
        XCTAssertEqual(
            fake.enqueuedFrames.count, 2,
            "the two chunks that yielded before the throw were enqueued, nothing after")
    }

    /// A chunk whose format differs from the session's first is a stream failure, not a silent
    /// conversion (the producers ship uniform-format streams; a differing chunk is corruption).
    /// `play` throws, and the halt path ran.
    func testAChunkInADifferentFormatIsAStreamFailure() async throws {
        let (engine, fake, clock) = Self.makeEngine()
        let changingStream = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(Self.chunk(frames: [0.1], sampleRate: 22_050, channelCount: 1))
            continuation.yield(Self.chunk(frames: [0.2], sampleRate: 44_100, channelCount: 1))
            continuation.finish()
        }
        let playTask = Self.playTask(engine, changingStream)

        try await Self.waitUntil { fake.gainEvents.contains { $0.gain == 0 } }
        let haltStart = fake.gainEvents.last?.at
        clock.advance(by: .milliseconds(20))
        do {
            try await playTask.value
            XCTFail("play must throw when the stream changes format mid-play")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .chunkFormatChanged)
        }
        XCTAssertEqual(
            fake.stopEvents, [FakePlaybackOutput.StopEvent(at: (haltStart ?? .zero) + .milliseconds(20))],
            "the format-change failure runs the halt path too")
        XCTAssertEqual(
            fake.enqueuedFrames.count, 1,
            "only the first, in-format chunk was enqueued")
    }

    /// `tearDown()` releases the output synchronously and is idempotent; a later `play` starts a
    /// fresh session — the `CaptureGraphSeam.stop()` release contract.
    func testTearDownReleasesTheOutputAndPlayReopens() async throws {
        let (engine, fake, _) = Self.makeEngine()
        let streamA = Self.stream(Self.threeChunks())
        let playTaskA = Self.playTask(engine, streamA)
        try await Self.waitUntil { fake.enqueuedFrames.count >= 1 }

        engine.tearDown()
        XCTAssertEqual(fake.stopEvents.count, 1, "tearDown releases the output exactly once")
        XCTAssertFalse(fake.isRunning, "the output is released")

        engine.tearDown()
        XCTAssertEqual(fake.stopEvents.count, 1, "a second tearDown is a no-op")

        try await playTaskA.value
        XCTAssertEqual(fake.stopEvents.count, 1, "the torn-down session adds no stop of its own")

        let streamB = Self.stream(Self.threeChunks())
        let playTaskB = Self.playTask(engine, streamB)
        try await Self.waitUntil { fake.enqueuedFrames.count == 3 + 3 }
        fake.consumeAll()
        try await playTaskB.value
        XCTAssertEqual(
            fake.stopEvents.count, 2,
            "a later play reopens the output and stops once after its own drain")
    }

    /// An output that refuses to start: `play` throws the output's error and nothing has
    /// started — no gain event, no stop, no enqueue (nothing to halt, so no halt is owed).
    func testAPlaybackOutputThatRefusesToStartThrowsAndStartsNothing() async throws {
        let (engine, fake, _) = Self.makeEngine()
        fake.nextStart = .failure(StartRefused())

        let stream = Self.stream(Self.threeChunks())
        let playTask = Self.playTask(engine, stream)
        do {
            try await playTask.value
            XCTFail("play must throw when the output refuses to start")
        } catch is StartRefused {
            // The output's own error, propagated unwrapped.
        }
        XCTAssertEqual(fake.startCalls.count, 1, "the output was asked exactly once")
        XCTAssertEqual(fake.enqueuedFrames.count, 0, "a refused start enqueues nothing")
        XCTAssertEqual(fake.gainEvents.count, 0, "a refused start runs no halt — nothing started")
        XCTAssertEqual(fake.stopEvents.count, 0, "a refused start never stops the output")
        XCTAssertFalse(fake.isRunning)
    }

    // MARK: - Helpers and doubles

    /// An engine over a ledger fake and a hand-moved clock.
    private static func makeEngine() -> (SystemPlayback, FakePlaybackOutput, PlaybackTestClock) {
        let clock = PlaybackTestClock()
        let fake = FakePlaybackOutput(clock: clock)
        let engine = SystemPlayback(level: .default, clock: clock, output: fake)
        return (engine, fake, clock)
    }

    /// The play task, routed through one helper: the `Task` closure lives here exactly once, so
    /// the region-based isolation checker's analysis budget is not spread across the suite's
    /// many task sites (a compiler quirk — the same pattern inlines fine in small files).
    private static func playTask(
        _ engine: SystemPlayback, _ stream: AsyncThrowingStream<AudioChunk, Error>
    ) -> Task<Void, Error> {
        Task { try await engine.play(stream) }
    }

    /// A scripted stream that yields the chunks in order and finishes.
    private static func stream(_ chunks: [AudioChunk]) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    private static func threeChunks() -> [AudioChunk] {
        [
            Self.chunk(frames: [0.1, 0.2]),
            Self.chunk(frames: [0.3, 0.4]),
            Self.chunk(frames: [0.5, 0.6]),
        ]
    }

    /// A chunk whose bytes are the native-endian Float32 encoding of `frames`, interleaved at
    /// `channelCount` channels — the shape the shipped producers emit.
    private static func chunk(
        frames: [Float], sampleRate: Double = 22_050, channelCount: Int = 1
    ) -> AudioChunk {
        var bytes = [UInt8]()
        bytes.reserveCapacity(frames.count * MemoryLayout<Float>.size)
        for value in frames {
            var bits = value.bitPattern
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        return AudioChunk(
            bytes: bytes,
            sampleRate: sampleRate,
            channelCount: channelCount,
            duration: Double(frames.count / channelCount) / sampleRate)
    }

    /// Polls `condition` on a 1 ms tick until it holds or the bound expires — the bounded-wait
    /// shape the tests use to observe ledger writes from other tasks.
    private static func waitUntil(
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("timed out waiting for the ledger condition", file: file, line: line)
                throw WaitTimeout()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private struct WaitTimeout: Error {}
    private struct StreamFailure: Error, Equatable {}
    private struct StartRefused: Error {}

    /// **The clock the state machine's halt observes.** `Mutex`-guarded and `@unchecked
    /// Sendable` on purpose: the cancel task reads `now` in its bounded poll while the test
    /// advances the clock — the shared `TestClock` is not thread-safe and is not reused.
    private final class PlaybackTestClock: MonotonicClock, @unchecked Sendable {
        private let lock = Mutex<Duration>(.zero)

        var now: Duration { lock.withLock { $0 } }

        func advance(by delta: Duration) {
            lock.withLock { $0 += delta }
        }
    }

    /// **The output, as a ledger.** Every assertion in this suite is made against what this
    /// recorded — start format, enqueue order, gain targets with clock stamps, stop count — and
    /// `isDrained` is the renderer's consumption, driven by the test via ``consumeAll()``.
    /// `Mutex`-guarded and `@unchecked Sendable` because the play task writes while the test
    /// reads.
    private final class FakePlaybackOutput: PlaybackOutputSeam, @unchecked Sendable {
        struct StartCall: Equatable {
            let sampleRate: Double
            let channelCount: Int
        }
        struct GainEvent: Equatable {
            let gain: Float
            let at: Duration
        }
        struct StopEvent: Equatable {
            let at: Duration
        }

        private let clock: PlaybackTestClock
        private let lock = Mutex<Ledger>(Ledger())

        private struct Ledger {
            var startCalls: [StartCall] = []
            var enqueuedFrames: [[Float]] = []
            var pendingFrames: [Float] = []
            var gainEvents: [GainEvent] = []
            var stopEvents: [StopEvent] = []
            var isRunning = false
            var nextStart: Result<Void, StartRefused> = .success(())
        }

        init(clock: PlaybackTestClock) {
            self.clock = clock
        }

        var isRunning: Bool { lock.withLock { $0.isRunning } }
        var isDrained: Bool { lock.withLock { $0.pendingFrames.isEmpty } }
        var startCalls: [StartCall] { lock.withLock { $0.startCalls } }
        var enqueuedFrames: [[Float]] { lock.withLock { $0.enqueuedFrames } }
        var gainEvents: [GainEvent] { lock.withLock { $0.gainEvents } }
        var stopEvents: [StopEvent] { lock.withLock { $0.stopEvents } }
        var nextStart: Result<Void, StartRefused> {
            get { lock.withLock { $0.nextStart } }
            set { lock.withLock { $0.nextStart = newValue } }
        }

        func start(sampleRate: Double, channelCount: Int) throws {
            try lock.withLock { ledger in
                // The attempt is recorded even when refused — the ledger is assertions against
                // what happened, and a refusal is a thing that happened.
                ledger.startCalls.append(StartCall(sampleRate: sampleRate, channelCount: channelCount))
                try ledger.nextStart.get()
                ledger.isRunning = true
            }
        }

        func enqueue(frames: [Float]) {
            lock.withLock { ledger in
                ledger.enqueuedFrames.append(frames)
                ledger.pendingFrames.append(contentsOf: frames)
            }
        }

        func setGain(_ gain: Float) {
            lock.withLock { ledger in
                ledger.gainEvents.append(GainEvent(gain: gain, at: clock.now))
            }
        }

        func stop() {
            lock.withLock { ledger in
                ledger.stopEvents.append(StopEvent(at: clock.now))
                ledger.isRunning = false
                ledger.pendingFrames = []
            }
        }

        /// The renderer's consumption: everything enqueued so far is now rendered — `isDrained`
        /// turns true, and a waiting `play` may return.
        func consumeAll() {
            lock.withLock { $0.pendingFrames = [] }
        }
    }
}