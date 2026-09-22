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

/// What a spoken utterance means once the intent step has had its say (`intent-layer` PRD R1;
/// `intent-seam` spec acceptance 1-5).
///
/// The resolution is the seam's whole output, and the converse pipeline branches on exactly the
/// three cases:
///
/// - ``IntentResolution/toolCall(_:)`` — a confident match: an ``ActionInvocation`` the gate can
///   confirm and the executor can run. Carried here as Core vocabulary — the same type the rest
///   of the action machinery speaks — so nothing above the seam has to translate.
/// - ``IntentResolution/ask(question:)`` — not confident: the spoken question names the top
///   candidates from the resolver's own ranking, and **nothing executes** (R2's ask path; a guess
///   never runs).
/// - ``IntentResolution/none`` — no tool resolved: the pipeline falls through to the existing
///   reply generator untouched.
///
/// `Sendable` and `Equatable` by construction: resolution is deterministic and crosses the
/// driver's task boundaries, and equality is what lets a test assert a resolution verbatim.
public enum IntentResolution: Sendable, Equatable {

    /// A confident match, with the exact invocation — provider, tool and argument text.
    case toolCall(ActionInvocation)

    /// Not confident: `question` names the resolver's own top candidates, in its own order.
    case ask(question: String)

    /// No tool resolved.
    case none
}