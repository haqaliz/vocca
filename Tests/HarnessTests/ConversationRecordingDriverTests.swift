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

import Synchronization
import VoccaBootstrap
import VoccaCore
import XCTest

// MARK: - The doubles

/// One recorded pair as the spy holds it — the assertion-friendly mirror of the store's
/// `(utterance, reply)` record, without the `interrupted` flag (that is the store's to own).
struct RecordedTurn: Equatable, Sendable {
    let utterance: String
    let reply: String
}

/// The ordering ledger both halves of the D2 proof write to — the spy's record completion and
/// the reply sink's delivery of spoken text. "Observed before the `.speakReply` effect" is the
/// relative order of the entries, never a timing claim; `Mutex`-owned because the spy's
/// executor and the main actor both write it (the `CountCollector` shape).
final class RecordingOrderLog: Sendable {
    private let lock = Mutex<[String]>([])

    func append(_ event: String) {
        lock.withLock { $0.append(event) }
    }

    var events: [String] {
        lock.withLock { $0 }
    }
}

/// The conversation recorder spy (`driver-recording` D5): an actor recording `(utterance,
/// reply)` pairs and mark counts into the shared order log, satisfying ``ConversationRecording``
/// exactly as the store will. The hold gate (the ``ScriptedASR`` shape) makes the D2 ordering
/// provable: while `recordTurn` is suspended in the gate, the awaited call has not returned,
/// so the driver cannot have reached `loop.scheduleReply` — asserted on the driver's effect
/// ledger, never on a timer. Under a fire-and-forget record the pipeline proceeds past the gate
/// and the assertion reddens: the mutation the ordering test exists to catch.
actor ConversationRecorderSpy: ConversationRecording {
    private(set) var records: [RecordedTurn] = []
    private(set) var marks = 0
    private(set) var isRecording = false

    let order: RecordingOrderLog

    private var holdEnabled = false
    private var holdContinuation: AsyncStream<Void>.Continuation?

    init(order: RecordingOrderLog = RecordingOrderLog()) {
        self.order = order
    }

    func recordTurn(utterance: String, reply: String) async {
        order.append("record")
        isRecording = true
        if holdEnabled {
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            holdContinuation = continuation
            for await _ in stream {
                break
            }
        }
        records.append(RecordedTurn(utterance: utterance, reply: reply))
        order.append("recordDone")
        isRecording = false
    }

    func markLastTurnInterrupted() async {
        order.append("mark")
        marks += 1
    }

    /// Whether nothing has been recorded or marked — the failed/skipped-turn shape's witness,
    /// spelled here so the polling closures need no precedence tricks.
    func hasRecordedNothing() -> Bool {
        records.isEmpty && marks == 0
    }

    /// Arms the gate: the next `recordTurn` suspends inside the call until `releaseHold()`.
    func enableHold() {
        holdEnabled = true
    }

    /// Releases a suspended `recordTurn`.
    func releaseHold() {
        holdContinuation?.yield(())
        holdContinuation = nil
    }
}

/// The scripted intent resolutions, consumed one per turn — an actor, so the `@Sendable`
/// provider closure's capture is honest (the ``ScriptedIntentProvider`` shape).
private actor RecordingIntentScript {
    private let resolutions: [IntentResolution]
    private var index = 0

    init(_ resolutions: [IntentResolution]) {
        self.resolutions = resolutions
    }

    func next() -> IntentResolution? {
        guard index < resolutions.count else { return nil }
        defer { index += 1 }
        return resolutions[index]
    }
}

/// The failure-sink recorder — the same single-threaded box shape as ``RecordingStateSink``.
private final class RecordingDriverFailureSink: @unchecked Sendable {
    private(set) var values: [ConverseTurnFailure] = []
    func record(_ failure: ConverseTurnFailure) {
        values.append(failure)
    }
}

/// The current-engine box — written between turns on the main actor, read by the driver's
/// `@Sendable` provider closure (the ``CurrentEngineBox`` shape).
private final class RecordingEngineSlot: @unchecked Sendable {
    var engine: (any ASREngine)?
}

// MARK: - The suite

/// **The driver's recording semantics** (`driver-recording` D1-D3, D5): the one point in
/// `runUtterancePipeline` where the cleaned utterance and the computed reply both exist — the
/// awaited record, applied **before** `loop.scheduleReply`, so a barge-in's mark is addressed to
/// the turn whose reply was playing; the mark delivered on every barge-in; failed turns and a
/// user stop with no committed reply recorded nowhere; the ask and action-ack turns recorded
/// through the same one point. Written first, against a `conversationRecorder:` parameter that
/// does not exist yet — compile-time RED is the right reason for an additive seam.
///
/// The ``ConversationRecorderSpy`` is the behavior-level witness — calls, mark counts and the
/// shared order log, plus the driver's own effect ledger for the in-flight ordering — never a
/// timing claim. The harness is the ``ConverseLoopDriverTests`` one: the scripted capture, the
/// scripted VAD and turn detector, the stub synthesizer and the fake playback over the injected
/// clock — the same doubles the composed acceptance scripts.
@MainActor
final class ConversationRecordingDriverTests: XCTestCase {

    /// The fixture VAD configuration, shared with the turn-taking suites.
    private static let configuration = VADConfiguration(
        onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)

    /// The scripted commit detector: a one-frame pause keeps listening, the eighth frame commits.
    private static let commitments = [TurnCommitment](repeating: .keepListening, count: 7)
        + [.commit]

    /// The fixture utterance tone: 880 Hz, orthogonal to the reply reference's 440 Hz.
    private static let userSpeech = TurnLoopFixtures.tone()

    /// The stub the reply renders: one 440 Hz chunk — the known-output reference.
    nonisolated private static let replyChunk = TurnLoopFixtures.chunk(
        amplitude: 0.4, frequency: 440, samples: 4000)

    nonisolated private static func makeStubSynthesizer() -> StubSynthesizer {
        StubSynthesizer(
            identity: VoiceIdentity(
                engineID: "conversation-recording-stub-synth", voiceName: nil),
            chunks: [replyChunk])
    }

    /// The shared stub instance the `@Sendable` provider closures capture — an actor, so the
    /// capture is honest.
    nonisolated private static let stubSynthesizer = makeStubSynthesizer()

    /// The hand-moved clock, as a **struct** — the driver's init requires `MonotonicClock &
    /// Sendable`, and these tests never advance it (the ``ScriptedClock`` shape).
    private struct ScriptedClock: MonotonicClock {
        var now: Duration = .zero
    }

    /// One committed turn's VAD script: listening silence, the 4-frame utterance, the
    /// 8-frame pause (commit).
    private static func turnScript() -> [SpeechActivity] {
        [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
            + [SpeechActivity](repeating: .silence, count: 8)
    }

    /// `turns` committed turns with a barge-in between each pair — the full-arc shape: after a
    /// reply plays, one residue frame (the `.silence` answer — accepted, never a barge-in) and
    /// one speech frame (the `.speech` answer — the barge-in) precede the next utterance's
    /// frames and its pause.
    private static func multiTurnScript(turns: Int) -> [SpeechActivity] {
        var script = turnScript()
        for _ in 1..<turns {
            script += [.silence, .speech] + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8)
        }
        return script
    }

    /// Whether the effect ledger contains a `.speakReply` — the associated-value-aware shape.
    nonisolated private static func effectsContainSpeakReply(_ effects: [TurnEffect]) -> Bool {
        effects.contains { effect in
            if case .speakReply = effect { return true } else { return false }
        }
    }

    /// The `.speakReply` texts in the ledger, in order — what the user heard.
    nonisolated private static func spokenReplies(in effects: [TurnEffect]) -> [String] {
        effects.compactMap { effect in
            if case .speakReply(let text) = effect { return text } else { return nil }
        }
    }

    /// Builds the driver over the seam doubles and the spy — the ``ConverseLoopDriverTests``
    /// harness plus the recording seam, in the init's own parameter order (the recorder after
    /// the reply sink, the D4 ordering).
    private func makeDriver(
        vad script: [SpeechActivity],
        capture: ScriptedContinuousCapture = ScriptedContinuousCapture(),
        asrProvider: @escaping @Sendable () -> (any ASREngine)?,
        cleanupProvider: @escaping @Sendable () async throws -> (any CleanupProvider)? = { nil },
        intentProvider: @escaping @Sendable (String) async -> IntentResolution? = { _ in nil },
        intentActionHandler: @escaping @Sendable (ActionInvocation, String) async -> String?
            = { _, _ in nil },
        synthesizerProvider: @escaping @Sendable () async throws -> any SpeechSynthesizer,
        playback: any PlaybackEngine = FakePlaybackEngine(),
        replySink: @escaping @Sendable (String?) -> Void = { _ in },
        recorder: ConversationRecorderSpy?,
        failureSink: @escaping @Sendable (ConverseTurnFailure) -> Void = { _ in }
    ) -> ConverseLoopDriver {
        ConverseLoopDriver(
            vad: ScriptedVAD(configuration: Self.configuration, script: script),
            turnDetector: ScriptedTurnDetector(script: Self.commitments),
            clock: ScriptedClock(),
            gate: EchoGate(),
            capture: capture,
            asrProvider: asrProvider,
            cleanupProvider: cleanupProvider,
            intentProvider: intentProvider,
            intentActionHandler: intentActionHandler,
            replyGenerator: EchoReplyGenerator(),
            synthesizer: synthesizerProvider,
            playback: playback,
            onStateChange: { _ in },
            converseReplySink: replySink,
            conversationRecorder: recorder,
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

    // MARK: - D1 · record at commit

    /// One completed turn calls `recordTurn` exactly once, with the **cleaned** utterance and
    /// the exact reply — the echo default (reply == utterance) still records — and the record
    /// is observed **before** the `.speakReply` effect, in two ways, neither timing-based:
    /// while the record is suspended in the spy's gate, the driver's effect ledger holds no
    /// `.speakReply` (the awaited call has not returned, so `loop.scheduleReply` was never
    /// reached); and the shared order log reads `record → recordDone → speakReply` (the record
    /// completes strictly before the sink delivers the spoken text).
    func testACompletedTurnRecordsOnceWithTheCleanedTextBeforeTheSpeakReplyEffect() async throws {
        let spy = ConversationRecorderSpy()
        await spy.enableHold()
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()
        let driver = makeDriver(
            vad: Self.turnScript(),
            capture: capture,
            asrProvider: { ScriptedASR(transcripts: ["turn one"]) },
            cleanupProvider: { RecordingCleanupProvider(outputs: ["cleaned one"]) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            replySink: { [order = spy.order] text in
                if text != nil { order.append("speakReply") }
            },
            recorder: spy)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }

        await waitUntil { await spy.isRecording }
        XCTAssertFalse(
            Self.effectsContainSpeakReply(driver.effects),
            "while the awaited record is in flight the reply has not been scheduled — the "
                + "record strictly precedes the .speakReply effect (a fire-and-forget record "
                + "would let the schedule — and the effect — land first)")
        await spy.releaseHold()
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()

        let records = await spy.records
        XCTAssertEqual(
            records, [RecordedTurn(utterance: "cleaned one", reply: "cleaned one")],
            "recordTurn runs exactly once per completed turn, with the cleaned utterance and "
                + "the exact reply — the echo default records like any other reply")
        XCTAssertEqual(
            spy.order.events, ["record", "recordDone", "speakReply"],
            "the shared order log: the record completes, then the reply text is delivered — "
                + "never the reverse")
        XCTAssertEqual(
            driver.effects.filter { effect in
                if case .speakReply = effect { return true } else { return false }
            }.count, 1,
            "one committed turn, one scheduled reply")
    }

    // MARK: - D2 · the barge-in mark

    /// After a committed reply, a barge-in delivers exactly one `markLastTurnInterrupted` —
    /// addressed to the turn whose reply was playing (the store's mark-last semantics are
    /// ordered by the driver's awaited record at commit: the playing turn is always the last
    /// recorded one) — and a following turn records normally, unaffected by the earlier mark.
    func testABargeInMarksExactlyOnceAndTheNextTurnRecordsNormally() async throws {
        let spy = ConversationRecorderSpy()
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()
        let driver = makeDriver(
            vad: Self.multiTurnScript(turns: 2),
            capture: capture,
            asrProvider: { ScriptedASR(transcripts: ["one", "two"]) },
            cleanupProvider: { RecordingCleanupProvider(outputs: ["cleaned one", "cleaned two"]) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            replySink: { [order = spy.order] text in
                if text != nil { order.append("speakReply") }
            },
            recorder: spy)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }

        capture.push([Self.userSpeech])  // the accepted residue — the VAD answers silence
        capture.push([Self.userSpeech])  // the VAD flips — the barge-in
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await spy.marks == 1 }
        await waitUntil { await playback.playCount == 2 }
        await driver.stop()

        let marks = await spy.marks
        XCTAssertEqual(marks, 1, "one mark for the one barge-in — never more")
        let recordedTurns = await spy.records
        XCTAssertEqual(
            recordedTurns,
            [
                RecordedTurn(utterance: "cleaned one", reply: "cleaned one"),
                RecordedTurn(utterance: "cleaned two", reply: "cleaned two"),
            ],
            "both turns record — the mark does not disturb the following turn")
        let order = spy.order.events
        let firstRecordDone = try XCTUnwrap(order.firstIndex(of: "recordDone"))
        let mark = try XCTUnwrap(order.firstIndex(of: "mark"))
        XCTAssertLessThan(
            firstRecordDone, mark,
            "the mark lands after the first turn's record completed — the barge-in is "
                + "addressed to the recorded turn whose reply was playing")
    }

    /// The driver calls the mark for **every** barge-in: two rapid barge-ins, each after its
    /// own committed turn, deliver two marks over three recorded turns — the driver never
    /// decides which mark is owed (the store owns the empty/no-turn no-op).
    func testEveryBargeInDeliversAMark() async throws {
        let spy = ConversationRecorderSpy()
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()
        let driver = makeDriver(
            vad: Self.multiTurnScript(turns: 3),
            capture: capture,
            asrProvider: { ScriptedASR(transcripts: ["one", "two", "three"]) },
            cleanupProvider: {
                RecordingCleanupProvider(outputs: ["cleaned one", "cleaned two", "cleaned three"])
            },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            recorder: spy)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }

        var expectedPlayCount = 2
        for _ in 0..<2 {
            capture.push([Self.userSpeech])  // the accepted residue
            capture.push([Self.userSpeech])  // the barge-in
            capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
            for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
            await waitUntil { await playback.playCount == expectedPlayCount }
            expectedPlayCount += 1
        }
        await waitUntil { await spy.marks == 2 }
        await driver.stop()

        let marks = await spy.marks
        XCTAssertEqual(marks, 2, "every barge-in delivers exactly one mark")
        let recordedTurns = await spy.records
        XCTAssertEqual(
            recordedTurns.count, 3,
            "three committed turns recorded, each between the barge-ins")
    }

    // MARK: - D3 · failed turns and the silent stop

    /// An ASR failure — the throw leg and the nil (readiness-gate) leg — produces zero recorder
    /// calls for the failed turn, and the recovered turn records normally afterwards: the
    /// failure never reaches the seam, and never poisons it.
    func testASRFailedTurnsProduceZeroCallsAndRecoveryRecords() async throws {
        // The throw leg: the engine throws on the first transcription, then recovers.
        let throwingASR = ScriptedASR(transcripts: ["later"])
        await throwingASR.armThrowNext()
        let throwSpy = ConversationRecorderSpy()
        let throwCapture = ScriptedContinuousCapture()
        let throwPlayback = FakePlaybackEngine()
        let throwDriver = makeDriver(
            vad: Self.turnScript() + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8),
            capture: throwCapture,
            asrProvider: { throwingASR },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: throwPlayback,
            recorder: throwSpy)

        try throwDriver.start()
        throwCapture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        throwCapture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { throwCapture.push([TurnLoopFixtures.silence()]) }
        throwCapture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { throwCapture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await throwPlayback.playCount == 1 }
        await throwDriver.stop()

        let throwRecords = await throwSpy.records
        XCTAssertEqual(
            throwRecords, [RecordedTurn(utterance: "later", reply: "later")],
            "the failed turn recorded nothing — only the recovered turn's record exists")
        let throwMarks = await throwSpy.marks
        XCTAssertEqual(throwMarks, 0, "no mark without a barge-in")

        // The nil leg: the provider answers nil (the engine is not ready) → the same drop.
        let nilASR = ScriptedASR(transcripts: ["fine"])
        let engineBox = RecordingEngineSlot()
        let nilSpy = ConversationRecorderSpy()
        let nilCapture = ScriptedContinuousCapture()
        let nilPlayback = FakePlaybackEngine()
        let nilDriver = makeDriver(
            vad: Self.turnScript() + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8),
            capture: nilCapture,
            asrProvider: { engineBox.engine },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: nilPlayback,
            recorder: nilSpy)

        try nilDriver.start()
        nilCapture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        nilCapture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { nilCapture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await nilSpy.hasRecordedNothing() }
        XCTAssertEqual(nilDriver.loop.state, .committed, "the readiness-gate nil drops the turn")

        engineBox.engine = nilASR
        nilCapture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { nilCapture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await nilPlayback.playCount == 1 }
        await nilDriver.stop()

        let nilRecords = await nilSpy.records
        XCTAssertEqual(
            nilRecords, [RecordedTurn(utterance: "fine", reply: "fine")],
            "only the recovered turn records")
    }

    /// A capture failure mid-session (the stream dies, `.captureFailed`, nothing owed) with no
    /// committed turn produces zero recorder calls.
    func testCaptureDeathProducesZeroCalls() async throws {
        let spy = ConversationRecorderSpy()
        let capture = ScriptedContinuousCapture()
        let driver = makeDriver(
            vad: [.silence, .silence],
            capture: capture,
            asrProvider: { nil },
            synthesizerProvider: { Self.stubSynthesizer },
            recorder: spy)

        try driver.start()
        capture.push([TurnLoopFixtures.silence()])
        capture.finishStream()

        await waitUntil { driver.loop.state == .idle }
        await driver.stop()

        let records = await spy.records
        XCTAssertTrue(records.isEmpty, "no turn ever committed — nothing recorded")
        let marks = await spy.marks
        XCTAssertEqual(marks, 0, "no barge-in ever landed")
    }

    /// A user stop cancels the in-flight pipeline **before** the record point: no reply was
    /// ever committed, so the seam sees nothing. An empty transcript is the same answer by a
    /// different path — a silent skip, no reply owed, nothing recorded.
    func testAUserStopAndAnEmptyTranscriptRecordNothing() async throws {
        // The stop leg: the pipeline suspends in the ASR, then the user stops.
        let stopASR = ScriptedASR(transcripts: ["never"])
        await stopASR.enableHold()
        let stopSpy = ConversationRecorderSpy()
        let stopCapture = ScriptedContinuousCapture()
        let stopDriver = makeDriver(
            vad: Self.turnScript(),
            capture: stopCapture,
            asrProvider: { stopASR },
            synthesizerProvider: { Self.stubSynthesizer },
            recorder: stopSpy)

        try stopDriver.start()
        stopCapture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        stopCapture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { stopCapture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await stopASR.transcribeStarted }
        await stopDriver.stop()

        XCTAssertEqual(stopDriver.loop.state, .idle)
        let stopRecords = await stopSpy.records
        XCTAssertTrue(stopRecords.isEmpty, "a stopped pipeline never reaches the record")
        let stopMarks = await stopSpy.marks
        XCTAssertEqual(stopMarks, 0)

        // The empty-transcript leg: the seam's legitimate answer, a silent skip — no reply
        // owed, nothing recorded; the next turn records normally.
        let emptyASR = ScriptedASR(transcripts: ["", "hi"])
        let emptySpy = ConversationRecorderSpy()
        let emptyCapture = ScriptedContinuousCapture()
        let emptyPlayback = FakePlaybackEngine()
        let emptyDriver = makeDriver(
            vad: Self.turnScript() + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8),
            capture: emptyCapture,
            asrProvider: { emptyASR },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: emptyPlayback,
            recorder: emptySpy)

        try emptyDriver.start()
        emptyCapture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        emptyCapture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { emptyCapture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await emptyASR.transcribedBuffers.count == 1 }
        let skippedRecords = await emptySpy.records
        XCTAssertTrue(skippedRecords.isEmpty, "the empty transcript's silent skip records nothing")
        let skippedMarks = await emptySpy.marks
        XCTAssertEqual(skippedMarks, 0)

        emptyCapture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { emptyCapture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await emptyPlayback.playCount == 1 }
        await emptyDriver.stop()

        let emptyRecords = await emptySpy.records
        XCTAssertEqual(
            emptyRecords, [RecordedTurn(utterance: "hi", reply: "hi")],
            "the empty transcript skipped silently — the following turn is the only record")
    }

    /// **Recorded deviation from the spec's D3 wording**, which lists `replyFailed` among the
    /// zero-call failures: with D2's record point — the one place the cleaned utterance and the
    /// computed reply both exist, awaited **before** `loop.scheduleReply` — a render failure
    /// happens strictly after the record, and `.replyFailed` is by definition a post-commit
    /// failure (`ConverseTurnFailure`: "after the reply was scheduled"). There is no driver-side
    /// point where a render-failed turn exists without its record; the reply was committed to
    /// speak, the failure is in the audio. This test pins the reconciled semantics: the
    /// committed turn records once, and no mark lands (no barge-in).
    func testARenderFailedTurnKeepsItsCommittedRecord() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["first", "second"])
        let synth = Self.makeStubSynthesizer()
        let synthProvider = ScriptedSynthesizerProvider(stub: synth)
        await synthProvider.armFailures(1)
        let playback = FakePlaybackEngine()
        let spy = ConversationRecorderSpy()
        let failures = RecordingDriverFailureSink()
        let driver = makeDriver(
            vad: Self.turnScript() + Self.turnScript(),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { RecordingCleanupProvider(outputs: ["cleaned one", "cleaned two"]) },
            synthesizerProvider: { try await synthProvider.resolve() },
            playback: playback,
            recorder: spy,
            failureSink: { failures.record($0) })

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { failures.values == [.replyFailed] }

        let duringFailureRecords = await spy.records
        XCTAssertEqual(
            duringFailureRecords.count, 1,
            "the render-failed turn's record already exists at the commit point — the failure "
                + "is post-commit (the repo's D3 spec wording is unreachable under D2; the "
                + "reconciled semantics are pinned here)")
        let duringFailureMarks = await spy.marks
        XCTAssertEqual(duringFailureMarks, 0, "no barge-in — no mark")

        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()

        let recordedTurns = await spy.records
        XCTAssertEqual(
            recordedTurns,
            [
                RecordedTurn(utterance: "cleaned one", reply: "cleaned one"),
                RecordedTurn(utterance: "cleaned two", reply: "cleaned two"),
            ],
            "the recovered turn appends after the failed turn's committed record")
    }

    // MARK: - the ask turn and the action-ack turn

    /// An ask turn and an action ack turn **do** record: the question a `.ask` resolution
    /// speaks and the handler's ack after a `.toolCall` are the reply at the same one
    /// `.speakReply` point — the record carries exactly what was committed to speak.
    func testAskAndAckTurnsRecordTheirSpokenText() async throws {
        let question = "Did you mean 'audit clear' or 'clear notes'?"
        let invocation = ActionInvocation(providerID: "probe-intent", toolID: "clear-audit")!
        let resolutions = RecordingIntentScript([.ask(question: question), .toolCall(invocation)])
        let spy = ConversationRecorderSpy()
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()
        let driver = makeDriver(
            vad: Self.multiTurnScript(turns: 2),
            capture: capture,
            asrProvider: { ScriptedASR(transcripts: ["run the audit", "clear the audit log"]) },
            cleanupProvider: {
                RecordingCleanupProvider(outputs: ["cleaned one", "cleaned two"])
            },
            intentProvider: { _ in await resolutions.next() },
            intentActionHandler: { _, _ in "Done." },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            recorder: spy)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        capture.push([Self.userSpeech])  // the accepted residue
        capture.push([Self.userSpeech])  // the barge-in
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 2 }
        await driver.stop()

        let recordedTurns = await spy.records
        XCTAssertEqual(
            recordedTurns,
            [
                RecordedTurn(utterance: "cleaned one", reply: question),
                RecordedTurn(utterance: "cleaned two", reply: "Done."),
            ],
            "the ask's question and the ack's 'Done.' are the replies at the one record point")
        XCTAssertEqual(
            Self.spokenReplies(in: driver.effects), [question, "Done."],
            "the recorded replies are exactly what was committed to speak")
    }

    // MARK: - the raw fallback and the restart

    /// A cleaned result that is empty/whitespace falls back to the raw transcript — and the
    /// record carries whatever the pipeline produced: no special case at the record point.
    func testAWhitespaceCleanResultRecordsTheRawFallback() async throws {
        let spy = ConversationRecorderSpy()
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()
        let driver = makeDriver(
            vad: Self.turnScript(),
            capture: capture,
            asrProvider: { ScriptedASR(transcripts: ["turn one"]) },
            cleanupProvider: { RecordingCleanupProvider(outputs: ["   "]) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            recorder: spy)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()

        let recordedTurns = await spy.records
        XCTAssertEqual(
            recordedTurns, [RecordedTurn(utterance: "turn one", reply: "turn one")],
            "the raw fallback is what the pipeline produced — recorded without a special case")
    }

    /// A driver restarted mid-session keeps recording through the same recorder — the seam
    /// carries no session identity of its own.
    func testARestartedDriverKeepsRecordingThroughTheSameRecorder() async throws {
        let spy = ConversationRecorderSpy()
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()
        let driver = makeDriver(
            vad: Self.turnScript() + Self.turnScript(),
            capture: capture,
            asrProvider: { ScriptedASR(transcripts: ["one", "two"]) },
            cleanupProvider: { RecordingCleanupProvider(outputs: ["one", "two"]) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            recorder: spy)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 2 }
        await driver.stop()

        let recordedTurns = await spy.records
        XCTAssertEqual(
            recordedTurns,
            [
                RecordedTurn(utterance: "one", reply: "one"),
                RecordedTurn(utterance: "two", reply: "two"),
            ],
            "the same recorder accumulates across a restart — sessions share the seam")
    }
}