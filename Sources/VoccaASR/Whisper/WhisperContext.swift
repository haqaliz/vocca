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

/// The seam between the engine and the C context that actually runs inference
/// (`plan_20260810.md` Phase 3): what the bridge's translated transcript looks like as an
/// abstract, testable service, with **no C-API name in sight** — the H7 doctrine, in protocol
/// form.
///
/// The engine holds an injected ``WhisperContext`` and never names the C API itself (the
/// `WhisperSeamTests` lint enforces it two-sided); the one implementation,
/// ``WhisperCAPI``, is the one file in `Sources/` permitted to speak the C ABI, and every
/// engine behavior test drives a stub context instead — no model file, no GPU, no C call, ever.
///
/// The protocol is deliberately *not* `Sendable`: like `MonotonicClock` in the Parakeet engine,
/// the instance lives in the engine actor's isolation domain (the class-constrained C handle it
/// owns — ``WhisperCAPI``'s `OpaquePointer` — is not `Sendable` in Swift 6, and must never leave
/// that domain), so its methods are called only from the actor and its state never crosses a
/// boundary.
public protocol WhisperContext {
    /// Creates the inference context for the model at `modelFileURL` — the C context
    /// initialisation, translated. Called once per prepared engine; throwing (a missing or
    /// corrupt model file) must leave the context unusable but the engine retryable.
    func prepare(modelFileURL: URL) throws

    /// Transcribes one buffer of 16 kHz mono samples into segments, translated.
    ///
    /// - Throws: a typed error the engine maps onto ``VoccaError/transcriptionFailed(_:underlying:)``
    ///   with the underlying cause intact — never a stringified reason.
    func transcribe(samples: [Float]) throws -> [WhisperSegment]
}
