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

/// The delivery end of TRY IT (prd.md M6): where a real dictation's final transcript lands when
/// onboarding is not yet complete.
///
/// The seam exists because TRY IT's transcript must reach the onboarding window's own field —
/// not the system-wide ladder (the AX allowlist is seeded with three apps, not Vocca) — and the
/// loop wiring speaks seams, never windows (`TextInjector`'s contract: text in, result out,
/// always). ``OnboardingInjector`` is the translation between the two: it calls ``deliver(_:)``
/// and maps the answer onto the injector's result vocabulary.
///
/// ## Delivery semantics belong to the conformer
///
/// This protocol says *that* a transcript is delivered, never *how*: the field binding (A5's
/// TRY IT field) decides what delivery means — append to the field, and on success the window
/// folds ``OnboardingAction/tryItSucceeded(_:)`` (G5: "success here = onboarding complete").
/// The headless suite drives a fake conformer in that field's place.
///
/// ## Failure
///
/// ``deliver(_:)`` throws when the delivery cannot happen — the binding is gone (the window
/// closed mid-dictation), the field refused, whatever the conformer's own semantics are. The
/// injector maps that refusal onto the failsafe terminal honestly: the pipeline surfaces the
/// reason-only failure, never a fabricated delivered result (plan: "do not fabricate success").
///
/// `Sendable`, like every seam on the latency path: the injector holds this across the
/// pipeline's actor boundary.
public protocol OnboardingTranscriptSink: Sendable {
    /// Delivers `transcript` to the conformer's destination — the TRY IT field's binding at
    /// ship. Throws when the delivery cannot happen.
    func deliver(_ transcript: String) async throws
}