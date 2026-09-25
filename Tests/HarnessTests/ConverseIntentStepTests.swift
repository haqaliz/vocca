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

/// The scripted intent provider — a scripted resolution per call, with a call log (the
/// utterance text it was handed). A plain `@unchecked Sendable` box, the
/// ``RecordingStateSink`` shape: the driver's `intentProvider` closure is `@Sendable`, and
/// the box is written and read only on the main actor (the driver's one isolation domain),
/// never concurrently.
private final class ScriptedIntentProvider: @unchecked Sendable {
    private(set) var calls: [String] = []
    private var resolutions: [IntentResolution]

    init(resolutions: [IntentResolution]) {
        self.resolutions = resolutions
    }

    /// Resolves the next scripted resolution, or `nil` when the script is spent — the
    /// unwired provider's honest answer.
    func resolve(_ utterance: String) async -> IntentResolution? {
        calls.append(utterance)
        return resolutions.isEmpty ? nil : resolutions.removeFirst()
    }
}

/// The scripted action handler — a scripted reply per call, with a call log (the
/// invocations it was handed). The same single-threaded box shape as
/// ``ScriptedIntentProvider``.
private final class ScriptedIntentActionHandler: @unchecked Sendable {
    private(set) var calls: [ActionInvocation] = []
    private var replies: [String?]

    init(replies: [String?]) {
        self.replies = replies
    }

    /// Handles the invocation, returning the scripted spoken reply — `nil` when the script
    /// says the terminal decision stays silent.
    func handle(_ invocation: ActionInvocation) async -> String? {
        calls.append(invocation)
        return replies.isEmpty ? nil : replies.removeFirst()
    }
}

/// The failure-sink recorder — the same single-threaded box shape as the intent doubles.
private final class RecordingIntentFailureSink: @unchecked Sendable {
    private(set) var values: [ConverseTurnFailure] = []
    func record(_ failure: ConverseTurnFailure) {
        values.append(failure)
    }
}

/// The hand-moved clock, as a **struct** — the driver's init requires `MonotonicClock &
/// Sendable`, and these tests never advance it (the loop's own copy freezing at `.zero`
/// changes nothing the assertions read).
private struct ConverseIntentTestClock: MonotonicClock {
    var now: Duration = .zero
}

// MARK: - The suite

/// **The intent step's contract** (`intent-layer` PRD R4; `converse-step` spec acceptance
/// 1-4): the widened utterance pipeline — between cleanup and the reply — branches on the
/// resolution: `.ask(question:)` → the question is the spoken reply and **nothing
/// executes** (R2: a guess never runs); `.toolCall(invocation:)` → the action handler's
/// reply is spoken (a `nil` handler reply falls through to the reply generator); `.none`
/// and the unwired `nil` → the shipped reply generator untouched, byte-identical. The
/// bounded re-ask: a second consecutive `.ask` falls through to the reply generator, and
/// the per-session counter resets on any non-`.ask` outcome.
///
/// The tests drive a scripted driver over the shared seam doubles — the
/// ``ConverseLoopDriverTests`` shape — and fail to **compile** against today's
/// twelve-parameter init: the two intent closures are the RED this file pins.
@MainActor
final class ConverseIntentStepTests: XCTestCase {

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
            identity: VoiceIdentity(engineID: "converse-intent-stub-synth", voiceName: nil),
            chunks: [replyChunk])
    }

    /// The shared stub instance the `@Sendable` provider closures capture — an actor, so
    /// the capture is honest.
    nonisolated private static let stubSynthesizer = makeStubSynthesizer()

    /// The fixture invocation a confident resolution carries.
    private static let fixtureInvocation = ActionInvocation(
        providerID: "probe-intent", toolID: "clear-audit")!

    /// One committed turn's VAD script: listening silence, the 4-frame utterance, the
    /// 8-frame pause (commit).
    private static func turnScript() -> [SpeechActivity] {
        [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
            + [SpeechActivity](repeating: .silence, count: 8)
    }

    /// Builds the driver over the seam doubles and the scripted intent machinery — the
    /// widened fourteen-parameter init this file's contract requires.
    private func makeDriver(
        vad script: [SpeechActivity],
        capture: ScriptedContinuousCapture = ScriptedContinuousCapture(),
        asrProvider: @escaping @Sendable () -> (any ASREngine)?,
        cleanupProvider: @escaping @Sendable () async throws -> (any CleanupProvider)?,
        intentProvider: @escaping @Sendable (String) async -> IntentResolution?,
        intentActionHandler: @escaping @Sendable (ActionInvocation) async -> String?,
        synthesizerProvider: @escaping @Sendable () async throws -> any SpeechSynthesizer,
        playback: any PlaybackEngine = FakePlaybackEngine(),
        failureSink: @escaping @Sendable (ConverseTurnFailure) -> Void = { _ in }
    ) -> ConverseLoopDriver {
        ConverseLoopDriver(
            vad: ScriptedVAD(configuration: Self.configuration, script: script),
            turnDetector: ScriptedTurnDetector(script: Self.commitments),
            clock: ConverseIntentTestClock(),
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
            failureSink: failureSink)
    }

    /// Bounded main-actor polling: yields until `condition` holds or the bound is
    /// exhausted — the ``ConverseLoopDriverTests`` shape.
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

    /// The `.speakReply` texts in the ledger, in order.
    nonisolated private static func spokenReplies(in effects: [TurnEffect]) -> [String] {
        effects.compactMap { effect in
            if case .speakReply(let text) = effect { return text } else { return nil }
        }
    }

    // MARK: - Acceptance 1: the ask path

    /// An `.ask` resolution makes the driver speak the question text, and the action
    /// handler is never touched — nothing executes (R2: a guess never runs).
    func testAnAskResolutionIsSpokenAndTouchesNoAction() async throws {
        let question = "Did you mean 'audit clear' or 'clear notes'?"
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["run the audit"])
        let provider = ScriptedIntentProvider(resolutions: [.ask(question: question)])
        let handler = ScriptedIntentActionHandler(replies: [])
        let playback = FakePlaybackEngine()
        let failures = RecordingIntentFailureSink()

        let driver = makeDriver(
            vad: Self.turnScript(),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            intentProvider: { await provider.resolve($0) },
            intentActionHandler: { await handler.handle($0) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            failureSink: { failures.record($0) })

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()

        XCTAssertEqual(
            Self.spokenReplies(in: driver.effects), [question],
            "the question is the spoken reply — the ask path, and nothing else")
        let handled = handler.calls
        XCTAssertEqual(
            handled, [],
            "an .ask resolution executes nothing — the action handler is never touched")
        let resolved = provider.calls
        XCTAssertEqual(
            resolved, ["run the audit"],
            "the resolver read the cleaned utterance once")
        XCTAssertTrue(
            failures.values.isEmpty,
            "an ask is an answer, never a failure notice")
    }

    // MARK: - Acceptance 2: the tool-call path

    /// A `.toolCall` resolution routes through the handler, and the handler's reply is the
    /// spoken reply — the invocation the resolution carried, verbatim.
    func testAToolCallResolutionRoutesThroughTheHandlerWhoseReplyIsSpoken() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["clear the audit log"])
        let provider = ScriptedIntentProvider(resolutions: [.toolCall(Self.fixtureInvocation)])
        let handler = ScriptedIntentActionHandler(replies: ["Done."])
        let playback = FakePlaybackEngine()
        let failures = RecordingIntentFailureSink()

        let driver = makeDriver(
            vad: Self.turnScript(),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            intentProvider: { await provider.resolve($0) },
            intentActionHandler: { await handler.handle($0) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            failureSink: { failures.record($0) })

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()

        XCTAssertEqual(
            Self.spokenReplies(in: driver.effects), ["Done."],
            "the handler's reply is the spoken reply")
        let handled = handler.calls
        XCTAssertEqual(
            handled, [Self.fixtureInvocation],
            "the handler received the resolution's invocation, verbatim")
        XCTAssertTrue(failures.values.isEmpty)
    }

    /// A `.toolCall` whose handler stays silent (nil) falls through to the reply generator
    /// — the honest-drop channel, never a throw and never a notice.
    func testAToolCallWhoseHandlerIsSilentFallsThroughToTheReplyGenerator() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["turn one"])
        let provider = ScriptedIntentProvider(resolutions: [.toolCall(Self.fixtureInvocation)])
        let handler = ScriptedIntentActionHandler(replies: [nil])
        let playback = FakePlaybackEngine()
        let failures = RecordingIntentFailureSink()

        let driver = makeDriver(
            vad: Self.turnScript(),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            intentProvider: { await provider.resolve($0) },
            intentActionHandler: { await handler.handle($0) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            failureSink: { failures.record($0) })

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
        await waitUntil { await playback.playCount == 1 }
        await driver.stop()

        XCTAssertEqual(
            Self.spokenReplies(in: driver.effects), ["turn one"],
            "a silent handler falls through to the reply generator — the echo of the "
                + "cleaned utterance, byte-identical")
        let handled = handler.calls
        XCTAssertEqual(handled, [Self.fixtureInvocation], "the handler was still consulted")
        XCTAssertTrue(failures.values.isEmpty, "silence is an answer, never a notice")
    }

    // MARK: - Acceptance 3: the unwired fall-through

    /// `.none` and the unwired `nil` reproduce today's echo path byte-for-byte — the
    /// intent step is a no-op for the default configuration.
    func testNoneAndNilResolutionsReproduceTheEchoPath() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["one", "two"])
        // `nil` (the unwired provider's answer) and `.none` (a resolver that matched
        // nothing) are distinct spellings of the same fall-through.
        let provider = ScriptedIntentProvider(resolutions: [.none])
        let handler = ScriptedIntentActionHandler(replies: [])
        let playback = FakePlaybackEngine()
        let failures = RecordingIntentFailureSink()

        let driver = makeDriver(
            vad: Self.turnScript() + Self.turnScript(),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            intentProvider: { await provider.resolve($0) },
            intentActionHandler: { await handler.handle($0) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            failureSink: { failures.record($0) })

        try driver.start()
        for turn in 0..<2 {
            capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
            capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
            for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
            await waitUntil { await playback.playCount == turn + 1 }
        }
        await driver.stop()

        XCTAssertEqual(
            Self.spokenReplies(in: driver.effects), ["one", "two"],
            "the first turn's nil and the second turn's .none both fall through to the "
                + "reply generator — the echo path, byte-identical")
        let handled = handler.calls
        XCTAssertEqual(handled, [], "no resolution executed anything")
        XCTAssertTrue(failures.values.isEmpty)
    }

    // MARK: - Acceptance 4: the bounded re-ask

    /// Two consecutive `.ask`s: the first is spoken, the second falls through to the reply
    /// generator — the ask loop is bounded (PRD R4: still `.ask` after the re-resolution →
    /// fall through to `.none`/echo).
    func testTwoConsecutiveAsksFallThroughToTheReplyGenerator() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["first", "second"])
        let provider = ScriptedIntentProvider(resolutions: [
            .ask(question: "question one"), .ask(question: "question two"),
        ])
        let handler = ScriptedIntentActionHandler(replies: [])
        let playback = FakePlaybackEngine()
        let failures = RecordingIntentFailureSink()

        let driver = makeDriver(
            vad: Self.turnScript() + Self.turnScript(),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            intentProvider: { await provider.resolve($0) },
            intentActionHandler: { await handler.handle($0) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            failureSink: { failures.record($0) })

        try driver.start()
        for turn in 0..<2 {
            capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
            capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
            for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
            await waitUntil { await playback.playCount == turn + 1 }
        }
        await driver.stop()

        XCTAssertEqual(
            Self.spokenReplies(in: driver.effects), ["question one", "second"],
            "the first .ask is spoken; the second consecutive .ask falls through to the "
                + "reply generator — the bounded re-ask")
        let handled = handler.calls
        XCTAssertEqual(handled, [], "no resolution executed anything")
        XCTAssertTrue(failures.values.isEmpty)
    }

    /// The re-ask bound resets on a non-`.ask` outcome: after a resolved action, a fresh
    /// `.ask` is spoken again rather than fallen through.
    func testTheReAskBoundResetsOnANonAskOutcome() async throws {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["first", "second", "third"])
        let provider = ScriptedIntentProvider(resolutions: [
            .ask(question: "question one"),
            .toolCall(Self.fixtureInvocation),
            .ask(question: "question three"),
        ])
        let handler = ScriptedIntentActionHandler(replies: ["Done."])
        let playback = FakePlaybackEngine()
        let failures = RecordingIntentFailureSink()

        let driver = makeDriver(
            vad: Self.turnScript() + Self.turnScript() + Self.turnScript(),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            intentProvider: { await provider.resolve($0) },
            intentActionHandler: { await handler.handle($0) },
            synthesizerProvider: { Self.stubSynthesizer },
            playback: playback,
            failureSink: { failures.record($0) })

        try driver.start()
        for turn in 0..<3 {
            capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
            capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
            for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
            await waitUntil { await playback.playCount == turn + 1 }
        }
        await driver.stop()

        XCTAssertEqual(
            Self.spokenReplies(in: driver.effects),
            ["question one", "Done.", "question three"],
            "the resolved action resets the re-ask bound — the third turn's .ask is spoken "
                + "again, not fallen through")
        XCTAssertTrue(failures.values.isEmpty)
    }
}