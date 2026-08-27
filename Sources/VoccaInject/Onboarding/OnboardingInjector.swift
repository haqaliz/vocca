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

import VoccaCore

/// One of ``TextInjector``'s implementations: TRY IT's delivery end (prd.md M6) — translation
/// from the pipeline's inject call to the onboarding sink's delivery, nothing else.
///
/// ``LadderInjector`` decides: it resolves a target's rung order, runs the allowlist gate and
/// routes each rung's answer through the failsafe. This conformance decides nothing and reads
/// nothing: the onboarding sink **is** its target — the window's own field, A5's binding — so
/// the focused-app context the pipeline passes is deliberately irrelevant. Whatever
/// ``TargetContext`` arrives (a focused app, nothing focused, Secure Input in force — the
/// refusals the ladder would have made), the transcript is delivered to the sink.
///
/// ## The result vocabulary, mapped honestly
///
/// The seam's contract is closed and this conformance answers it with translation only:
///
/// - **Delivery** — ``deliver(_:)`` returned: the transcript reached the field. The result
///   reports a delivery rung (``InjectionRung``'s set is closed by design,
///   `InjectionRung.swift:20-22` — a fifth case re-tests the ladder's whole fault-injection set,
///   a deliberate, reviewed change this aspect does not make — and the sink is none of the four
///   ways text can reach the *focused field*). The rung label is therefore a vocabulary
///   artifact: `attempted` — the only field a consumer demotes on (C8's strategy memory) — is
///   honestly empty, `verified` is honestly `false` (no read-back exists on this path; the
///   conformer's own binding semantics own rendering), and the outcome the record carries —
///   the `.delivered` class, the `.idle` surface — is the truth.
/// - **Failure** — ``deliver(_:)`` threw (the binding is gone, the field refused): the failsafe
///   terminal is answered, the pipeline reads a holder that holds nothing and surfaces the
///   reason-only failure — the TRY IT failure the window folds
///   (``OnboardingAction/tryItFailed``). **Never a fabricated success**, and never a silent
///   idle: a refused delivery is a visible failure, exactly like the ladder's own residual row.
///
/// ## Deliberate divergence from ``LadderInjector``: not durable-before-return
///
/// The ladder's conformance hands custody to a journal whose `hold` does not return until the
/// transcript survives process death (`TranscriptHolder.swift:25-34`). This conformance
/// deliberately has no journal: **the sink owns delivery** — the window's binding holds the text
/// in the field itself, where the user is looking — so durability-in-a-file would be a second,
/// competing claim on the same transcript, and the C4 contract is a ladder property, not an
/// injector-universal. A transcript whose sink refuses is *not* silently lost: the reason-only
/// failure surfaces it as exactly what it was — a dictation that did not land — which is what
/// lets the user simply try again.
///
/// ## Isolation
///
/// A plain `Sendable` struct, like ``DictationPipeline``: the only dependency is the
/// `Sendable` sink, so the conformance needs no isolation domain of its own and a test drives
/// it directly.
public struct OnboardingInjector: TextInjector {
    /// The delivery destination — the TRY IT field's binding at ship (A5); a recording fake in
    /// the headless suite.
    private let sink: any OnboardingTranscriptSink

    /// - Parameter sink: Where the transcript lands. Owned by the composition root (the sink is
    ///   the root's, A4's wiring); the window's binding conforms to the seam in A5.
    public init(sink: any OnboardingTranscriptSink) {
        self.sink = sink
    }

    public func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
        do {
            try await sink.deliver(text)
            // Delivered: the delivery-rung vocabulary artifact documented above. `attempted` is
            // empty — no ladder rung ran — and `verified` is `false` — no read-back exists on
            // this path (the sink's own binding semantics own rendering).
            return InjectionResult(
                rung: .clipboardPaste, attempted: [], verified: false, elapsed: .zero)
        } catch {
            // The sink refused custody. The failsafe terminal answers honestly: nothing was
            // fabricated as delivered, and the pipeline's holder-read surfaces the reason-only
            // failure (nothing held — this conformance never holds, so the pipeline's
            // `.exhausted` residual is exactly its own documented shape for that case,
            // `DictationPipeline.swift:71-77`).
            return InjectionResult(
                rung: .widgetFailsafe, attempted: [], verified: false, elapsed: .zero)
        }
    }
}