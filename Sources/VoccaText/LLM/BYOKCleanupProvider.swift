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

/// Rung 3 of the cleanup ladder (`ROADMAP.md:120`): the user's own cloud endpoint, behind the
/// ``LLMTransport`` seam, the ``KeyProvider`` seam and the ``CleanupProvider`` seam, with egress
/// **declared** (`requiresNetwork = true` — the UI badges the point of use) and a declared 5 s
/// budget (`prd.md` M1).
///
/// The provider owns every decision the transport must not: it reads the key through the injected
/// ``KeyProvider`` (absent ⇒ ``LLMProviderError/keyUnavailable`` — never a prompt, never a silent
/// skip), shapes the OpenAI-compatible chat-completions request (the v1 contract, `prd.md` Risks:
/// `{ "model": …, "messages": [system, user] }` with `Authorization: Bearer <key>`), calls the
/// injected transport, parses `choices[0].message.content`, and maps a bad body onto
/// ``LLMProviderError``. **401/403 is a first-class outcome, not a retry trigger** — a wrong key
/// is a user error, and a retry loop would hammer the user's endpoint — so those two statuses map
/// to ``LLMProviderError/unauthorized`` and every other transport failure passes through
/// unreinterpreted. Every throw degrades to the rules output in the chain (`cleanup-chain`),
/// never a partial string.
///
/// The key never appears in an error or a log: the ``LLMTransportError`` seam keeps bodies out of
/// errors by contract, the provider's own errors are key-free vocabulary, and only the wire (the
/// `Authorization` header) carries the key — asserted by the key-hygiene acceptance (B8).
///
/// This type is executed by nothing in CI that dials real network or a real Keychain — the stub
/// transport and a ``StubKeyProvider`` stand in for every test, and the real BYOK run is a
/// founder smoke step (`root-wiring` M10).
public struct BYOKCleanupProvider: CleanupProvider {

    /// The chat-completions endpoint to POST to — the v1 contract, e.g.
    /// `https://api.openai.com/v1/chat/completions`.
    public let endpoint: URL

    /// The model to request, or `nil` to omit the `model` field (some endpoints default their
    /// own — documented as the v1 contract).
    public let model: String?

    /// The key's seam — injected, so a test drives a stub and the provider never names the
    /// Keychain.
    public let keyProvider: any KeyProvider

    /// The transport the completion is sent through — injected, so a test drives a stub.
    public let transport: any LLMTransport

    /// The machine key the seam reserves for the BYOK provider (`ProviderIdentity.swift:31`).
    public let identity = ProviderIdentity(id: "byok-cleanup", displayName: "BYOK")

    /// Declared, not defaulted: a BYOK round-trip sends the transcript to the user's own cloud
    /// endpoint, so the egress hook `ARCHITECTURE.md:275` reads the truth rather than inheriting
    /// the offline default.
    public var requiresNetwork: Bool { true }

    /// Declared, not defaulted: the seconds an LLM round-trip may take (M1), raced by the caller.
    public var budget: Duration { .seconds(5) }

    public init(
        endpoint: URL,
        model: String?,
        keyProvider: any KeyProvider,
        transport: any LLMTransport
    ) {
        self.endpoint = endpoint
        self.model = model
        self.keyProvider = keyProvider
        self.transport = transport
    }

    /// Clean one transcript: read the key, build the chat-completions request, send it, parse
    /// the answer.
    ///
    /// - Throws: ``LLMProviderError/keyUnavailable`` when the key is absent;
    ///   ``LLMProviderError/unauthorized`` when the server rejects the key (401/403, never
    ///   retried); ``LLMProviderError/malformedResponse`` when the body is not a
    ///   `choices[0].message.content` shape; ``LLMProviderError/emptyResponse`` when the decoded
    ///   answer is empty or whitespace-only. Every other transport failure passes through
    ///   unreinterpreted, as does a throwing key provider.
    public func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String {
        guard let key = try keyProvider.key() else {
            throw LLMProviderError.keyUnavailable
        }

        let body = RequestBody(
            model: model,
            messages: [
                Message(role: "system", content: CleanupPrompts.byokSystem),
                Message(role: "user", content: transcript.text),
            ])
        let request = LLMRequest(
            url: endpoint,
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(key)",
            ],
            body: try JSONEncoder().encode(body))

        let response: LLMResponse
        do {
            response = try await transport.complete(request)
        } catch LLMTransportError.serverStatus(let code) where code == 401 || code == 403 {
            throw LLMProviderError.unauthorized
        }

        let answer: ResponseBody
        do {
            answer = try JSONDecoder().decode(ResponseBody.self, from: response.body)
        } catch {
            throw LLMProviderError.malformedResponse
        }
        guard let cleaned = answer.choices.first?.message.content else {
            throw LLMProviderError.malformedResponse
        }
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.emptyResponse
        }
        return cleaned
    }
}

/// The chat-completions request body — the v1 contract, model optional (omitted when nil).
private struct RequestBody: Encodable {
    let model: String?
    let messages: [Message]
}

/// One chat message — role plus content; the provider ships exactly the system instruction and
/// the transcript.
private struct Message: Encodable {
    let role: String
    let content: String
}

/// The answer body shape — the one path the contract names: `choices[0].message.content`.
/// `content` is optional so a missing key decodes and is reported as
/// ``LLMProviderError/malformedResponse`` rather than crashing the decode.
private struct ResponseBody: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}
