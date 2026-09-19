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

/// The shipped default ``ActionProvider``: **serves no tools and does nothing**
/// (`action-safety-spine` PRD M9).
///
/// ## The honesty posture
///
/// Vocca ships an action seam and no ability to act. The default advertises an empty tool list,
/// describes every tool it is asked about as a refusal, and returns
/// ``ActionOutcome/notInvoked`` from every invocation. It claims nothing it cannot do:
/// deterministic by construction (constant functions — no state, no environment), stdlib-only
/// (this module imports nothing, so no `Process` and no transport could compile here), and
/// zero-network.
///
/// This is the same posture ``NullContext`` holds for the context seam, and for the same
/// reason: the seam exists so a real implementation can slot in behind it, and until one does,
/// the default must be the thing that is safest to have shipped rather than the thing that is
/// most useful.
///
/// ## Read-only is not an exception
///
/// A ``BlastRadius/readOnly`` invocation is refused here exactly like any other. "Read-only may
/// run directly" is a rule about *permission* — it tells the gate it need not stop to ask — and
/// it has never been a promise that some provider must serve the call. The default serves
/// nothing at any radius, and the answer is about the provider rather than about the tool it
/// was handed: every `describe` returns the same refusal.
public struct NullActionProvider: ActionProvider {

    public init() {}

    /// No tools. There is nothing for an intent layer to resolve an utterance against.
    public var toolIDs: [String] { [] }

    /// The refusal summary — identical for every tool, because the answer is about this
    /// provider and not about what it was asked.
    ///
    /// The radius is ``BlastRadius/readOnly``: nothing will happen, so there is nothing to
    /// confirm. Describing an unserved tool never traps — the shipped default is safe to call
    /// with anything, including a tool id no provider has ever heard of.
    /// It is `async` because the seam is, and it suspends nowhere: the default has nothing to
    /// await. A provider that genuinely does — the reason the seam is asynchronous at all — is a
    /// later aspect's.
    public func describe(_ invocation: ActionInvocation) async -> ActionSummary {
        ActionSummary(
            sentence: "Vocca has no action provider that can do this. Nothing will happen.",
            blastRadius: .readOnly)
    }

    /// Never acts — ``ActionOutcome/notInvoked`` for every invocation, confirmed or not.
    ///
    /// `.notInvoked` rather than a failure, deliberately: the provider did not try and fail, it
    /// never ran at all, and the audit log's one real question is which of those happened.
    public func invoke(
        _ invocation: ActionInvocation, confirmation: ActionConfirmation
    ) async -> ActionOutcome {
        .notInvoked
    }
}
