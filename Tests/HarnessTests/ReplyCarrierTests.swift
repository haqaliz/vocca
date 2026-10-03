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

import VoccaBootstrap
import VoccaCore
import XCTest

// MARK: - The doubles

/// The reply-sink recorder — the `RecordingStateSink` shape: an `@unchecked Sendable` box
/// written and read only on the main actor (the driver's one isolation domain), never
/// concurrently.
private final class RecordingReplySink: @unchecked Sendable {
    private(set) var values: [String?] = []
    func record(_ text: String?) {
        values.append(text)
    }
}

/// The render-resolution snapshot: what the sink held at the moment the render leg resolved
/// its synthesizer — the "the text is emitted before audio starts" proof (the render's
/// resolution is the first thing after the emission).
private final class ReplySinkSnapshotBox: @unchecked Sendable {
    private(set) var valuesAtResolve: [String?] = []
    func record(_ value: String?) {
        valuesAtResolve.append(value)
    }
}

/// The failure-sink recorder — the same single-threaded box shape as ``RecordingReplySink``.
private final class RecordingCarrierFailureSink: @unchecked Sendable {
    private(set) var values: [ConverseTurnFailure] = []
    func record(_ failure: ConverseTurnFailure) {
        values.append(failure)
    }
}

/// The static intent provider — one resolution for every utterance, the unwired `nil` when
/// the resolution is nil.
private final class StaticIntentProvider: @unchecked Sendable {
    private let resolution: IntentResolution?

    init(resolution: IntentResolution?) {
        self.resolution = resolution
    }

    func resolve(_ utterance: String) async -> IntentResolution? {
        resolution
    }
}

/// The hand-moved clock, as a **struct** — the driver's init requires `MonotonicClock &
/// Sendable`, and these tests never advance it (the loop's own copy freezing at `.zero`
/// changes nothing the assertions read).
private struct ReplyCarrierTestClock: MonotonicClock {
    var now: Duration = .zero
}

// MARK: - The suite

/// **The reply carrier's contract** (`reply-text-rendering` R1/R3, the carrier aspect's
/// acceptances 1-6): the driver's additive reply sink receives the reply text once, when the
/// reply is scheduled (before audio); the ask path's question is a reply and reaches it; the
/// clears land on barge-in, on the turn returning to listening and on idle; a render failure
/// keeps the text (the recorded rule); and the unwired default is byte-identical. Acceptance
/// 7 (the G5 re-anchor) is the REFACTOR step, not a row here. Compile-RED is the right
/// reason: `converseReplySink` does not exist yet.
@MainActor
final class ReplyCarrierTests: XCTestCase {

    /// The fixture VAD configuration, shared with the turn-taking suites.
    private static let configuration = VADConfiguration(
        onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)

    /// The fixture utterance tone: 880 Hz, orthogonal to the reply reference's 440 Hz.
    private static let userSpeech = TurnLoopFixtures.tone()

    /// The scripted commit detector: a one-frame pause keeps listening, the eighth frame
    /// commits.
    private static let commitments = [TurnCommitment](repeating: .keepListening, count: 7)
        + [.commit]

    /// The stub the reply renders: one 440 Hz chunk — the known-output reference.
    nonisolated private static let replyChunk = TurnLoopFixtures.chunk(
        amplitude: 0.4, frequency: 440, samples: 4000)

    nonisolated private static func makeStubSynthesizer() -> StubSynthesizer {
        StubSynthesizer(
            identity: VoiceIdentity(engineID: "reply-carrier-stub-synth", voiceName: nil),
            chunks: [replyChunk])
    }

    /// The shared stub instance the `@Sendable` provider closures capture — an actor, so the
    /// capture is honest.
    nonisolated private static let stubSynthesizer = makeStubSynthesizer()

    /// One committed turn's VAD script: listening silence, the 4-frame utterance, the
    /// 8-frame pause (commit).
    private static func turnScript() -> [SpeechActivity] {
        [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
            + [SpeechActivity](repeating: .silence, count: 8)
    }

    /// Builds the driver over the seam doubles with the recording reply sink — the carrier's
    /// widened init this file's contract requires.
    private func makeDriver(
        vad script: [SpeechActivity],
        capture: ScriptedContinuousCapture = ScriptedContinuousCapture(),
        asrProvider: @escaping @Sendable () -> (any ASREngine)?,
        cleanupProvider: @escaping @Sendable () async throws -> (any CleanupProvider)? = { nil },
        intentProvider: @escaping @Sendable (String) async -> IntentResolution? = { _ in nil },
        synthesizerProvider: @escaping @Sendable () async throws -> any SpeechSynthesizer,
        playback: any PlaybackEngine = FakePlaybackEngine(),
        replySink: RecordingReplySink,
        failureSink: @escaping @Sendable (ConverseTurnFailure) -> Void = { _ in }
    ) -> ConverseLoopDriver {
        ConverseLoopDriver(
            vad: ScriptedVAD(configuration: Self.configuration, script: script),
            turnDetector: ScriptedTurnDetector(script: Self.commitments),
            clock: ReplyCarrierTestClock(),
            gate: EchoGate(),
            capture: capture,
            asrProvider: asrProvider,
            cleanupProvider: cleanupProvider,
            intentProvider: intentProvider,
            replyGenerator: EchoReplyGenerator(),
            synthesizer: synthesizerProvider,
            playback: playback,
            onStateChange: { _ in },
            converseReplySink: { replySink.record($0) },
            failureSink: failureSink)
    }

    /// Bounded main-actor polling: yields until `condition` holds or the bound is exhausted —
    /// the ``ConverseLoopDriverTests`` shape.
    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<5_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("the condition never became true", file: file, line: line)
    }

    // MARK: - Acceptance 1: the reply at schedule time

    /// A committed turn with a reply → the sink receives the reply text **once**, and it
    /// already holds it when the render leg resolves its synthesizer — the emission is at
    /// schedule time, before audio starts. The session start's listening clear is the only
    /// nil before it.
    func testTheReplyReachesTheSinkOnceWhenItIsScheduled() async throws {
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()
        let sink = RecordingReplySink()
        let snapshot = ReplySinkSnapshotBox()

        let driver = makeDriver(
            vad: Self.turnScript(),
            capture: capture,
            asrProvider: { ScriptedASR(transcripts: ["hello there"]) },
            synthesizerProvider: {
                snapshot.record(sink.values.last.flatMap(\.self))
                return Self.stubSynthesizer
            },
            playback: playback,
            replySink: sink)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }

        XCTAssertEqual(
            sink.values, [nil, "hello there"],
            "the reply text reaches the sink exactly once — the start's listening clear is "
                + "the only nil before it")
        XCTAssertEqual(
            snapshot.valuesAtResolve, ["hello there"],
            "the sink already held the reply when the render resolved — the emission is at "
                + "schedule time, before audio starts")

        await driver.stop()
    }

    // MARK: - Acceptance 2: the ask path

    /// The ask path's question is a reply: it flows into `scheduleReply` as the reply text
    /// and reaches the sink — one emission point covers both (gap 1).
    func testTheAskQuestionReachesTheSink() async throws {
        let question = "Did you mean 'audit clear' or 'clear notes'?"
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()
        let sink = RecordingReplySink()
        let intent = StaticIntentProvider(resolution: .ask(question: question))

        let driver = makeDriver(
            vad: Self.turnScript(),
            capture: capture,
            asrProvider: { ScriptedASR(transcripts: ["run the audit"]) },
            intentProvider: { await intent.resolve($0) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            replySink: sink)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }

        XCTAssertEqual(
            sink.values, [nil, question],
            "the ask path's question is a reply — it reaches the sink (gap 1)")

        await driver.stop()
    }

    // MARK: - Acceptance 3: the barge-in clear

    /// A barge-in mid-reply → the sink receives the clear: the interrupted reply's text is
    /// discarded with its audio (Q3).
    func testABargeInMidReplyClearsTheSink() async throws {
        let script = Self.turnScript() + [.silence, .speech]
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()
        let sink = RecordingReplySink()

        let driver = makeDriver(
            vad: script,
            capture: capture,
            asrProvider: { ScriptedASR(transcripts: ["turn one"]) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            replySink: sink)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        XCTAssertEqual(sink.values, [nil, "turn one"], "the reply is up before the interrupt")

        capture.push([TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech])
        await waitUntil { driver.effects.contains(.bargeIn) }

        XCTAssertEqual(
            sink.values, [nil, "turn one", nil],
            "the barge-in clears the bubble — text and audio discarded together (Q3)")

        await driver.stop()
    }

    // MARK: - Acceptance 4: the listening and idle clears

    /// The turn returning to listening clears the reply (the next utterance's clear), and the
    /// next turn's reply arrives into a clean bubble.
    func testTheTurnReturningToListeningClearsTheReply() async throws {
        let script = Self.turnScript() + [SpeechActivity](repeating: .speech, count: 4)
            + [SpeechActivity](repeating: .silence, count: 8)
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()
        let sink = RecordingReplySink()
        let asr = ScriptedASR(transcripts: ["one", "two"])

        let driver = makeDriver(
            vad: script,
            capture: capture,
            asrProvider: { asr },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            replySink: sink)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        XCTAssertEqual(sink.values, [nil, "one"], "the first reply is up")

        driver.loop.reportPlaybackEnded()
        XCTAssertEqual(
            sink.values, [nil, "one", nil],
            "the turn returning to listening clears the reply — the next utterance's clear")

        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 2 }
        await driver.stop()

        XCTAssertEqual(
            sink.values, [nil, "one", nil, "two", nil],
            "the next utterance begins clean, its reply arrives, and idle clears at the stop")
    }

    /// The session's end (idle) clears the reply.
    func testIdleClearsTheReply() async throws {
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()
        let sink = RecordingReplySink()

        let driver = makeDriver(
            vad: Self.turnScript(),
            capture: capture,
            asrProvider: { ScriptedASR(transcripts: ["one"]) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            replySink: sink)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        XCTAssertEqual(sink.values, [nil, "one"])

        await driver.stop()

        XCTAssertEqual(
            sink.values, [nil, "one", nil],
            "the session's end (idle) clears the reply")
    }

    // MARK: - Acceptance 5: replyFailed keeps the text

    /// A render failure closes the playback window (`.playing → .listening`) but emits **no
    /// clear**: the reply happened as text, nothing was heard, and the text is the more
    /// valuable half — the recorded rule. The suppression does not stick: a later idle still
    /// clears.
    func testAReplyFailedKeepsTheText() async throws {
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()
        let sink = RecordingReplySink()
        let failures = RecordingCarrierFailureSink()
        let synthProvider = ScriptedSynthesizerProvider(stub: Self.makeStubSynthesizer())
        await synthProvider.armFailures(1)

        let driver = makeDriver(
            vad: Self.turnScript(),
            capture: capture,
            asrProvider: { ScriptedASR(transcripts: ["one"]) },
            synthesizerProvider: { try await synthProvider.resolve() },
            playback: playback,
            replySink: sink,
            failureSink: { failures.record($0) })

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { failures.values == [.replyFailed] }

        XCTAssertEqual(
            sink.values, [nil, "one"],
            "a render failure keeps the text — the reply happened as text; nothing was heard "
                + "(the recorded rule); no clear is emitted")
        let plays = await playback.playCount
        XCTAssertEqual(plays, 0, "the failed render never reached playback")

        await driver.stop()
        XCTAssertEqual(
            sink.values, [nil, "one", nil],
            "the failure's suppression does not stick — the session's idle still clears")
    }

    // MARK: - Acceptance 6: the unwired default

    /// The unwired default is the same driver: constructed without `converseReplySink` (the
    /// default no-op), it produces the identical effect ledger — the sink is additive and
    /// byte-identical when not wired.
    func testTheUnwiredDefaultIsByteIdentical() async throws {
        let wiredCapture = ScriptedContinuousCapture()
        let wiredPlayback = FakePlaybackEngine()
        let wiredSink = RecordingReplySink()
        let wiredDriver = makeDriver(
            vad: Self.turnScript(),
            capture: wiredCapture,
            asrProvider: { ScriptedASR(transcripts: ["one"]) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: wiredPlayback,
            replySink: wiredSink)

        let unwiredCapture = ScriptedContinuousCapture()
        let unwiredPlayback = FakePlaybackEngine()
        let unwiredDriver = ConverseLoopDriver(
            vad: ScriptedVAD(configuration: Self.configuration, script: Self.turnScript()),
            turnDetector: ScriptedTurnDetector(script: Self.commitments),
            clock: ReplyCarrierTestClock(),
            gate: EchoGate(),
            capture: unwiredCapture,
            asrProvider: { ScriptedASR(transcripts: ["one"]) },
            cleanupProvider: { nil },
            replyGenerator: EchoReplyGenerator(),
            synthesizer: { Self.stubSynthesizer },
            playback: unwiredPlayback,
            onStateChange: { _ in },
            failureSink: { _ in })

        func drive(
            _ driver: ConverseLoopDriver, _ capture: ScriptedContinuousCapture,
            _ playback: FakePlaybackEngine
        ) async throws {
            try driver.start()
            capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
            capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
            for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
            await waitUntil { await playback.playCount == 1 }
            await driver.stop()
        }

        try await drive(wiredDriver, wiredCapture, wiredPlayback)
        try await drive(unwiredDriver, unwiredCapture, unwiredPlayback)

        XCTAssertEqual(
            unwiredDriver.effects, wiredDriver.effects,
            "the unwired default produces the identical effect ledger — the sink is additive")
        XCTAssertEqual(
            wiredSink.values, [nil, "one", nil],
            "the wired run's sink saw the text and the idle clear")
        XCTAssertEqual(unwiredDriver.loop.state, .idle)
    }
}
