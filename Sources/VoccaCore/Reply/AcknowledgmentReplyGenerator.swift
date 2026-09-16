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

/// The second ``ReplyGenerator``: the fixed copy `"Vocca is listening."` for every input,
/// empty included.
///
/// ## The copy decision (R7, decided and recorded — a change is a founder decision)
///
/// The copy states the mode's own honest state — the machine is listening, nothing more. It
/// deliberately does **not** say "got it" (which claims comprehension), does not put on a
/// persona, and does not say "the assistant is not here yet" (which sounds like a defect). It
/// matches the widget's in-state label wording (`◈ listening…`, `PRODUCT_SPEC.md §5`), is
/// short enough to speak, and can never be read as an answer to anything. It is deterministic
/// by construction (a constant), local, and zero-network.
///
/// `converse-wiring` composes ``EchoReplyGenerator`` (the shipped default); this
/// implementation exists for the seam doctrine's two-implementations guardrail
/// (`CAPABILITY_ROADMAP.md:414`) and as the honest non-echo alternative.
public struct AcknowledgmentReplyGenerator: ReplyGenerator {

    public init() {}

    /// Returns `"Vocca is listening."` for every input — input-independent, empty included.
    public func reply(to text: String) -> String {
        "Vocca is listening."
    }
}