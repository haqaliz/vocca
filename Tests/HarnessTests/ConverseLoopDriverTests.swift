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

/// A scripted ASR failure.
private enum ScriptedASRError: Error {
    case failure
}

/// A scripted cleanup failure.
private enum ScriptedCleanupError: Error {
    case failure
}

/// A scripted synthesizer-resolution failure.
private enum ScriptedSynthesizerError: Error {
    case failure
}

/// The scripted `ContinuousAudioSource`: the test pushes frames and the stream yields them in
/// order to the driver's drive task. `stop()` records and ends the stream (the normal
/// terminal); `finishStream()` ends it without `stop()` (capture death); a second `start()`
/// while the first stream is live throws `.alreadyStarted` (the ownership contract); a
/// scripted `startError` throws `.unavailable`.
final class ScriptedContinuousCapture: ContinuousAudioSource {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: ContinuousAudioSourceError?
    private var continuation: AsyncStream<AudioBuffer>.Continuation?
    private var isOpen = false

    func start() throws -> AsyncStream<AudioBuffer> {
        startCount += 1
        if let startError { throw startError }
        guard !isOpen else { throw ContinuousAudioSourceError.alreadyStarted }
        isOpen = true
        let (stream, continuation) = AsyncStream.makeStream(of: AudioBuffer.self)
        self.continuation = continuation
        return stream
    }

    func stop() {
        stopCount += 1
        guard isOpen else { return }
        isOpen = false
        continuation?.finish()
        continuation = nil
    }

    /// Yields the scripted frames into the live stream — the capture's chunk arrival.
    func push(_ frames: [AudioBuffer]) {
        for frame in frames {
            continuation?.yield(frame)
        }
    }

    /// Ends the stream without `stop()` — the capture's abnormal terminal (the converter-error
    /// path's shape).
    func finishStream() {
        guard isOpen else { return }
        isOpen = false
        continuation?.finish()
        continuation = nil
    }
}

/// The scripted `ASREngine` — an **actor**, the `ProbeEngine` shape: `ASREngine` is a
/// `Sendable` protocol, and the double must cross actor boundaries honestly (the house's
/// boundary doctrine). Scripted transcripts per call; a scripted throw; a hold mode that
/// suspends the transcription until the test releases it (or the caller cancels).
actor ScriptedASR: ASREngine {
    let identity: EngineIdentity
    let supportsStreaming = false
    private(set) var transcribedBuffers: [AudioBuffer] = []
    private(set) var transcribeStarted = false
    private var transcripts: [String]

    /// Whether the next transcription throws — the honest ASR-failure injection.
    private var throwNext = false

    /// Whether transcription suspends on the hold gate until released.
    private var holdEnabled = false
    private var holdContinuation: AsyncStream<Void>.Continuation?
    private var holdStream: AsyncStream<Void>?

    init(
        transcripts: [String],
        identity: EngineIdentity = EngineIdentity(
            id: "scripted-asr", displayName: "Scripted ASR", isLocal: true)
    ) {
        self.transcripts = transcripts
        self.identity = identity
    }

    func prepare() async throws {}

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        transcribeStarted = true
        if holdEnabled {
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            holdStream = stream
            holdContinuation = continuation
            for await _ in stream {
                break
            }
        }
        transcribedBuffers.append(buffer)
        if throwNext {
            throwNext = false
            throw ScriptedASRError.failure
        }
        let text = transcripts.isEmpty ? "" : transcripts.removeFirst()
        return Transcript(
            text: text, segments: [], engine: identity, isFinal: true,
            audioDuration: buffer.audioDuration, missingSampleCount: buffer.missingSampleCount)
    }

    /// Releases the held transcription.
    func releaseHold() {
        holdContinuation?.yield(())
        holdContinuation = nil
        holdStream = nil
    }

    /// Arms the next transcription to throw.
    func armThrowNext() {
        throwNext = true
    }

    /// Enables the hold gate for the next transcriptions.
    func enableHold() {
        holdEnabled = true
    }

    /// Disables the hold gate.
    func disableHold() {
        holdEnabled = false
    }
}

/// The scripted `CleanupProvider` — an actor, for the same honesty reason as ``ScriptedASR``.
/// Records every context it was handed; returns a scripted cleaned text per call or throws.
actor RecordingCleanupProvider: CleanupProvider {
    let identity = ProviderIdentity(id: "recording-cleanup", displayName: "Recording cleanup")
    private(set) var contexts: [CleanupContext] = []
    private var outputs: [String]
    var throwNext = false
    let budget: Duration

    init(outputs: [String] = [], budget: Duration = .milliseconds(100)) {
        self.outputs = outputs
        self.budget = budget
    }

    func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String {
        contexts.append(context)
        if throwNext {
            throwNext = false
            throw ScriptedCleanupError.failure
        }
        return outputs.isEmpty ? transcript.text : outputs.removeFirst()
    }

    /// Arms the next cleanup to throw.
    func armThrowNext() {
        throwNext = true
    }
}

/// The scripted synthesizer provider — an actor: the driver's recipe closure is `@Sendable`
/// and the provider's state (the failure script) must cross the boundary honestly. Resolves
/// to the stub after the scripted failures are spent.
actor ScriptedSynthesizerProvider {
    let stub: StubSynthesizer
    private(set) var resolveCount = 0
    var failuresBeforeSuccess = 0

    init(stub: StubSynthesizer) {
        self.stub = stub
    }

    func resolve() async throws -> any SpeechSynthesizer {
        resolveCount += 1
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw ScriptedSynthesizerError.failure
        }
        return stub
    }

    /// Arms the provider to fail its next `failures` resolutions.
    func armFailures(_ failures: Int) {
        failuresBeforeSuccess = failures
    }
}

/// The state-sink recorder — an `@unchecked Sendable` box: the driver's `onStateChange` is a
/// `@Sendable` closure, and the recorder is written and read only on the main actor (the
/// driver's one isolation domain), never concurrently — the `TurnLoopDriveBox` shape.
private final class RecordingStateSink: @unchecked Sendable {
    private(set) var values: [TurnState] = []
    func record(_ state: TurnState) {
        values.append(state)
    }
}

/// The failure-sink recorder — the same single-threaded box shape as ``RecordingStateSink``.
private final class RecordingFailureSink: @unchecked Sendable {
    private(set) var values: [ConverseTurnFailure] = []
    func record(_ failure: ConverseTurnFailure) {
        values.append(failure)
    }
}

/// The current-engine box the resolve-once/swap test swaps through — written between turns on
/// the main actor, read by the driver's `@Sendable` provider closure.
private final class CurrentEngineBox: @unchecked Sendable {
    var engine: (any ASREngine)?
}

/// A main-actor-only resolve counter for the `@Sendable` provider closures.
private final class ResolveCounter: @unchecked Sendable {
    private(set) var count = 0
    func bump() {
        count += 1
    }
}

/// The hand-moved clock, as a **struct**: the driver's init requires `MonotonicClock & Sendable`
/// (the pipeline's documented shape — the cleanup race's watcher reads it from a task closure),
/// and the driver's tests never advance it — the loop's own copy freezing at `.zero` changes
/// nothing the assertions read (the playback window's timestamps are never asserted).
private struct ScriptedClock: MonotonicClock {
    var now: Duration = .zero

    mutating func advance(by duration: Duration) {
        now += duration
    }
}

// MARK: - The suite

/// **The converse loop driver's contract** (`converse-wiring` Phase 1): C10's recipe executed —
/// capture-stream drive, committed utterance → ASR → cleanup(`.conversing`) → reply →
/// `scheduleReply` → render + playback with the playback window, the barge-in path, the honest
/// drops, the capture-failure stop, and the state sink — pinned over the seam doubles before a
/// line of production code exists. Compile-time RED is the right reason for a new seam.
@MainActor
final class ConverseLoopDriverTests: XCTestCase {

    /// The fixture VAD configuration, shared with the turn-taking suites.
    private static let configuration = VADConfiguration(
        onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)

    /// The fixture utterance tone: 880 Hz, orthogonal to the reply reference's 440 Hz.
    private static let userSpeech = TurnLoopFixtures.tone()

    /// The scripted commit detector: a one-frame pause keeps listening, the eighth frame commits.
    private static let commitments = [TurnCommitment](repeating: .keepListening, count: 7)
        + [.commit]

    /// Builds the driver over the seam doubles and the scripted machinery.
    private func makeDriver(
        vad script: [SpeechActivity],
        capture: ScriptedContinuousCapture = ScriptedContinuousCapture(),
        asrProvider: @escaping @Sendable () -> (any ASREngine)?,
        cleanupProvider: @escaping @Sendable () async throws -> (any CleanupProvider)?,
        synthesizerProvider: @escaping @Sendable () async throws -> any SpeechSynthesizer,
        playback: any PlaybackEngine = FakePlaybackEngine(),
        clock: ScriptedClock = ScriptedClock(),
        replyGenerator: any ReplyGenerator = EchoReplyGenerator(),
        stateSink: RecordingStateSink = RecordingStateSink(),
        failureSink: RecordingFailureSink = RecordingFailureSink()
    ) -> ConverseLoopDriver {
        ConverseLoopDriver(
            vad: ScriptedVAD(configuration: Self.configuration, script: script),
            turnDetector: ScriptedTurnDetector(script: Self.commitments),
            clock: clock,
            gate: EchoGate(),
            capture: capture,
            asrProvider: asrProvider,
            cleanupProvider: cleanupProvider,
            replyGenerator: replyGenerator,
            synthesizer: synthesizerProvider,
            playback: playback,
            onStateChange: { stateSink.record($0) },
            failureSink: { failureSink.record($0) })
    }

    /// The stub the reply renders: one 440 Hz chunk — the known-output reference the echo rows
    /// play back.
    nonisolated private static let replyChunk = TurnLoopFixtures.chunk(
        amplitude: 0.4, frequency: 440, samples: 4000)

    nonisolated private static func makeStubSynthesizer() -> StubSynthesizer {
        StubSynthesizer(
            identity: VoiceIdentity(engineID: "converse-stub-synth", voiceName: nil),
            chunks: [replyChunk])
    }

    /// The shared stub instance the `@Sendable` provider closures capture — an actor, so the
    /// capture is honest (a fresh stub per closure would trip the main-actor rule).
    nonisolated private static let stubSynthesizer = makeStubSynthesizer()

    /// Whether the effect ledger contains a `.speakReply` — the associated-value-aware shape.
    nonisolated private static func effectsContainSpeakReply(_ effects: [TurnEffect]) -> Bool {
        effects.contains { effect in
            if case .speakReply = effect { return true } else { return false }
        }
    }

    /// Whether the effect ledger contains `.captureFailed`.
    nonisolated private static func effectsContainCaptureFailed(_ effects: [TurnEffect]) -> Bool {
        effects.contains { $0 == .captureFailed }
    }

    /// The shared full-arc VAD script: listening silence, the 4-frame first utterance, the
    /// 8-frame pause (commit), the gated echo (no VAD call), the 880 seed and barge-in pair,
    /// the interrupting 4-frame utterance, and its 8-frame pause (commit).
    private static func fullArcScript() -> [SpeechActivity] {
        [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
            + [SpeechActivity](repeating: .silence, count: 8)
            + [.silence, .speech]
            + [SpeechActivity](repeating: .speech, count: 4)
            + [SpeechActivity](repeating: .silence, count: 8)
    }

    /// Bounded main-actor polling: yields until `condition` holds or the bound is exhausted.
    /// Everything the driver does runs on the main actor, so a few yields always suffice; the
    /// bound is a hard failure, never a silent timeout.
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

    // MARK: - The compile pins

    /// The driver exists with the fourteen-parameter init and the public loop — a widened or
    /// renamed seam stops compiling (the frozen-signature doctrine). The two intent closures
    /// are pinned here at their nil-safe defaults (`converse-step`'s deliberate widening — a
    /// reviewed edit, never an edit-to-match of a broken build): the unwired driver is
    /// today's driver.
    func testTheDriverIsConstructibleOverTheDoubles() {
        func requireDriver(_ driver: ConverseLoopDriver) -> ConverseLoopDriver { driver }

        let driver = requireDriver(
            ConverseLoopDriver(
                vad: ScriptedVAD(configuration: Self.configuration, script: [.silence]),
                turnDetector: ScriptedTurnDetector(script: [.keepListening]),
                clock: ScriptedClock(),
                gate: EchoGate(),
                capture: ScriptedContinuousCapture(),
                asrProvider: { ScriptedASR(transcripts: []) },
                cleanupProvider: { nil },
                intentProvider: { _ in nil },
                intentActionHandler: { _ in nil },
                replyGenerator: EchoReplyGenerator(),
                synthesizer: { Self.stubSynthesizer },
                playback: FakePlaybackEngine(),
                onStateChange: { _ in },
                failureSink: { _ in }
            ))
        XCTAssertEqual(driver.loop.state, .idle, "a fresh driver's loop is idle")
    }

    // MARK: - The full arc

    /// **The whole recipe, one arc**: start → silence → speech → pause (commit) → the
    /// utterance pipeline (ASR with the concatenated utterance; cleanup recorded with
    /// `mode == .conversing`; reply generated) → `scheduleReply` → the stub render + fake
    /// playback with `reportPlaybackStarted/Chunk` (the window stays open — the reply is still
    /// sounding) → the gated echo frame + the seed/barge-in pair (cancel + duck +
    /// `reportPlaybackEnded`) → the interrupting utterance → pause (second commit) → second
    /// reply → `stop()`.
    func testTheFullArcWithABargeInRunsTheWholeRecipe() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["turn one", "turn two"])
        let cleanup = RecordingCleanupProvider(outputs: ["cleaned one", "cleaned two"])
        let cleanupResolves = ResolveCounter()
        let synth = Self.makeStubSynthesizer()
        let synthProvider = ScriptedSynthesizerProvider(stub: synth)
        let playback = FakePlaybackEngine()
        let states = RecordingStateSink()
        let failures = RecordingFailureSink()

        let driver = makeDriver(
            vad: Self.fullArcScript(),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: {
                cleanupResolves.bump()
                return cleanup
            },
            synthesizerProvider: { try await synthProvider.resolve() },
            playback: playback,
            stateSink: states,
            failureSink: failures)

        try driver.start()

        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([
            Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech,
        ])
        for _ in 0..<8 {
            capture.push([TurnLoopFixtures.silence()])
        }

        // The first reply: the pipeline drained, the window opened, the fake played.
        await waitUntil { await playback.playCount == 1 }

        let echo = TurnLoopFixtures.echo(of: Self.replyChunk, gain: 0.85)
        capture.push([echo])
        capture.push([Self.userSpeech])  // accepted residue — the seed
        capture.push([Self.userSpeech])  // VAD flips — the barge-in

        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 {
            capture.push([TurnLoopFixtures.silence()])
        }

        await waitUntil { await playback.playCount == 2 }
        await driver.stop()

        XCTAssertEqual(driver.loop.state, .idle)
        XCTAssertEqual(
            driver.effects,
            [
                .started, .speechBegan,
                .turnCommitted(utterance: [Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech]),
                .speakReply(text: "cleaned one"),
                .bargeIn,
                .turnCommitted(
                    utterance: [
                        Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech,
                        Self.userSpeech, Self.userSpeech,
                    ]),
                .speakReply(text: "cleaned two"),
                .stopped,
            ],
            "the full effect ledger — one arc, one barge-in, no surprises")
        XCTAssertEqual(driver.loop.fedFrameCount, 29, "every frame fed, in order")
        XCTAssertEqual(driver.loop.gatedFrameCount, 1, "the echo frame was gated")

        let transcribed = await asr.transcribedBuffers
        XCTAssertEqual(transcribed.count, 2, "one transcription per committed utterance")
        XCTAssertEqual(
            transcribed[0].samples,
            [Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech].flatMap(\.samples),
            "the ASR receives the concatenated utterance — never the pause frames")

        let contexts = await cleanup.contexts
        XCTAssertEqual(contexts.count, 2, "one cleanup per committed utterance")
        XCTAssertEqual(contexts.map(\.mode), [.conversing, .conversing])

        let played = await playback.playCount
        XCTAssertEqual(played, 2, "both replies reached the playback engine")
        let halted = await playback.haltCount
        XCTAssertEqual(halted, 1, "the barge-in ducked exactly once")
        let cancelled = await synth.cancelCount
        XCTAssertEqual(cancelled, 1, "the barge-in cancelled the render once")
        XCTAssertEqual(cleanupResolves.count, 1, "the cleanup provider resolves once per session")

        XCTAssertEqual(states.values, [.listening, .uttering, .committed, .playing, .uttering, .committed, .playing, .idle])
        XCTAssertTrue(failures.values.isEmpty, "a clean arc carries no failure notice")
    }

    // MARK: - The honest drops

    /// ASR nil or throw → exactly one `.asrFailed` notice, zero `.speakReply`, nothing
    /// scheduled, the loop left `.committed`; then speech + silence → a fresh commit proceeds
    /// (no hang).
    func testASRFailureDropsTheTurnHonestly() async throws {
        // The throw leg: the engine throws on its next transcription, then recovers.
        let throwingASR = ScriptedASR(transcripts: ["later"])
        await throwingASR.armThrowNext()
        let throwFailures = RecordingFailureSink()
        let throwCapture = ScriptedContinuousCapture()
        let throwSynth = Self.makeStubSynthesizer()
        let throwPlayback = FakePlaybackEngine()

        let throwDriver = makeDriver(
            vad: [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8)
                + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8),
            capture: throwCapture,
            asrProvider: { throwingASR },
            cleanupProvider: { nil },
            synthesizerProvider: { throwSynth },
            playback: throwPlayback,
            failureSink: throwFailures)

        try throwDriver.start()
        throwCapture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        throwCapture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { throwCapture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { throwFailures.values == [.asrFailed] }

        XCTAssertEqual(
            throwDriver.loop.state, .committed,
            "an ASR failure leaves the loop committed — no reply scheduled, no state moved")
        XCTAssertFalse(Self.effectsContainSpeakReply(throwDriver.effects), "nothing was scheduled")
        let threwPlays = await throwPlayback.playCount
        XCTAssertEqual(threwPlays, 0, "nothing reached the playback")

        // The fresh commit proceeds: no hang after the drop.
        throwCapture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { throwCapture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await throwPlayback.playCount == 1 }
        await throwDriver.stop()
        XCTAssertTrue(
            throwFailures.values == [.asrFailed],
            "exactly one notice — the recovered turn is not a failure")

        // The nil leg: the provider answers nil (the engine is not ready) → the same drop.
        let nilASR = ScriptedASR(transcripts: ["fine"])
        let engineBox = CurrentEngineBox()
        let nilFailures = RecordingFailureSink()
        let nilCapture = ScriptedContinuousCapture()
        let nilSynth = Self.makeStubSynthesizer()
        let nilPlayback = FakePlaybackEngine()

        let nilDriver = makeDriver(
            vad: [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8)
                + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8),
            capture: nilCapture,
            asrProvider: { engineBox.engine },
            cleanupProvider: { nil },
            synthesizerProvider: { nilSynth },
            playback: nilPlayback,
            failureSink: nilFailures)

        try nilDriver.start()
        nilCapture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        nilCapture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { nilCapture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { nilFailures.values == [.asrFailed] }
        XCTAssertEqual(nilDriver.loop.state, .committed)
        XCTAssertFalse(Self.effectsContainSpeakReply(nilDriver.effects))

        engineBox.engine = nilASR
        nilCapture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { nilCapture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await nilPlayback.playCount == 1 }
        await nilDriver.stop()
        XCTAssertTrue(
            nilFailures.values == [.asrFailed],
            "exactly one notice — the readiness-gate nil is a notice, never a hang")
    }

    /// The `.replyFailed` twin: the reply was scheduled, but the render leg fails (the
    /// synthesizer recipe throws — the lazy resolve is the render leg's first step) → the
    /// window closes honestly (`reportPlaybackEnded`, `.playing → .listening`), one
    /// `.replyFailed` notice, and the next turn proceeds. The reply generator seam itself is
    /// non-throwing by contract (the shipped signature is `reply(to:) -> String`), so the
    /// reply-path failure is injected at the render — the only place the seam permits.
    func testReplyGeneratorFailureDropsTheTurnHonestly() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["first", "second"])
        let synth = Self.makeStubSynthesizer()
        let synthProvider = ScriptedSynthesizerProvider(stub: synth)
        await synthProvider.armFailures(1)
        let playback = FakePlaybackEngine()
        let failures = RecordingFailureSink()
        let states = RecordingStateSink()

        let driver = makeDriver(
            vad: [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8)
                + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            synthesizerProvider: { try await synthProvider.resolve() },
            playback: playback,
            stateSink: states,
            failureSink: failures)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }

        await waitUntil { failures.values == [.replyFailed] }
        XCTAssertEqual(
            states.values.last, .listening,
            "the render failure closes the window honestly — the loop returns to listening")
        let beforeRecovery = await playback.playCount
        XCTAssertEqual(beforeRecovery, 0, "the failed render never reached playback")
        XCTAssertEqual(
            driver.effects.filter { effect in
                if case .speakReply = effect { return true } else { return false }
            }.count, 1,
            "the reply was scheduled once — the drop is at the render, never before")

        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()

        XCTAssertTrue(
            failures.values == [.replyFailed],
            "exactly one notice — the recovered turn is not a failure")
        XCTAssertEqual(driver.loop.state, .idle)
    }

    /// Cleanup failure yields raw: a throwing provider → the raw transcript reaches the reply
    /// generator (no drop), no notice.
    func testCleanupFailureYieldsRaw() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["raw words"])
        let cleanup = RecordingCleanupProvider()
        await cleanup.armThrowNext()
        let playback = FakePlaybackEngine()
        let failures = RecordingFailureSink()

        let driver = makeDriver(
            vad: [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { cleanup },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            failureSink: failures)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()

        XCTAssertEqual(
            driver.effects.filter { effect in
                if case .speakReply(let text) = effect { return text == "raw words" } else {
                    return false
                }
            }.count, 1,
            "the raw transcript reached the reply generator — cleanup failure never drops")
        XCTAssertTrue(failures.values.isEmpty, "a cleanup failure is not a failure notice")
    }

    /// The converse context: `mode == .conversing`, the nothing-focused target, an empty
    /// dictionary, and the provider's own budget.
    func testCleanupReceivesTheConversingModeAndNoTarget() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["hello"])
        let cleanup = RecordingCleanupProvider(budget: .milliseconds(250))
        let playback = FakePlaybackEngine()

        let driver = makeDriver(
            vad: [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { cleanup },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()

        let contexts = await cleanup.contexts
        let context = try XCTUnwrap(contexts.first)
        XCTAssertEqual(context.mode, .conversing, "the converse driver cleans as .conversing")
        XCTAssertEqual(
            context.target,
            TargetContext(bundleID: nil, windowTitle: nil, isSecureInput: false),
            "converse never names a target — the never-a-target rule")
        XCTAssertTrue(context.dictionary.isEmpty, "no replacement rules in converse")
        XCTAssertEqual(context.budget, .milliseconds(250), "the provider's own budget")
    }

    // MARK: - The honest stop

    /// The capture stream dies without `stop()` → `.captureFailed` notice once, the loop
    /// `.idle`, the state sink's last entry `.idle` — the no-trap stop.
    func testCaptureDeathEndsTheSessionHonestly() async throws {
        let capture = ScriptedContinuousCapture()
        let states = RecordingStateSink()
        let failures = RecordingFailureSink()

        let driver = makeDriver(
            vad: [.silence, .silence],
            capture: capture,
            asrProvider: { nil },
            cleanupProvider: { nil },
            synthesizerProvider: { Self.stubSynthesizer },
            stateSink: states,
            failureSink: failures)

        try driver.start()
        capture.push([TurnLoopFixtures.silence()])
        capture.finishStream()

        await waitUntil { driver.loop.state == .idle }
        await Task.yield()

        XCTAssertEqual(failures.values, [.captureFailed], "exactly one capture-failure notice")
        XCTAssertEqual(states.values.last, .idle, "the state sink ends idle")
        XCTAssertEqual(capture.stopCount, 0, "nobody stopped the capture — it died")
        XCTAssertTrue(Self.effectsContainCaptureFailed(driver.effects))
    }

    /// A second `start()` while the capture is already open is refused — the ownership pin,
    /// mapped from `.alreadyStarted`: nothing started, no notice.
    func testStartRefusedWhenTheCaptureIsAlreadyOpen() throws {
        let capture = ScriptedContinuousCapture()
        let failures = RecordingFailureSink()

        let driver = makeDriver(
            vad: [.silence],
            capture: capture,
            asrProvider: { nil },
            cleanupProvider: { nil },
            synthesizerProvider: { Self.stubSynthesizer },
            failureSink: failures)

        // The capture is opened from outside the driver — the stream stays live.
        _ = try capture.start()

        XCTAssertThrowsError(try driver.start()) { error in
            XCTAssertEqual(error as? ContinuousAudioSourceError, .alreadyStarted)
        }
        XCTAssertEqual(driver.loop.state, .idle, "nothing was started")
        XCTAssertTrue(failures.values.isEmpty, "no notice is owed for a refused start")
    }

    /// A start against an unavailable capture maps `.unavailable` through — nothing started,
    /// no notice.
    func testStartRefusedWhenTheCaptureIsUnavailable() throws {
        let capture = ScriptedContinuousCapture()
        capture.startError = .unavailable
        let failures = RecordingFailureSink()

        let driver = makeDriver(
            vad: [.silence],
            capture: capture,
            asrProvider: { nil },
            cleanupProvider: { nil },
            synthesizerProvider: { Self.stubSynthesizer },
            failureSink: failures)

        XCTAssertThrowsError(try driver.start()) { error in
            XCTAssertEqual(error as? ContinuousAudioSourceError, .unavailable)
        }
        XCTAssertEqual(driver.loop.state, .idle)
        XCTAssertEqual(capture.stopCount, 0, "nothing was opened, nothing to close")
        XCTAssertTrue(failures.values.isEmpty)
    }

    // MARK: - The resolve-once doctrine

    /// The ASR provider resolves **once per committed utterance**, and a provider switching
    /// engines between turns yields attribution from the new engine on the second turn (the
    /// egress fold's resolve-once doctrine).
    func testASRResolvesOncePerCommittedUtteranceAndHonorsASwap() async throws {
        let first = ScriptedASR(transcripts: ["one"])
        let second = ScriptedASR(transcripts: ["two"])
        let engineBox = CurrentEngineBox()
        engineBox.engine = first
        let resolveCount = ResolveCounter()
        let capture = ScriptedContinuousCapture()
        let playback = FakePlaybackEngine()

        let driver = makeDriver(
            vad: [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8)
                + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8),
            capture: capture,
            asrProvider: {
                resolveCount.bump()
                return engineBox.engine
            },
            cleanupProvider: { nil },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }

        // The mid-session swap: a settings switch mints a new engine behind the same provider.
        engineBox.engine = second

        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 2 }
        await driver.stop()

        XCTAssertEqual(resolveCount.count, 2, "one resolve per committed utterance")
        let firstTranscribes = await first.transcribedBuffers.count
        XCTAssertEqual(firstTranscribes, 1, "the first turn went to the first engine")
        let secondTranscribes = await second.transcribedBuffers.count
        XCTAssertEqual(
            secondTranscribes, 1,
            "the swap happened between turns — the second turn went to the new engine")
    }

    // MARK: - The never-speak-over-the-user rule

    /// Speech while the pipeline is still running supersedes the pending reply: the late
    /// `scheduleReply` is refused by the loop's own guard — no double speech, no notice, and
    /// the interrupting utterance commits normally afterwards.
    func testSpeechBeforeThePipelineCompletesSupersedesThePendingReply() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["late", "second"])
        await asr.enableHold()
        let playback = FakePlaybackEngine()
        let failures = RecordingFailureSink()

        let driver = makeDriver(
            vad: [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8)
                + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            failureSink: failures)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }

        // The first utterance commits and the pipeline suspends in the ASR; the user speaks
        // again before the reply could be scheduled — the loop supersedes the pending turn.
await waitUntil { await asr.transcribeStarted }
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        await waitUntil { driver.loop.state == .uttering }
        XCTAssertFalse(
            Self.effectsContainSpeakReply(driver.effects),
            "the superseded turn has not been scheduled yet")

await asr.disableHold()
        await asr.releaseHold()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(driver.loop.state, .uttering, "the user is still talking")
        XCTAssertFalse(
            Self.effectsContainSpeakReply(driver.effects),
            "the late scheduleReply was refused — never speak over the user")
        let playedBeforeRecovery = await playback.playCount
        XCTAssertEqual(playedBeforeRecovery, 0, "nothing played over the user")
        XCTAssertTrue(failures.values.isEmpty, "a superseded turn is not a failure")

        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()

        let replies = driver.effects.filter { effect in
            if case .speakReply = effect { return true } else { return false }
        }
        XCTAssertEqual(replies, [.speakReply(text: "second")], "only the second turn replies")
        XCTAssertEqual(driver.loop.state, .idle)
    }

    // MARK: - The state sink

    /// The full arc's `onStateChange` sequence, pinned exactly: listening → uttering →
    /// committed → playing → (barge-in) uttering → committed → playing → idle. The barge-in's
    /// `reportPlaybackEnded` cannot transition back to listening (the loop already left
    /// `.playing` at the interrupt) — the sequence is the machine's own trajectory.
    func testTheStateSinkReceivesEveryTransitionInOrder() async throws {
        let capture = ScriptedContinuousCapture()
        let states = RecordingStateSink()
        let playback = FakePlaybackEngine()

        let driver = makeDriver(
            vad: Self.fullArcScript(),
            capture: capture,
            asrProvider: { ScriptedASR(transcripts: ["a", "b"]) },
            cleanupProvider: { nil },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            stateSink: states)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }

        capture.push([TurnLoopFixtures.echo(of: Self.replyChunk, gain: 0.85)])
        capture.push([Self.userSpeech])
        capture.push([Self.userSpeech])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 2 }
        await driver.stop()

        XCTAssertEqual(
            states.values,
            [.listening, .uttering, .committed, .playing, .uttering, .committed, .playing, .idle])
    }

    // MARK: - The silent skip and the stop

    /// An empty transcript is a silent skip: no reply, no notice, the loop left `.committed`,
    /// and the next speech supersedes it.
    func testEmptyTranscriptIsASilentSkip() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["", "hi"])
        let playback = FakePlaybackEngine()
        let failures = RecordingFailureSink()

        let driver = makeDriver(
            vad: [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8)
                + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            failureSink: failures)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await asr.transcribedBuffers.count == 1 }

        XCTAssertEqual(driver.loop.state, .committed, "the empty turn is not a state change")
        XCTAssertFalse(Self.effectsContainSpeakReply(driver.effects), "nothing was scheduled")
        XCTAssertTrue(failures.values.isEmpty, "empty is an answer, never a notice")

        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()
        XCTAssertTrue(failures.values.isEmpty)
    }

    /// A stop mid-pipeline cancels the in-flight work: no `scheduleReply`, no notice — the
    /// user asked to stop.
    func testStopCancelsAnInFlightPipelineWithoutANotice() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["never"])
        await asr.enableHold()
        let playback = FakePlaybackEngine()
        let failures = RecordingFailureSink()

        let driver = makeDriver(
            vad: [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
                + [SpeechActivity](repeating: .silence, count: 8),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            failureSink: failures)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await asr.transcribeStarted }

        await driver.stop()

        XCTAssertEqual(driver.loop.state, .idle)
        XCTAssertFalse(Self.effectsContainSpeakReply(driver.effects), "nothing was scheduled")
        XCTAssertTrue(failures.values.isEmpty, "a user stop is not a failure")
        let played = await playback.playCount
        XCTAssertEqual(played, 0)
    }

    /// `stop()` is idempotent: the capture stops once, `.stopped` fires once, the loop ends
    /// `.idle`.
    func testStopIsIdempotent() async throws {
        let capture = ScriptedContinuousCapture()
        let failures = RecordingFailureSink()

        let driver = makeDriver(
            vad: [.silence],
            capture: capture,
            asrProvider: { nil },
            cleanupProvider: { nil },
            synthesizerProvider: { Self.stubSynthesizer },
            failureSink: failures)

        try driver.start()
        capture.push([TurnLoopFixtures.silence()])

        await driver.stop()
        await driver.stop()

        XCTAssertEqual(capture.stopCount, 1, "the capture stops once")
        XCTAssertEqual(driver.effects.filter { $0 == .stopped }.count, 1, "one .stopped")
        XCTAssertEqual(driver.loop.state, .idle)
        XCTAssertTrue(failures.values.isEmpty, "a stop is never a capture failure")
    }
}