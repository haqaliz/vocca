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

/// Rung 2 of the cleanup ladder (`ROADMAP.md:119`): a local LLM via Ollama, behind the
/// ``LLMTransport`` seam and the ``CleanupProvider`` seam, with egress **declared** and a
/// declared 5 s budget (`prd.md` M1 — the caller races the number and routes a slow provider to
/// raw, never a provider-side truncation).
///
/// The provider owns every decision the transport must not (`spec.md:42-44`): it shapes the
/// `/api/generate` request — `model`, the pinned ``CleanupPrompts/ollama`` instruction prefixed to
/// the transcript, and `stream: false` (`CAPABILITY_ROADMAP.md:137`) — calls the injected
/// transport, parses `{"response": String}`, and maps a bad body onto ``LLMProviderError``.
/// Transport failures pass through unreinterpreted; every throw degrades to the rules output in
/// the chain (`cleanup-chain`), never a partial string.
///
/// This type is executed by nothing in CI that dials real network — the stub transport stands in
/// for every test, and the real Ollama run is a founder smoke step (`root-wiring` M10).
public struct OllamaCleanupProvider: CleanupProvider {

    /// The Ollama endpoint — `http://localhost:11434` at ship. The provider posts to
    /// `endpoint/api/generate`.
    public let endpoint: URL

    /// The model to run, e.g. `llama3.1`.
    public let model: String

    /// The transport the completion is sent through — injected, so a test drives a stub.
    public let transport: any LLMTransport

    /// The cleanup instruction prefixed to the transcript.
    public let prompt: String

    /// The machine key the seam reserves for the Ollama provider (`ProviderIdentity.swift:31`).
    public let identity = ProviderIdentity(id: "ollama-cleanup", displayName: "Ollama")

    /// Declared, not defaulted: an LLM round-trip sends text off the process, so the egress hook
    /// `ARCHITECTURE.md:275` reads the truth rather than inheriting the offline default.
    public var requiresNetwork: Bool { true }

    /// Declared, not defaulted: the seconds an LLM round-trip may take (M1), raced by the caller.
    public var budget: Duration { .seconds(5) }

    public init(
        endpoint: URL,
        model: String,
        transport: any LLMTransport,
        prompt: String = CleanupPrompts.ollama
    ) {
        self.endpoint = endpoint
        self.model = model
        self.transport = transport
        self.prompt = prompt
    }

    /// Clean one transcript: build the `/api/generate` request, send it, parse the answer.
    ///
    /// - Throws: `LLMProviderError.malformedResponse` when the body is not `{"response": String}`;
    ///   `LLMProviderError.emptyResponse` when the decoded answer is empty or whitespace-only; the
    ///   transport's own errors pass through unreinterpreted.
    public func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String {
        let body = RequestBody(
            model: model,
            prompt: prompt + "\n\nDICTATED TEXT:\n" + transcript.text,
            stream: false)
        let request = LLMRequest(
            url: endpoint.appendingPathComponent("api/generate"),
            headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(body))

        let response = try await transport.complete(request)

        let answer: ResponseBody
        do {
            answer = try JSONDecoder().decode(ResponseBody.self, from: response.body)
        } catch {
            throw LLMProviderError.malformedResponse
        }
        let cleaned = answer.response
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.emptyResponse
        }
        return cleaned
    }
}

/// The request body shape the Ollama `/api/generate` endpoint speaks — a batch completion, never
/// streaming (`stream` is pinned `false` here and byte-asserted in the contract tests).
private struct RequestBody: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
}

/// The answer body shape — the one key the contract names (`{"response": String}`).
private struct ResponseBody: Decodable {
    let response: String
}
