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
import VoccaActions
import VoccaBootstrap
import VoccaCore
import XCTest

// MARK: - The doubles

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
private struct IntentDriverTestClock: MonotonicClock {
    var now: Duration = .zero
}

// MARK: - The suite

/// **The driver-handler integration** (`action-round-trip` plan Phase 3): the seam between this
/// aspect and `converse-step`, driven end to end — a scripted `ConverseLoopDriver` over the
/// seam doubles, with the **real** `composeIntentWiring` recipe supplying the driver's intent
/// slots: utterance → resolve → `.toolCall` → the card (the gate's sentence verbatim,
/// re-rendered after the record) → the existing confirm closure → the audit row reconstructs
/// with `approvedSentence` matched.
///
/// The driver's own spoken reply while the card is up is the honest-drop fall-through (the
/// handler returned `nil` — the card is the surface) — pinned here so the channel is
/// documented rather than assumed.
@MainActor
final class IntentDriverIntegrationTests: XCTestCase {

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

    private static let providerID = AuditActionProvider.providerID
    private static let clearToolID = AuditActionProvider.clearToolID

    private func clearSentence(entries: Int) -> String {
        "Permanently delete \(entries) \(entries == 1 ? "entry" : "entries") from the action "
            + "audit log. This cannot be undone."
    }

    /// One committed turn's VAD script: listening silence, the 4-frame utterance, the
    /// 8-frame pause (commit).
    private static func turnScript() -> [SpeechActivity] {
        [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
            + [SpeechActivity](repeating: .silence, count: 8)
    }

    /// Builds the driver over the seam doubles and the **real** intent recipe's closures.
    private func makeDriver(
        capture: ScriptedContinuousCapture,
        asr: ScriptedASR,
        intentProvider: @escaping @Sendable (String) async -> IntentResolution?,
        intentActionHandler: @escaping @Sendable (ActionInvocation) async -> String?,
        playback: FakePlaybackEngine,
        failures: RecordingIntentFailureSink
    ) -> ConverseLoopDriver {
        ConverseLoopDriver(
            vad: ScriptedVAD(configuration: Self.configuration, script: Self.turnScript()),
            turnDetector: ScriptedTurnDetector(script: Self.commitments),
            clock: IntentDriverTestClock(),
            gate: EchoGate(),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            intentProvider: intentProvider,
            intentActionHandler: intentActionHandler,
            replyGenerator: EchoReplyGenerator(),
            synthesizer: { Self.stubSynthesizer },
            playback: playback,
            onStateChange: { _ in },
            failureSink: { failures.record($0) })
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

    /// **The end-to-end voice round trip through a scripted driver**: "clear the audit log"
    /// commits as a turn, the wiring resolves it against the enablement catalog, the action leg
    /// presents the card (the gate's sentence re-rendered after the record — the count the
    /// confirm will face), the existing confirm closure answers it, and the audit row
    /// reconstructs with the shown sentence bound to the record. The driver's own spoken reply
    /// while the card is up is the honest-drop fall-through.
    func testTheVoiceRoundTripDrivesTheDriverEndToEndThroughTheCardAndTheAudit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-intent-driver-integration-\(UUID().uuidString)")
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = AuditActionProvider(store: auditStore)
        let harness = IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await harness.seedEntries(2)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)

        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: ["clear the audit log"])
        let playback = FakePlaybackEngine()
        let failures = RecordingIntentFailureSink()

        let driver = makeDriver(
            capture: capture,
            asr: asr,
            intentProvider: { await harness.wiring.resolve($0) },
            intentActionHandler: { await harness.wiring.performAction($0) },
            playback: playback,
            failures: failures)

        try driver.start()
        capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
        capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
        for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }

        // The card lands mid-converse: the utterance resolved, the gate asked, and the wiring
        // presented the card with the sentence re-rendered after its own record — the count
        // the confirm will face.
        await waitUntil { harness.root.widgetStore.state.confirmation != nil }
        let card = try XCTUnwrap(harness.root.widgetStore.state.confirmation?.signal)
        XCTAssertEqual(
            card.sentence, clearSentence(entries: 3),
            "the card carries the gate's sentence verbatim, re-rendered after the record — the "
                + "end-to-end count-bearing leg")
        XCTAssertEqual(card.providerID, Self.providerID)
        XCTAssertEqual(card.toolID, Self.clearToolID)

        // The driver's own turn ends with the honest-drop fall-through — the handler returned
        // nil (the card is the surface), so the echo speaks.
        await waitUntil { await playback.playCount == 1 }
        XCTAssertEqual(
            Self.spokenReplies(in: driver.effects), ["clear the audit log"],
            "while the card is up the turn falls through to the reply generator — the card is "
                + "the surface, never a spoken stand-in")

        // The human leg — the existing confirm closure over the intent-presented card, and the
        // audit reconstructs with the approved sentence bound to the record.
        await harness.surface.confirm()
        XCTAssertNil(harness.root.widgetStore.state.confirmation)

        let reloaded = await harness.auditStore.load()
        XCTAssertEqual(
            reloaded.count, 1,
            "audit.clear ran: the log holds only the clear's own record (the record lands after)")
        let entry = try XCTUnwrap(reloaded.first)
        XCTAssertEqual(entry.decision, .confirmed)
        XCTAssertEqual(entry.providerID, Self.providerID)
        XCTAssertEqual(entry.toolID, Self.clearToolID)
        XCTAssertEqual(
            entry.summary, card.sentence,
            "approvedSentence matched end to end — the sentence the card showed is the sentence "
                + "the gate acted on and the log recorded")

        await driver.stop()
        XCTAssertTrue(
            failures.values.isEmpty,
            "the round trip is an answer, never a failure notice")
    }
}