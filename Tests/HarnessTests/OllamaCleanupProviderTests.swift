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

/// The Ollama cleanup provider's contract (spec B1–B5): rung 2 of the cleanup ladder behind the
/// ``LLMTransport`` seam (`ROADMAP.md:119`), driven headlessly over ``StubLLMTransport``'s
/// recorded-request ledger.
///
/// The provider is executed by nothing that dials real network in CI — the stub stands in, and the
/// real Ollama run is a founder smoke step (`root-wiring` M10). So the decisions are tested here:
/// request shaping (`/api/generate`, the JSON body, the pinned prompt prefix), the happy path, and
/// every failure mode throwing honestly so the chain (`cleanup-chain`) can degrade to the rules
/// output rather than truncate.
///
/// Transport failures pass through unreinterpreted — the provider maps only what *it* decides:
/// a body that is not a `{"response": String}` object is ``LLMProviderError/malformedResponse``,
/// an empty or whitespace-only decoded response is ``LLMProviderError/emptyResponse``.
final class OllamaCleanupProviderTests: XCTestCase {

    // MARK: - B1: identity, network, budget

    /// **B1 — the provider names itself.** The machine key is `"ollama-cleanup"`, the name
    /// ``ProviderIdentity`` documentation reserves (`ProviderIdentity.swift:31`); the display name
    /// is for humans; and the identity's `Hashable` equality holds against a hand-built value with
    /// the same key — the attribution is stable.
    func testTheProviderNamesItselfOllamaCleanup() {
        let provider = Self.makeProvider(transport: StubLLMTransport(
            mode: .happyPath(response: Self.happyResponse)))

        XCTAssertEqual(
            provider.identity.id, "ollama-cleanup",
            "the machine key is the name ProviderIdentity.swift:31 reserves for the Ollama provider")
        XCTAssertEqual(
            provider.identity.displayName, "Ollama",
            "the display name is the human-readable label a log or a settings row shows")
        XCTAssertEqual(
            provider.identity, ProviderIdentity(id: "ollama-cleanup", displayName: "Ollama"),
            "the identity is a stable value — Hashable equality against the reserved key")
    }

    /// **B1 — the provider declares the network.** Sending a transcript to a local Ollama server
    /// still sends text off the process, so `requiresNetwork` is **declared** `true` (the egress
    /// hook `ARCHITECTURE.md:275` — the UI badges the point of use), not inherited.
    func testTheProviderDeclaresNetworkTrue() {
        let provider = Self.makeProvider(transport: StubLLMTransport(
            mode: .happyPath(response: Self.happyResponse)))

        XCTAssertTrue(
            provider.requiresNetwork,
            "an LLM round-trip sends text off the process — the provider declares the egress")
    }

    /// **B1 — the provider declares its five-second budget.** An LLM round-trip needs seconds,
    /// declared here (`prd.md` M1, the N1 deferral makes it non-configurable); the caller races the
    /// declared number and routes a slow provider to raw.
    func testTheProviderDeclaresAFiveSecondBudget() {
        let provider = Self.makeProvider(transport: StubLLMTransport(
            mode: .happyPath(response: Self.happyResponse)))

        XCTAssertEqual(
            provider.budget, .seconds(5),
            "the provider declares the seconds an LLM round-trip may take — declared, not defaulted")
    }

    // MARK: - B2: request shape over the stub's ledger

    /// **B2 — the request posts to `/api/generate` with the JSON body shape.** The recorded request
    /// carries the endpoint path, the `POST` method, the `Content-Type: application/json` header,
    /// and a body that decodes to `{model, prompt, stream: false}` — the transcript inside the
    /// prompt, and the prompt beginning with the pinned instruction.
    func testTheRequestPostsToTheGenerateEndpointWithTheJsonBodyShape() async throws {
        let stub = StubLLMTransport(mode: .happyPath(response: Self.happyResponse))
        let provider = Self.makeProvider(transport: stub)

        _ = try await provider.clean(Self.transcript, context: Self.context())

        let recorded = await stub.recordedRequests
        XCTAssertEqual(recorded.count, 1, "one clean call records exactly one request")
        let sent = try XCTUnwrap(recorded.first)

        XCTAssertEqual(
            sent.url, Self.endpoint.appendingPathComponent("api/generate"),
            "the provider posts to the endpoint's /api/generate path")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: sent.body) as? [String: Any],
            "the request body must decode as a JSON object")
        XCTAssertEqual(json["model"] as? String, Self.model)
        XCTAssertEqual(json["stream"] as? Bool, false, "stream must be false — a batch completion")
        let prompt = try XCTUnwrap(json["prompt"] as? String)
        XCTAssertTrue(
            prompt.hasPrefix(CleanupPrompts.ollama),
            "the prompt begins with the pinned cleanup-not-creativity instruction")
        XCTAssertTrue(
            prompt.contains(Self.transcriptText),
            "the transcript is in the prompt, verbatim")
    }

    // MARK: - B3: happy path

    /// **B3 — a `{"response": "cleaned text"}` answer yields the cleaned text.** The provider
    /// returns exactly what the server answered; the caller injects it.
    func testTheHappyPathReturnsTheCleanedResponse() async throws {
        let stub = StubLLMTransport(mode: .happyPath(response: Self.happyResponse))
        let provider = Self.makeProvider(transport: stub)

        let cleaned = try await provider.clean(Self.transcript, context: Self.context())

        XCTAssertEqual(cleaned, "cleaned text")
    }

    // MARK: - B4: every failure mode throws

    /// **B4 — an unreachable transport throws, passed through unreinterpreted.** The provider never
    /// swallows a transport failure into a partial string; the chain's degrade decision needs the
    /// throw to happen.
    func testAnUnreachableTransportThrows() async {
        let stub = StubLLMTransport(mode: .failsUnreachable)
        let provider = Self.makeProvider(transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("an unreachable transport must throw")
        } catch LLMTransportError.unreachable {
            // the transport's own vocabulary passes through — the provider does not reinterpret it
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B4 — a server status throw passes through.** A non-2xx answer surfaces as
    /// `LLMTransportError.serverStatus`; the provider does not reinterpret it (body-less by the
    /// seam's contract).
    func testAServerStatusTransportThrowPassesThrough() async {
        let stub = StubLLMTransport(mode: .serverStatus(500))
        let provider = Self.makeProvider(transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a server status throw must throw")
        } catch LLMTransportError.serverStatus(500) {
            // passed through verbatim, code intact
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B4 — a malformed transport response throws.** A transport-level `invalidResponse`
    /// (non-HTTP, undecodable) passes through unreinterpreted.
    func testAMalformedTransportResponseThrows() async {
        let stub = StubLLMTransport(mode: .malformedResponse)
        let provider = Self.makeProvider(transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a malformed transport response must throw")
        } catch LLMTransportError.invalidResponse {
            // passed through — the transport's answer, not the provider's invention
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B4 — a body that is not JSON throws `malformedResponse`.** The provider's parse decision:
    /// an undecodable body is the provider's to name.
    func testAMalformedJsonBodyThrowsMalformedResponse() async {
        let stub = StubLLMTransport(mode: .happyPath(response: LLMResponse(
            statusCode: 200, body: Data("not json".utf8))))
        let provider = Self.makeProvider(transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a malformed JSON body must throw")
        } catch LLMProviderError.malformedResponse {
            // expected — the body is not a JSON object
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B4 — a body missing the `response` key throws `malformedResponse`.** A JSON object without
    /// the one key the contract names is a malformed answer, never an empty string.
    func testAMissingResponseKeyThrowsMalformedResponse() async {
        let stub = StubLLMTransport(mode: .happyPath(response: LLMResponse(
            statusCode: 200, body: Data(#"{"foo":"bar"}"#.utf8))))
        let provider = Self.makeProvider(transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a body without the response key must throw")
        } catch LLMProviderError.malformedResponse {
            // expected — the response key is the contract, and it is absent
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B4 — an empty decoded response throws `emptyResponse`.** `{"response": ""}` is a
    /// well-formed answer with nothing to inject — a typed throw, never a partial string.
    func testAnEmptyDecodedResponseThrowsEmptyResponse() async {
        let stub = StubLLMTransport(mode: .happyPath(response: LLMResponse(
            statusCode: 200, body: Data(#"{"response":""}"#.utf8))))
        let provider = Self.makeProvider(transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("an empty response must throw")
        } catch LLMProviderError.emptyResponse {
            // expected — nothing to inject, and the caller decides the degrade
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// **B4 — a whitespace-only decoded response throws `emptyResponse`.** Whitespace is emptiness
    /// for the injector's purposes; the provider says so rather than returning `"   "`.
    func testAWhitespaceOnlyResponseThrowsEmptyResponse() async {
        let stub = StubLLMTransport(mode: .happyPath(response: LLMResponse(
            statusCode: 200, body: Data(#"{"response":"   \n"}"#.utf8))))
        let provider = Self.makeProvider(transport: stub)

        do {
            _ = try await provider.clean(Self.transcript, context: Self.context())
            XCTFail("a whitespace-only response must throw")
        } catch LLMProviderError.emptyResponse {
            // expected — whitespace is emptiness for the injector
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - B5: prompt byte-fidelity

    /// **B5 — the Ollama prompt is pinned byte-for-byte.** The cleanup-not-creativity instruction
    /// is a shipped constant (`CleanupPrompts.ollama`); the copy-family discipline pins the exact
    /// text so review adjusts one string, not the logic.
    func testTheOllamaPromptIsPinnedByteForByte() {
        XCTAssertEqual(
            CleanupPrompts.ollama,
            "You are a dictation cleanup assistant. Rewrite the dictated text into clean, "
                + "correctly punctuated prose. Preserve the meaning, names, code identifiers, "
                + "numbers, and spelling exactly. Remove fillers and stumbles. Output only the "
                + "cleaned text with no preamble or explanation.")
    }

    /// **B5 — the BYOK system prompt is pinned byte-for-byte.** The remote-service variant shares
    /// the cleanup core with ``CleanupPrompts.ollama`` but frames it as the service's role; the
    /// `byok-provider` aspect imports it rather than redefining it.
    func testTheByokSystemPromptIsPinnedByteForByte() {
        XCTAssertEqual(
            CleanupPrompts.byokSystem,
            "You are a dictation cleanup service. Rewrite the dictated text into clean, "
                + "correctly punctuated prose. Preserve the meaning, names, code identifiers, "
                + "numbers, and spelling exactly. Remove fillers and stumbles. Output only the "
                + "cleaned text with no preamble or explanation.")
    }

    // MARK: - Fixtures

    /// The Ollama endpoint a test provider is configured with — the default local address.
    private static let endpoint = URL(string: "http://localhost:11434")!

    /// The model a test provider is configured with.
    private static let model = "llama3.1"

    /// The canonical transcript text a test provider cleans.
    private static let transcriptText = "um so like we need to ship this period"

    /// A 200 answer carrying `{"response": "cleaned text"}` — the happy path's fixture.
    private static let happyResponse = LLMResponse(
        statusCode: 200, body: Data(#"{"response":"cleaned text"}"#.utf8))

    /// Builds the provider under test over an injected transport.
    private static func makeProvider(transport: any LLMTransport) -> OllamaCleanupProvider {
        OllamaCleanupProvider(endpoint: endpoint, model: model, transport: transport)
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
}
