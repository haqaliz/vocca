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

/// The errors the core's ASR and injection paths can raise (`ARCHITECTURE.md:186-193`).
///
/// Both ASR cases carry the ``EngineIdentity`` of the engine that failed, because an error that
/// cannot be attributed cannot be acted on: "which engine is unavailable?" is the same question
/// as "which download do I offer?", and a transcription failure without its engine would be
/// credited to whichever model the log happened to be talking about.
///
/// ``VoccaError/injectionExhausted(attempted:)`` is the injection path's single case, and the
/// only one of the §4 errors that belongs to the core: it is the vocabulary the ladder's
/// decision and every consumer share, whereas the failure itself is carried in the
/// ``InjectionResult`` the caller receives. The remaining cases named in §4 — permission,
/// capture, cleanup — belong to the aspects that raise them and are added there, not here.
public enum VoccaError: Error, Sendable {
    /// The engine's model is not available: not downloaded, not loadable, not granted.
    case modelUnavailable(EngineIdentity, reason: String)

    /// The engine failed to transcribe. The underlying error is carried intact, not stringified —
    /// stringifying would throw away the very thing a caller needs to diagnose.
    case transcriptionFailed(EngineIdentity, underlying: Error)

    /// Every rung of the injection ladder was attempted and failed. **Not a loss:** the
    /// transcript fell through to the widget failsafe, which is a *successful* outcome under I1
    /// (`ARCHITECTURE.md:193-199`) — "injectionExhausted is not a loss — it means the ladder
    /// fell through to the widget". The payload is the full attempt trace, in order: the input
    /// C8's per-app strategy memory demotes on. Declared as vocabulary; the ladder does not
    /// throw it, because the caller-facing contract is the ``InjectionResult``.
    case injectionExhausted(attempted: [InjectionRung])
}
