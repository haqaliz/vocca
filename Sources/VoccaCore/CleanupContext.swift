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

/// Everything a cleanup provider may need to know about the dictation it is cleaning
/// (`ARCHITECTURE.md:220-225`).
///
/// Deliberately free of system types, like ``TargetContext`` (`TargetContext.swift:15-22`):
/// `VoccaCore` imports nothing, and the decision must be testable over a context a test builds by
/// hand. Every field is `let` — the caller describes the session, the provider does not
/// reinterpret it.
///
/// - ``target`` — what the user was typing into, for provider choices that depend on the app;
/// - ``mode`` — dictate vs converse (``SessionMode``; declared, never read at C5);
/// - ``dictionary`` — the user's replacement rules, **in declared order** (`ReplacementRule` —
///   order is the contract);
/// - ``budget`` — the time the caller is prepared to wait; exceeding it is the caller's decision
///   to route to raw, never the provider's to silently truncate (`ARCHITECTURE.md:224` — "exceed
///   it and we return raw — I5").
///
/// The init is plain memberwise, free of defaults — the ``TargetContext`` precedent
/// (`TargetContext.swift:47-51`): a test must be able to build this by hand, and a default could
/// hide a missing caller read.
public struct CleanupContext: Sendable {
    /// The focused application and window at capture time.
    public let target: TargetContext

    /// The session's mode: dictation or conversing. Both constructible; C5 reads neither.
    public let mode: SessionMode

    /// The replacement rules in application order — a conformer must not sort or deduplicate.
    public let dictionary: [ReplacementRule]

    /// The caller-enforced time budget (`prd.md:89-93`): the caller routes to raw when exceeded;
    /// the provider must not reinterpret it.
    public let budget: Duration

    public init(target: TargetContext, mode: SessionMode, dictionary: [ReplacementRule], budget: Duration) {
        self.target = target
        self.mode = mode
        self.dictionary = dictionary
        self.budget = budget
    }
}
