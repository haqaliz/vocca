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

/// The one seam through which LLM completion bytes enter the machine — the network half of the
/// AI-cleanup story, and the second of the two network types `ARCHITECTURE.md:16` names
/// (``DefaultModelTransport`` is the first).
///
/// This aspect builds the seam now, before any provider, so the providers' tests can drive a stub
/// through the real protocol; `DefaultLLMTransport` (Phase 2) is the second file in `Sources/`
/// permitted to name `URLSession`, and the H8-shaped confinement lint (`spec.md:28-31`) makes that
/// a build failure elsewhere rather than an aspiration.
///
/// The vocabulary is deliberately domain-free: a request is a URL, a method, headers and a body —
/// no chat-role shapes, no temperature, nothing a provider would need to interpret. **Request
/// shaping belongs to the providers** (`ollama-provider`, `byok-provider`), which build an
/// `LLMRequest` from their own configuration; the transport never knows a key exists, so a server
/// echo can never leak one (see `LLMTransportError`'s body-less rule).
public protocol LLMTransport: Sendable {
    /// Sends one completion request and returns the raw response.
    ///
    /// - Parameters:
    ///   - request: The URL, method, headers and body to send — exactly as given, byte for byte.
    ///
    /// - Returns: The status code and body the server answered with. A 2xx answer is the caller's
    ///   to parse; the transport does not interpret the body.
    ///
    /// - Throws: `LLMTransportError` for every failure the transport can name, or
    ///   `CancellationError` when the call was cancelled. The error never carries a response body.
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

/// One LLM completion request — a URL, a method, headers and a body, with no domain meaning.
public struct LLMRequest: Sendable {
    /// Where the request is sent.
    public let url: URL

    /// The HTTP method. Defaults to `POST`, the shape every chat completion endpoint speaks.
    public let method: String

    /// The request headers, sent verbatim.
    public let headers: [String: String]

    /// The request body, sent verbatim.
    public let body: Data

    public init(url: URL, method: String = "POST", headers: [String: String], body: Data) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// The raw answer to an ``LLMRequest`` — status code and body, with no domain meaning.
public struct LLMResponse: Sendable {
    /// The HTTP status code the server answered with.
    public let statusCode: Int

    /// The response body. A caller parses it; the transport never interprets it.
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// The typed failures an ``LLMTransport`` conformer can name.
///
/// **Errors deliberately carry no body** (`spec.md:48-50`): a 401 body, an HTML error page, a
/// malformed JSON — none of it rides in the error a caller can log, so a server echo can never
/// leak a key the BYOK provider put in a header. `serverStatus` carries only the status code the
/// provider can log.
public enum LLMTransportError: Error, Sendable {
    /// The host could not be reached — no connection, no route, no DNS, a timeout. Nothing was
    /// answered, so there is nothing more specific to say.
    case unreachable

    /// The server answered with a non-2xx status. Carries the status code, and deliberately
    /// nothing else — see the type documentation.
    case serverStatus(Int)

    /// The answer was not a usable HTTP response at all — a non-HTTP response, or a transport
    /// failure that is not a connection failure.
    case invalidResponse
}
