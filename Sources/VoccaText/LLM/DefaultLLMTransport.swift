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

/// The second file in `Sources/` permitted to name `URLSession` — the second of `ARCHITECTURE.md:16`'s
/// two named network types (``DefaultModelTransport`` is the first), and the network half of the
/// AI-cleanup story.
///
/// Everything *decided* about an LLM completion — request shaping, the key, the caller's budget
/// race, parsing the response — lives above the ``LLMTransport`` seam, in the providers and their
/// callers. This type is the adapter: it builds a `URLRequest` from an ``LLMRequest`` verbatim,
/// speaks HTTP, and translates failures onto the seam's vocabulary. It contains no decisions,
/// which is why CI never executes a line of it and why that is acceptable — the seam's stub drives
/// every test (`LLMTransportTests`), and the real adapter is smoke-verified on the founder's
/// machine (`root-wiring` M10). The H8-shaped confinement lint (`ModelDownloaderSeamTests`) makes
/// this the *only* other file that may name `URLSession`.
///
/// Contract:
/// - **Translation only.** URL, method, headers and body pass through byte for byte; no retry, no
///   backoff, and no timeout of its own — the caller's budget race (`prd.md` M1) is the only
///   timeout.
/// - **Cancellation.** A cancelled transfer surfaces as `CancellationError` (translated from
///   `URLError.cancelled`), so the caller's budget race / Esc can rethrow cancellation intact.
/// - **Body-less errors.** A connection-family `URLError` maps to ``LLMTransportError/unreachable``,
///   a non-2xx answer to ``LLMTransportError/serverStatus(_:)`` (no body), anything else to
///   ``LLMTransportError/invalidResponse`` — see the seam's error documentation for why.
public struct DefaultLLMTransport: LLMTransport {

    /// The session used for completions. Injected so a caller can supply an ephemeral or
    /// custom-configured session; defaults to the shared one.
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = request.body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where Self.connectionFailureCodes.contains(error.code) {
            throw LLMTransportError.unreachable
        } catch {
            throw LLMTransportError.invalidResponse
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMTransportError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMTransportError.serverStatus(http.statusCode)
        }
        return LLMResponse(statusCode: http.statusCode, body: data)
    }

    /// The `URLError` codes that mean "the host could not be reached" — the connection-family
    /// failures the seam maps to ``LLMTransportError/unreachable``. Anything else (bad URL,
    /// transport-level) is ``LLMTransportError/invalidResponse``.
    private static let connectionFailureCodes: Set<URLError.Code> = [
        .cannotConnectToHost,
        .cannotFindHost,
        .networkConnectionLost,
        .notConnectedToInternet,
        .timedOut,
    ]
}
