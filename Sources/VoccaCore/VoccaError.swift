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

/// The errors the core's ASR path can raise (`ARCHITECTURE.md:186-193`).
///
/// Both ASR cases carry the ``EngineIdentity`` of the engine that failed, because an error that
/// cannot be attributed cannot be acted on: "which engine is unavailable?" is the same question
/// as "which download do I offer?", and a transcription failure without its engine would be
/// credited to whichever model the log happened to be talking about.
///
/// The other cases named in §4 — permission, capture, injection, cleanup — belong to the aspects
/// that raise them and are added there, not here.
public enum VoccaError: Error, Sendable {
    /// The engine's model is not available: not downloaded, not loadable, not granted.
    case modelUnavailable(EngineIdentity, reason: String)

    /// The engine failed to transcribe. The underlying error is carried intact, not stringified —
    /// stringifying would throw away the very thing a caller needs to diagnose.
    case transcriptionFailed(EngineIdentity, underlying: Error)
}
