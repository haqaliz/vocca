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
import VoccaText
import XCTest

/// The BYOK cleanup provider's contract (spec B1–B8): rung 3 of the cleanup ladder behind the
/// ``LLMTransport`` seam and the ``KeyProvider`` seam (`ROADMAP.md:120`), driven headlessly over
/// ``StubLLMTransport``'s recorded-request ledger and a ``StubKeyProvider``.
///
/// The provider is the first Security-adjacent code in the repo, and it is executed by nothing
/// that touches a real Keychain or a real network in CI — the stubs stand in, and the real BYOK
/// run is a founder smoke step (`root-wiring` M10). So the decisions are tested here: the key read
/// through the injected seam (absent ⇒ throw, never a prompt or a silent skip), the request shape
/// (OpenAI-compatible chat completions with `Authorization: Bearer <key>`), the happy path, the
/// 401/403 ⇒ ``LLMProviderError/unauthorized`` mapping (a wrong key is a user error, never a
/// retry), and — the unit's sharpest edge — the key-hygiene sweep: the sentinel key rides the
/// wire (the request header, asserted) and appears in none of the thrown errors' descriptions.
///
/// Every path throws so the cleanup chain can degrade to the rules output rather than truncate.
/// Transport failures pass through unreinterpreted except 401/403, which the provider maps
/// distinctly; a body that is not a chat-completions shape is ``LLMProviderError/malformedResponse``,
/// an empty or whitespace-only decoded answer is ``LLMProviderError/emptyResponse``.
final class BYOKCleanupProviderTests: XCTestCase {

    // MARK: - B1: identity, network, budget

    /// **B1 — the provider names itself.** The machine key is `"byok-cleanup"`, the name
    /// ``ProviderIdentity`` documentation reserves (`ProviderIdentity.swift:31`); the display name
    /// is for humans; and the identity's `Hashable` equality holds against a hand-built value with
    /// the same key — the attribution is stable.
    func testTheProviderNamesItselfByokCleanup() {
        let provider = Self.makeProvider(
            key: Self.sentinel, transport: StubLLMTransport(mode: .happyPath(response: Self.happyResponse)))

        XCTAssertEqual(
            provider.identity.id, "byok-cleanup",
            "the machine key is the name ProviderIdentity.swift:31 reserves for the BYOK provider")
        XCTAssertEqual(
            provider.identity.displayName, "BYOK",
            "the display name is the human-readable label a log or a settings row shows")
        XCTAssertEqual(
            provider.identity, ProviderIdentity(id: "byok-cleanup", displayName: "BYOK"),
            "the identity is a stable value — Hashable equality against the reserved key")
    }

    /// **B1 — the provider declares the network.** A BYOK cleanup sends the transcript to the
    /// user's own cloud endpoint, so `requiresNetwork` is **declared** `true` (the egress hook
    /// `ARCHITECTURE.md:275` — the UI badges the point of use), not inherited.
    func testTheProviderDeclaresNetworkTrue() {
        let provider = Self.makeProvider(
            key: Self.sentinel, transport: StubLLMTransport(mode: .happyPath(response: Self.happyResponse)))

        XCTAssertTrue(
            provider.requiresNetwork,
            "a BYOK round-trip sends text off the device — the provider declares the egress")
    }

    /// **B1 — the provider declares its five-second budget.** An LLM round-trip needs seconds,
    /// declared here (`prd.md` M1); the caller races the declared number and routes a slow
    /// provider to raw.
    func testTheProviderDeclaresAFiveSecondBudget() {
        let provider = Self.makeProvider(
            key: Self.sentinel, transport: StubLLMTransport(mode: .happyPath(response: Self.happyResponse)))

        XCTAssertEqual(
            provider.budget, .seconds(5),
            "the provider declares the seconds an LLM round-trip may take — declared, not defaulted")
    }

    // MARK: - B2: request shape over the stub's ledger

    /// **B2 — the request posts to the configured endpoint with the chat-completions body.** The
    /// recorded request carries the endpoint verbatim, the `POST` method, the JSON content type,
    /// the `Authorization: Bearer <key>` header, and a body that decodes to `{model, messages}` —
    /// the system message is the pinned ``CleanupPrompts/byokSystem`` instruction, the user message
    /// the transcript verbatim.
    func testTheRequestPostsToTheEndpointWithTheChatCompletionsBodyShape() async throws {
        let sentinel = Self.sentinel
        let stub = StubLLMTransport(mode: .happyPath(response: Self.happyResponse))
        let provider = Self.makeProvider(key: sentinel, transport: stub)

        _ = try await provider.clean(Self.transcript, context: Self.context())

        let recorded = await stub.recordedRequests
        XCTAssertEqual(recorded.count, 1, "one clean call records exactly one request")
        let sent = try XCTUnwrap(recorded.first)

        XCTAssertEqual(
            sent.url, Self.endpoint,
            "the provider posts to the configured endpoint verbatim — the v1 chat-completions contract")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        XCTAssertEqual(
            sent.headers["Authorization"], "Bearer \(sentinel)",
            "the key rides the wire in the Authorization header — the one place it may appear")

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: sent.body) as? [String: Any],
            "the request body must decode as a JSON object")
        XCTAssertEqual(json["model"] as? String, Self.model)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2, "one system instruction plus one user transcript")
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(
            messages[0]["content"] as? String, CleanupPrompts.byokSystem,
            "the system message is the pinned BYOK instruction")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, Self.transcriptText)
    }

    /// **B2 — a nil model omits the `model` field.** Some endpoints default their own model; the
    /// v1 contract documents that `model == nil` omits the field rather than sending an empty one.
    func testANilModelOmitsTheModelField() async throws {
        let stub = StubLLMTransport(mode: .happyPath(response: Self.happyResponse))
        let provider = BYOKCleanupProvider(
            endpoint: Self.endpoint,
            model: nil,
            keyProvider: StubKeyProvider(mode: .returns(Self.sentinel)),
            transport: stub)

        _ = try await provider.clean(Self.transcript, context: Self.context())

        let recorded = await stub.recordedRequests
        let sent = try XCTUnwrap(recorded.first)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertNil(
            json["model"],
            "a nil model must omit the field — some endpoints default, and an empty string is not that")
    }

    // MARK: - B3: happy path

    /// **B3 — a chat-completions answer yields `choices[0].message.content`.** The provider
    /// returns exactly what the server answered; the caller injects it.
    func testTheHappyPathReturnsTheCleanedContent() async throws {
        let stub = StubLLMTransport(mode: .happyPath(response: Self.happyResponse))
        let provider = Self.makeProvider(key: Self.sentinel, transport: stub)

        let cleaned = try await provider.clean(Self.transcript, context: Self.context())

        XCTAssertEqual(cleaned, "cleaned text")
    }

    // MARK: - B4: key absent

    /// **B4 — a missing key throws `keyUnavailable` and no request is recorded.** Absent is a
    /// first-class outcome (never a prompt, never a silent skip) and the transport is never
    /// reached — nothing to retry.
    func testAMissingKeyThrowsKeyUnavailableWithoutARecordedRequest() async {
        let stub = StubLLMTransport(mode: .happyPath(response: Self.happyResponse))
        let provider = BYOKCleanupProvider(
            endpoint: Self.endpoint,
            model: Self.model,
            keyProvider: StubKeyProvider(mode: .returnsNil),
            transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a missing key must throw")
        } catch LLMProviderError.keyUnavailable {
            let recorded = await stub.recordedRequests
            XCTAssertEqual(recorded.count, 0, "the transport must never be reached for a missing key")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - B5: keyProvider throws

    /// **B5 — a throwing key provider rethrows, and no request is recorded.** The seam's own
    /// failure (a locked or unreadable Keychain) passes through unreinterpreted — the provider
    /// does not invent a key-free vocabulary for someone else's failure.
    func testAThrowingKeyProviderRethrowsWithoutARecordedRequest() async {
        let stub = StubLLMTransport(mode: .happyPath(response: Self.happyResponse))
        let provider = BYOKCleanupProvider(
            endpoint: Self.endpoint,
            model: Self.model,
            keyProvider: StubKeyProvider(mode: .throwsLocked),
            transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a throwing key provider must throw")
        } catch StubKeyProviderError.locked {
            let recorded = await stub.recordedRequests
            XCTAssertEqual(recorded.count, 0, "the transport must never be reached for a throwing key")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - B6: 401/403 are first-class, never a retry

    /// **B6 — a 401 maps to `unauthorized`.** A rejected key is a user error; the provider names
    /// it distinctly (never a generic serverStatus), sends exactly one request — no retry loop
    /// hammering the user's endpoint — and the error carries no key.
    func testA401MapsToUnauthorizedWithNoRetry() async {
        await Self.assertUnauthorized(statusCode: 401)
    }

    /// **B6 — a 403 maps to `unauthorized`.** Same mapping, same no-retry rule.
    func testA403MapsToUnauthorizedWithNoRetry() async {
        await Self.assertUnauthorized(statusCode: 403)
    }

    // MARK: - B7: every other failure mode throws

    /// **B7 — an unreachable transport throws, passed through unreinterpreted.** The provider
    /// never swallows a transport failure into a partial string; the chain's degrade decision
    /// needs the throw to happen.
    func testAnUnreachableTransportThrows() async {
        let stub = StubLLMTransport(mode: .failsUnreachable)
        let provider = Self.makeProvider(key: Self.sentinel, transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("an unreachable transport must throw")
        } catch LLMTransportError.unreachable {
            // the transport's own vocabulary passes through — the provider does not reinterpret it
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B7 — a 500 server status passes through.** Only 401/403 are the key's rejection; a 500 is
    /// the service's failure and stays `serverStatus(500)`.
    func testAServerStatus500ThrowsPassesThrough() async {
        let stub = StubLLMTransport(mode: .serverStatus(500))
        let provider = Self.makeProvider(key: Self.sentinel, transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a server status must throw")
        } catch LLMTransportError.serverStatus(500) {
            // passed through verbatim, code intact — not mapped to unauthorized
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B7 — a malformed transport response throws.** A transport-level `invalidResponse`
    /// (non-HTTP, undecodable) passes through unreinterpreted.
    func testAMalformedTransportResponseThrows() async {
        let stub = StubLLMTransport(mode: .malformedResponse)
        let provider = Self.makeProvider(key: Self.sentinel, transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a malformed transport response must throw")
        } catch LLMTransportError.invalidResponse {
            // passed through — the transport's answer, not the provider's invention
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B7 — a body that is not JSON throws `malformedResponse`.**
    func testAMalformedJsonBodyThrowsMalformedResponse() async {
        let stub = StubLLMTransport(mode: .happyPath(response: LLMResponse(
            statusCode: 200, body: Data("not json".utf8))))
        let provider = Self.makeProvider(key: Self.sentinel, transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a malformed JSON body must throw")
        } catch LLMProviderError.malformedResponse {
            // expected — the body is not a JSON object
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B7 — a body with no `choices` entry throws `malformedResponse`.** The contract's key —
    /// `choices[0].message.content` — is absent, so the answer is malformed, never an empty string.
    func testAMissingChoicesKeyThrowsMalformedResponse() async {
        let stub = StubLLMTransport(mode: .happyPath(response: LLMResponse(
            statusCode: 200, body: Data(#"{"foo":"bar"}"#.utf8))))
        let provider = Self.makeProvider(key: Self.sentinel, transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a body without choices must throw")
        } catch LLMProviderError.malformedResponse {
            // expected — the choices key is the contract, and it is absent
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B7 — an empty `choices` array throws `malformedResponse`.** The JSON decodes but the
    /// contract names `choices[0]`; an empty array is no answer.
    func testAnEmptyChoicesArrayThrowsMalformedResponse() async {
        let stub = StubLLMTransport(mode: .happyPath(response: LLMResponse(
            statusCode: 200, body: Data(#"{"choices":[]}"#.utf8))))
        let provider = Self.makeProvider(key: Self.sentinel, transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("an empty choices array must throw")
        } catch LLMProviderError.malformedResponse {
            // expected — choices[0] is the contract, and it is absent
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B7 — an empty decoded content throws `emptyResponse`.** `{"content": ""}` is a
    /// well-formed answer with nothing to inject — a typed throw, never a partial string.
    func testAnEmptyDecodedContentThrowsEmptyResponse() async {
        let stub = StubLLMTransport(mode: .happyPath(response: LLMResponse(
            statusCode: 200, body: Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8))))
        let provider = Self.makeProvider(key: Self.sentinel, transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("an empty content must throw")
        } catch LLMProviderError.emptyResponse {
            // expected — nothing to inject, and the caller decides the degrade
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B7 — a whitespace-only decoded content throws `emptyResponse`.** Whitespace is emptiness
    /// for the injector's purposes; the provider says so rather than returning `"   "`.
    func testAWhitespaceOnlyContentThrowsEmptyResponse() async {
        let stub = StubLLMTransport(mode: .happyPath(response: LLMResponse(
            statusCode: 200, body: Data(#"{"choices":[{"message":{"content":"   \n"}}]}"#.utf8))))
        let provider = Self.makeProvider(key: Self.sentinel, transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a whitespace-only content must throw")
        } catch LLMProviderError.emptyResponse {
            // expected — whitespace is emptiness for the injector
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - B8: key hygiene

    /// **B8 — the sentinel key rides the wire and none of the failure surface repeats it.** The
    /// key appears in the happy-path request's `Authorization` header — the one place it is
    /// *supposed* to be — and in **none** of the thrown errors' descriptions across every failure
    /// path. The provider never logs; the loggable surface is the errors a caller can print, so
    /// the sweep is over `String(describing:)` and `localizedDescription` of every thrown error,
    /// asserted complete over the closed set of failure paths.
    func testTheSentinelKeyNeverAppearsInAnyErrorDescriptionAcrossEveryFailurePath() async {
        let sentinel = "SENTINEL-\(UUID().uuidString)"

        let failurePaths: [(label: String, provider: BYOKCleanupProvider)] = [
            ("keyAbsent",
                BYOKCleanupProvider(
                    endpoint: Self.endpoint, model: Self.model,
                    keyProvider: StubKeyProvider(mode: .returnsNil),
                    transport: StubLLMTransport(mode: .happyPath(response: Self.happyResponse)))),
            ("keyThrows",
                BYOKCleanupProvider(
                    endpoint: Self.endpoint, model: Self.model,
                    keyProvider: StubKeyProvider(mode: .throwsLocked),
                    transport: StubLLMTransport(mode: .happyPath(response: Self.happyResponse)))),
            ("unreachable",
                Self.makeProvider(key: sentinel, transport: StubLLMTransport(mode: .failsUnreachable))),
            ("unauthorized401",
                Self.makeProvider(key: sentinel, transport: StubLLMTransport(mode: .serverStatus(401)))),
            ("unauthorized403",
                Self.makeProvider(key: sentinel, transport: StubLLMTransport(mode: .serverStatus(403)))),
            ("serverStatus500",
                Self.makeProvider(key: sentinel, transport: StubLLMTransport(mode: .serverStatus(500)))),
            ("malformedTransport",
                Self.makeProvider(key: sentinel, transport: StubLLMTransport(mode: .malformedResponse))),
            ("malformedBody",
                Self.makeProvider(
                    key: sentinel,
                    transport: StubLLMTransport(mode: .happyPath(response: LLMResponse(
                        statusCode: 200, body: Data("not json".utf8)))))),
            ("missingChoices",
                Self.makeProvider(
                    key: sentinel,
                    transport: StubLLMTransport(mode: .happyPath(response: LLMResponse(
                        statusCode: 200, body: Data(#"{"choices":[]}"#.utf8)))))),
            ("emptyContent",
                Self.makeProvider(
                    key: sentinel,
                    transport: StubLLMTransport(mode: .happyPath(response: LLMResponse(
                        statusCode: 200, body: Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8)))))),
            ("whitespaceContent",
                Self.makeProvider(
                    key: sentinel,
                    transport: StubLLMTransport(mode: .happyPath(response: LLMResponse(
                        statusCode: 200, body: Data(#"{"choices":[{"message":{"content":"  \n"}}]}"#.utf8)))))),
        ]

        for path in failurePaths {
            let (string, localized) = await Self.captureError {
                try await path.provider.clean(Self.transcript, context: Self.context())
            }
            XCTAssertFalse(
                string.isEmpty,
                "\(path.label) must throw — a silent pass would leave the sweep incomplete")
            XCTAssertFalse(
                string.contains(sentinel),
                "\(path.label): String(describing:) leaked the key — \(string)")
            XCTAssertFalse(
                localized.contains(sentinel),
                "\(path.label): localizedDescription leaked the key — \(localized)")
        }

        // The wire half: the happy-path request header carries the key, asserted here so the sweep
        // above is a real prohibition and not the vacuous one (the key absent everywhere, request
        // included) that would pass a one-sided check.
        let stub = StubLLMTransport(mode: .happyPath(response: Self.happyResponse))
        let provider = Self.makeProvider(key: sentinel, transport: stub)
        _ = try? await provider.clean(Self.transcript, context: Self.context())
        let recorded = await stub.recordedRequests
        XCTAssertEqual(
            recorded.first?.headers["Authorization"], "Bearer \(sentinel)",
            "the key must ride the wire — the point of B8 is the logs and errors, not the header")
    }

    // MARK: - Fixtures

    /// A unique sentinel key, fresh per process — the key-hygiene sweeps key on its absence.
    private static let sentinel = "SENTINEL-\(UUID().uuidString)"

    /// The BYOK endpoint a test provider is configured with — a fake chat-completions address.
    private static let endpoint = URL(string: "https://api.example.com/v1/chat/completions")!

    /// The model a test provider is configured with.
    private static let model = "gpt-4o-mini"

    /// The canonical transcript text a test provider cleans.
    private static let transcriptText = "um so like we need to ship this period"

    /// A 200 answer carrying `choices[0].message.content == "cleaned text"` — the happy path's fixture.
    private static let happyResponse = LLMResponse(
        statusCode: 200,
        body: Data(#"{"choices":[{"message":{"role":"assistant","content":"cleaned text"}}]}"#.utf8))

    /// Builds the provider under test over an injected key and transport.
    private static func makeProvider(
        key: String,
        transport: any LLMTransport
    ) -> BYOKCleanupProvider {
        BYOKCleanupProvider(
            endpoint: endpoint,
            model: model,
            keyProvider: StubKeyProvider(mode: .returns(key)),
            transport: transport)
    }

    /// The transcript the provider cleans, over the probe-stub engine identity.
    private static let transcript = Transcript(
        text: transcriptText,
        segments: [],
        engine: EngineIdentity(
            id: "probe-stub-engine", displayName: "Probe stub engine", isLocal: true),
        isFinal: true,
        audioDuration: 1.0)

    /// The dictation-mode context the pipeline hands a provider.
    private static func context() -> CleanupContext {
        CleanupContext(
            target: TargetContext(
                bundleID: "com.example.Notes", windowTitle: "Notes - The Draft",
                isSecureInput: false),
            mode: .dictation,
            dictionary: [],
            budget: .seconds(5))
    }

    /// Runs `clean` and captures the thrown error's two printable forms — or two empty strings if
    /// it does not throw, so the caller can fail the sweep as incomplete.
    private static func captureError(
        _ body: () async throws -> String
    ) async -> (string: String, localized: String) {
        do {
            _ = try await body()
            return ("", "")
        } catch {
            return (String(describing: error), error.localizedDescription)
        }
    }

    /// B6's shared body: a 401 or 403 maps to `unauthorized` with exactly one request and no key
    /// in the error description.
    private static func assertUnauthorized(statusCode: Int) async {
        let sentinel = Self.sentinel
        let stub = StubLLMTransport(mode: .serverStatus(statusCode))
        let provider = Self.makeProvider(key: sentinel, transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a \(statusCode) must throw")
        } catch LLMProviderError.unauthorized {
            let recorded = await stub.recordedRequests
            XCTAssertEqual(
                recorded.count, 1,
                "a rejected key is never retried — exactly one request, the one that was rejected")
            let (string, localized) = await Self.captureError {
                try await provider.clean(Self.transcript, context: Self.context())
            }
            XCTAssertFalse(string.contains(sentinel), "String(describing:) leaked the key: \(string)")
            XCTAssertFalse(
                localized.contains(sentinel),
                "localizedDescription leaked the key: \(localized)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

/// The key-seam double the BYOK tests drive: configurable return/throw, never a real Keychain.
///
/// `KeyProvider` is ``Sendable``; the stub is a final class over an immutable ``Mode`` so the
/// conformance holds at compile time (the same pin the transport test applies to its existential).
private final class StubKeyProvider: KeyProvider {
    /// What a `key()` call may do.
    enum Mode: Sendable {
        /// Return `key` — the happy path (and the wire half of the key-hygiene sweep).
        case returns(String)
        /// Return nil — the key is absent from the Keychain.
        case returnsNil
        /// Throw ``StubKeyProviderError/locked`` — the Keychain is locked or unreadable.
        case throwsLocked
    }

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func key() throws -> String? {
        switch mode {
        case .returns(let key):
            return key
        case .returnsNil:
            return nil
        case .throwsLocked:
            throw StubKeyProviderError.locked
        }
    }
}

/// The one failure the stub's key seam can name — the B5 rethrow's distinct marker.
private enum StubKeyProviderError: Error, Sendable {
    case locked
}
