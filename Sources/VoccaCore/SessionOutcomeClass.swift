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

/// How a session ended — exactly the five routes the P0 pipeline can exit by.
///
/// The classes are **never force-labeled**: the P0 first-method-success metric is derived, not
/// stored (prd.md, confirmed decision) — it counts ``delivered`` outcomes, and no other class may
/// be coerced into one at the margin. ``delivered(rung:verified:)`` carries the rung and the
/// read-back truth off a hand-built ``InjectionResult`` (spec A6): the same facts the
/// ``InjectionResult`` carries, so the wiring reads one shape wherever it looks.
public enum SessionOutcomeClass: Sendable, Equatable {
    /// The transcript reached the focused field — the only class the first-method-success
    /// metric counts. `.widgetFailsafe` as the rung is a success under I1.
    case delivered(rung: InjectionRung, verified: Bool)
    /// The transcript was held for the user — the failsafe window rendered it; I1's floor.
    case failsafeHeld
    /// The session was cancelled (Escape) — nothing was asked of the engine.
    case aborted
    /// The session failed — a transcription or injection failure with no delivery.
    case failed
    /// A short press with nothing recorded — skipped the injector entirely.
    case emptySkip
}
