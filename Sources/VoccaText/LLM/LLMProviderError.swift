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

/// The failures an LLM cleanup provider names *after the transport has answered* — the shared
/// vocabulary the `ollama-provider` and `byok-provider` aspects both import (`llm-cleanup` M3).
///
/// The transport's own failures (``LLMTransportError``) pass through a provider unreinterpreted;
/// this enum is what the *provider* decides about the body it was handed: the answer was not
/// usable (``malformedResponse``), the answer was usable but empty — nothing to inject
/// (``emptyResponse``) — or the caller's key was missing (``keyUnavailable``) or rejected
/// (``unauthorized``). The BYOK provider needs the two key cases; the Ollama provider needs the
/// two response cases. Both import this file rather than redefining it.
public enum LLMProviderError: Error, Sendable {
    /// The body could not be decoded into the contract's shape — not JSON, or missing the key the
    /// contract names.
    case malformedResponse

    /// The decoded answer was empty or whitespace-only — nothing to inject.
    case emptyResponse

    /// The caller's key is missing from configuration.
    case keyUnavailable

    /// The remote service rejected the caller's key.
    case unauthorized
}
