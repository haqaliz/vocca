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

/// The root accessor's box — the `configure` `WeakBox` shape, test-side: weak, so a released
/// root reads `nil` exactly as the shipped `{ rootBox.value }` does. Plain `@unchecked
/// Sendable`, written and read only on the main actor (the suite is `@MainActor`).
private final class WiringRootBox: @unchecked Sendable {
    weak var value: DictationLoopRoot?

    init(_ root: DictationLoopRoot?) {
        self.value = root
    }
}

/// The failure-sink recorder — the same single-threaded box shape as the intent doubles.
private final class RecordingWiringFailureSink: @unchecked Sendable {
    private(set) var values: [ConverseTurnFailure] = []
    func record(_ failure: ConverseTurnFailure) {
        values.append(failure)
    }
}

/// The hand-moved clock, as a **struct** — the driver's init requires `MonotonicClock &
/// Sendable`, and these tests never advance it.
private struct ConverseWiringTestClock: MonotonicClock {
    var now: Duration = .zero
}

// MARK: - The suite

/// **The converse intent closures through the real driver** (`converse-intent-wiring` /
/// `intent-leg-wiring` B8): a scripted `ConverseLoopDriver` over the seam doubles, its two
/// intent slots filled by `AppBootstrap.composeConverseIntentClosures(root:)` over an
/// `IntentRoundTripHarness` root — a phrase table, real temp-directory stores, the real card
/// and audit log. Every assertion reads the **spoken** reply (the ledger's `.speakReply`), the
/// thing a user hears: a read-only hit speaks the wiring's "Done."; a destructive hit speaks
/// exactly "Confirm on screen." — never the echo of the user's words — with the card up; every
/// unwired posture (empty table, disabled tool, no wiring, a released root) and a miss speak the
/// echo exactly as `EchoReplyGenerator` produces it, byte-identical to today.
///
/// ``ConverseIntentClosuresTests`` pins the same behaviour on the closures alone (B1-B7); this
/// suite proves the driver carries it to the speaker. Each test's counterfactual (a production
/// mutation that kills it, checked and reverted) is recorded in the unit's task report.
@MainActor
final class ConverseIntentWiringTests: XCTestCase {

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
            identity: VoiceIdentity(engineID: "converse-wiring-stub-synth", voiceName: nil),
            chunks: [replyChunk])
    }

    /// The shared stub instance the `@Sendable` provider closures capture — an actor, so the
    /// capture is honest.
    nonisolated private static let stubSynthesizer = makeStubSynthesizer()

    private static let providerID = AuditActionProvider.providerID
    private static let clearToolID = AuditActionProvider.clearToolID
    private static let countToolID = AuditActionProvider.countToolID

    private static let clearUtterance = "clear the audit log"
    private static let countUtterance = "count the audit log"
    private static let missUtterance = "what a lovely afternoon"

    /// The two phrase rows every wired test resolves through.
    private static let phraseRows = [
        PhraseIntentRow(phrase: clearUtterance, providerID: providerID, toolID: clearToolID),
        PhraseIntentRow(phrase: countUtterance, providerID: providerID, toolID: countToolID),
    ]

    /// The echo a driver speaks for `utterance` — computed by the shipped default generator,
    /// never spelled by hand, so "byte-identical to today" is a claim about the generator.
    private static func echo(_ utterance: String) -> String {
        EchoReplyGenerator().reply(to: utterance)
    }

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-converse-intent-wiring-\(UUID().uuidString)")
    }

    /// One committed turn's VAD script: listening silence, the 4-frame utterance, the
    /// 8-frame pause (commit).
    private static func turnScript() -> [SpeechActivity] {
        [.silence, .silence] + [SpeechActivity](repeating: .speech, count: 4)
            + [SpeechActivity](repeating: .silence, count: 8)
    }

    /// A harness whose wiring resolves through a phrase table (`rows`) — the composed
    /// default's resolver shape, in memory.
    private func makeHarness<Provider: ActionProvider>(
        directory: URL, provider: Provider, auditStore: FileSystemActionAuditStore,
        rows: [PhraseIntentRow] = ConverseIntentWiringTests.phraseRows
    ) -> IntentRoundTripHarness<Provider> {
        IntentRoundTripHarness(
            directory: directory, provider: provider, auditStore: auditStore,
            resolverProvider: { PhraseIntentResolver(rows: rows) })
    }

    /// The stub wiring's closures in the root slot's concrete type — the
    /// ``ConverseIntentClosuresTests`` rehost: the static reads only `resolve`/`performAction`,
    /// so the copied executor is never reached and the stub's counts stay real.
    private func rehosted<Provider>(
        _ wiring: IntentWiring<Provider>, auditStore: FileSystemActionAuditStore
    ) -> IntentWiring<AuditActionProvider> {
        let unreached = AuditActionProvider(store: auditStore)
        return IntentWiring(
            resolve: wiring.resolve,
            performAction: wiring.performAction,
            executor: ActionExecutor(provider: unreached, store: auditStore),
            policy: wiring.policy,
            spawnsSubprocess: wiring.spawnsSubprocess)
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

    /// Speaks `utterances` as consecutive committed turns through a real driver whose intent
    /// slots are the static's closures over `box`, and returns what the driver spoke.
    /// `afterTurn` runs once each turn's reply has played — the human leg's slot.
    private func speak(
        _ utterances: [String],
        over box: WiringRootBox,
        afterTurn: @MainActor (Int) async -> Void = { _ in },
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> [String] {
        let closures = AppBootstrap.composeConverseIntentClosures(root: { box.value })
        return try await speak(utterances, closures: closures, afterTurn: afterTurn)
    }

    /// The driver run itself, over already-composed closures (the released-root leg composes
    /// them while the root is alive and releases it before the first turn).
    private func speak(
        _ utterances: [String],
        closures: (
            provider: @Sendable (String) async -> IntentResolution?,
            handler: @Sendable (ActionInvocation, String) async -> String?
        ),
        afterTurn: @MainActor (Int) async -> Void = { _ in },
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> [String] {
        let capture = ScriptedContinuousCapture()
        let asr = ScriptedASR(transcripts: utterances)
        let playback = FakePlaybackEngine()
        let failures = RecordingWiringFailureSink()
        let driver = ConverseLoopDriver(
            vad: ScriptedVAD(
                configuration: Self.configuration,
                script: Array(utterances.map { _ in Self.turnScript() }.joined())),
            turnDetector: ScriptedTurnDetector(
                script: Array(utterances.map { _ in Self.commitments }.joined())),
            clock: ConverseWiringTestClock(),
            gate: EchoGate(),
            capture: capture,
            asrProvider: { asr },
            cleanupProvider: { nil },
            intentProvider: closures.provider,
            intentActionHandler: closures.handler,
            replyGenerator: EchoReplyGenerator(),
            synthesizer: { Self.stubSynthesizer },
            playback: playback,
            onStateChange: { _ in },
            failureSink: { failures.record($0) })

        try driver.start()
        for turn in utterances.indices {
            capture.push([TurnLoopFixtures.silence(), TurnLoopFixtures.silence()])
            capture.push([Self.userSpeech, Self.userSpeech, Self.userSpeech, Self.userSpeech])
            for _ in 0..<8 { capture.push([TurnLoopFixtures.silence()]) }
            await waitUntil({ await playback.playCount == turn + 1 }, file: file, line: line)
            await afterTurn(turn)
        }
        await driver.stop()
        XCTAssertTrue(
            failures.values.isEmpty, "every turn is an answer, never a failure notice",
            file: file, line: line)
        return Self.spokenReplies(in: driver.effects)
    }

    // MARK: - (a) read-only → "Done."

    /// **A read-only phrase hit speaks the wiring's ack**: "Done.", audited `autoRanReadOnly`,
    /// no card, the provider invoked once.
    func testAReadOnlyPhraseHitSpeaksDoneAuditedWithNoCard() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.countToolID], describedRadius: .readOnly)
        let harness = makeHarness(directory: directory, provider: provider, auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.countToolID, true)
        harness.root.intentWiring = rehosted(harness.wiring, auditStore: auditStore)

        let spoken = try await speak([Self.countUtterance], over: WiringRootBox(harness.root))

        XCTAssertEqual(spoken, ["Done."], "the wiring's ack is what the user hears")
        XCTAssertNil(harness.root.widgetStore.state.confirmation, "read-only runs, no card")
        XCTAssertEqual(provider.invokeCount, 1)
        let entries = await harness.auditStore.load()
        XCTAssertEqual(entries.map(\.decision), [.autoRanReadOnly])
    }

    // MARK: - (b) destructive → "Confirm on screen."

    /// **A destructive phrase hit speaks the confirm line, never the echo**: the card is up,
    /// nothing is invoked, the stop is recorded.
    func testADestructivePhraseHitSpeaksTheConfirmLineNotTheEcho() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let harness = makeHarness(directory: directory, provider: provider, auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)
        harness.root.intentWiring = rehosted(harness.wiring, auditStore: auditStore)

        let spoken = try await speak([Self.clearUtterance], over: WiringRootBox(harness.root))

        XCTAssertEqual(spoken, ["Confirm on screen."], "the card is waiting — the driver says so")
        XCTAssertNotEqual(
            spoken, [Self.echo(Self.clearUtterance)],
            "a destructive request is never answered with the user's own words")
        XCTAssertNotNil(harness.root.widgetStore.state.confirmation, "the card is the surface")
        XCTAssertEqual(provider.invokeCount, 0, "nothing runs without a human yes")
        let entries = await harness.auditStore.load()
        XCTAssertEqual(entries.map(\.decision), [.refused])
    }

    // MARK: - (c) the default postures → the echo

    /// **An empty phrase table speaks the echo** — the shipped default with no file: the
    /// tool is enabled and the wiring present, and still nothing resolves.
    func testAnEmptyPhraseTableSpeaksTheEchoByteIdentical() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let harness = makeHarness(
            directory: directory, provider: AuditActionProvider(store: auditStore),
            auditStore: auditStore, rows: [])
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)
        harness.root.intentWiring = harness.wiring

        let spoken = try await speak([Self.clearUtterance], over: WiringRootBox(harness.root))

        XCTAssertEqual(spoken, [Self.echo(Self.clearUtterance)], "today's echo, byte-identical")
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        let entries = await harness.auditStore.load()
        XCTAssertTrue(entries.isEmpty, "nothing resolved → nothing submitted → nothing recorded")
    }

    /// **A phrase whose tool is not enabled speaks the echo** — the second half of the two-step
    /// opt-in is missing, so the catalog-gated resolver resolves nothing.
    func testAPhraseWithNoEnabledToolSpeaksTheEcho() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let harness = makeHarness(
            directory: directory, provider: AuditActionProvider(store: auditStore),
            auditStore: auditStore)
        harness.root.intentWiring = harness.wiring

        let spoken = try await speak(
            [Self.clearUtterance, Self.countUtterance], over: WiringRootBox(harness.root))

        XCTAssertEqual(
            spoken, [Self.echo(Self.clearUtterance), Self.echo(Self.countUtterance)],
            "a phrase is not enough — with no enabled tool the driver echoes")
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        let entries = await harness.auditStore.load()
        XCTAssertTrue(entries.isEmpty)
    }

    /// **A root with no intent wiring speaks the echo** — the unwired posture, with the tool
    /// enabled and a phrase that would match.
    func testARootWithNoIntentWiringSpeaksTheEcho() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let harness = makeHarness(
            directory: directory, provider: AuditActionProvider(store: auditStore),
            auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.countToolID, true)
        XCTAssertNil(harness.root.intentWiring, "precondition: the slot is never filled")

        let spoken = try await speak([Self.countUtterance], over: WiringRootBox(harness.root))

        XCTAssertEqual(spoken, [Self.echo(Self.countUtterance)], "no wiring → today's echo")
        let entries = await harness.auditStore.load()
        XCTAssertTrue(entries.isEmpty)
    }

    /// **A released root speaks the echo** — the closures are composed while the root is alive
    /// and wired (a matching phrase, an enabled read-only tool), the root is then released, and
    /// the next turn must not reach it. The wiring in the slot is a second harness's (its
    /// closures capture *that* harness's root), so the slot forms no cycle and the release is
    /// real — asserted, not assumed.
    func testAReleasedRootSpeaksTheEcho() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let donor = makeHarness(
            directory: directory.appendingPathComponent("donor"),
            provider: AuditActionProvider(store: auditStore), auditStore: auditStore)
        try await donor.surface.setToolEnabled(Self.providerID, Self.countToolID, true)

        let box = WiringRootBox(nil)
        let closures: (
            provider: @Sendable (String) async -> IntentResolution?,
            handler: @Sendable (ActionInvocation, String) async -> String?
        )
        do {
            let released = makeHarness(
                directory: directory.appendingPathComponent("released"),
                provider: AuditActionProvider(store: auditStore), auditStore: auditStore)
            released.root.intentWiring = donor.wiring
            box.value = released.root
            closures = AppBootstrap.composeConverseIntentClosures(root: { box.value })
            let live = await closures.provider(Self.countUtterance)
            XCTAssertNotNil(live, "precondition: while alive, the root's wiring resolves the phrase")
        }

        let spoken = try await speak([Self.countUtterance], closures: closures)

        XCTAssertNil(box.value, "precondition: the root was really released")
        XCTAssertEqual(spoken, [Self.echo(Self.countUtterance)], "a released root → the echo")
        // The precondition resolve submitted nothing; only a turn reaching the wiring would.
        let entries = await auditStore.load()
        XCTAssertTrue(entries.isEmpty, "the released root's wiring was never reached")
    }

    // MARK: - (d) a miss → the echo

    /// **A miss with the wiring present speaks the echo** — a fully wired root (both tools
    /// enabled, both phrases) and an utterance no phrase matches.
    func testAMissWithTheWiringPresentSpeaksTheEcho() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let harness = makeHarness(
            directory: directory, provider: AuditActionProvider(store: auditStore),
            auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)
        try await harness.surface.setToolEnabled(Self.providerID, Self.countToolID, true)
        harness.root.intentWiring = harness.wiring

        let spoken = try await speak([Self.missUtterance], over: WiringRootBox(harness.root))

        XCTAssertEqual(spoken, [Self.echo(Self.missUtterance)], "a miss → today's echo")
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        let entries = await harness.auditStore.load()
        XCTAssertTrue(entries.isEmpty)
    }

    /// **A hit the wiring answers with nil and no card speaks the echo** — a read-only run
    /// whose outcome is `.notInvoked`: the handler is reached, nothing is on screen, so the
    /// confirm line would be an instruction the user cannot act on.
    func testAHitAnsweredWithNilAndNoCardSpeaksTheEcho() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.countToolID], describedRadius: .readOnly,
            behavior: .executes(.notInvoked))
        let harness = makeHarness(directory: directory, provider: provider, auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.countToolID, true)
        harness.root.intentWiring = rehosted(harness.wiring, auditStore: auditStore)

        let spoken = try await speak([Self.countUtterance], over: WiringRootBox(harness.root))

        XCTAssertEqual(spoken, [Self.echo(Self.countUtterance)], "no card → never the line")
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        XCTAssertEqual(provider.invokeCount, 1, "the handler was reached — the run happened")
    }

    // MARK: - (e) a second destructive request while the card is up

    /// **A second destructive request while the first card is up speaks the confirm line
    /// again** — still exactly one card (the first, untouched), the audit unchanged.
    func testASecondDestructiveRequestWhileTheCardIsUpSpeaksTheLineAgain() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let provider = RecordingActionProvider(
            toolIDs: [Self.clearToolID], describedRadius: .destructive)
        let harness = makeHarness(directory: directory, provider: provider, auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)
        harness.root.intentWiring = rehosted(harness.wiring, auditStore: auditStore)

        var firstGeneration: Int?
        var entriesAfterFirst: [ActionAuditDecision] = []
        let spoken = try await speak(
            [Self.clearUtterance, Self.clearUtterance], over: WiringRootBox(harness.root),
            afterTurn: { turn in
                guard turn == 0 else { return }
                firstGeneration = harness.root.widgetStore.state.confirmation?.signal.generation
                entriesAfterFirst = await harness.auditStore.load().map(\.decision)
            })

        XCTAssertEqual(
            spoken, ["Confirm on screen.", "Confirm on screen."],
            "a card is still waiting — the driver says so again")
        XCTAssertNotNil(firstGeneration, "precondition: the first turn put a card up")
        XCTAssertEqual(
            harness.root.widgetStore.state.confirmation?.signal.generation, firstGeneration,
            "exactly one card — the first, untouched")
        let entries = await harness.auditStore.load().map(\.decision)
        XCTAssertEqual(entries, entriesAfterFirst, "the card-up refusal records nothing")
        XCTAssertEqual(entries, [.refused])
        XCTAssertEqual(provider.invokeCount, 0)
    }

    // MARK: - (f) the line is not sticky

    /// **After the card is confirmed the next turn behaves normally** — over the real
    /// `AuditActionProvider` (both tools, one provider): the destructive hit speaks the line,
    /// the human confirms through the surface's own closure, then a read-only hit speaks
    /// "Done." and a miss speaks the echo.
    func testAfterTheCardIsConfirmedTheNextTurnsBehaveNormally() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let harness = makeHarness(
            directory: directory, provider: AuditActionProvider(store: auditStore),
            auditStore: auditStore)
        try await harness.surface.setToolEnabled(Self.providerID, Self.clearToolID, true)
        try await harness.surface.setToolEnabled(Self.providerID, Self.countToolID, true)
        harness.root.intentWiring = harness.wiring

        let spoken = try await speak(
            [Self.clearUtterance, Self.countUtterance, Self.missUtterance],
            over: WiringRootBox(harness.root),
            afterTurn: { turn in
                guard turn == 0 else { return }
                XCTAssertNotNil(harness.root.widgetStore.state.confirmation, "the card is up")
                await harness.surface.confirm()
                XCTAssertNil(harness.root.widgetStore.state.confirmation, "the human said yes")
            })

        XCTAssertEqual(
            spoken, ["Confirm on screen.", "Done.", Self.echo(Self.missUtterance)],
            "the confirm line belongs to the card — once it is answered, turns are normal again")
        XCTAssertNil(harness.root.widgetStore.state.confirmation)
        let entries = await harness.auditStore.load().map(\.decision)
        XCTAssertEqual(
            entries, [.confirmed, .autoRanReadOnly],
            "the clear ran (its own record lands after it), then the count auto-ran")
    }
}
