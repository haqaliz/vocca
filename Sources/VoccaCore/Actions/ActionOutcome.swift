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

/// What came of an invocation — what ``ActionProvider/invoke(_:confirmation:)`` returns.
///
/// Failure is a **value, not a thrown error**. The seam is non-throwing by contract, for the
/// same reason `ContextProvider` is (the C12 D1 posture): a provider that can throw is a
/// provider that can be caught mid-turn by whoever forgot to handle it, and the audit log must
/// record the failure either way. An outcome that must be returned is an outcome that cannot
/// be dropped by omission.
public enum ActionOutcome: Sendable, Equatable {
    /// The provider acted and the action completed.
    case succeeded

    /// The provider acted, or tried to, and the attempt failed.
    ///
    /// - Parameter reasonKey: A **bounded key**, never a message — `"provider.unknownTool"`,
    ///   not the text of an underlying error. Two reasons: `VoccaCore` imports nothing, so
    ///   there is no error type to carry; and the audit entry is byte-pinned (M6), which
    ///   free-form error text would defeat by smuggling unbounded — and possibly
    ///   transcript-derived — bytes onto disk.
    case failed(reasonKey: String)

    /// The provider **never acted**. Declined by the gate, refused by the provider, or never
    /// reached.
    ///
    /// Distinct from ``failed(reasonKey:)`` on purpose: "it tried and failed" and "it was never
    /// allowed to try" are different events, and an audit log that conflated them could not
    /// answer the only question the log exists for — *did this actually run?* The same
    /// distinction is what makes the dry-run acceptance (M5/G2) expressible at all.
    case notInvoked
}
