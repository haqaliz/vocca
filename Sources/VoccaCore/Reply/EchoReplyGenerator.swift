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

/// The shipped default ``ReplyGenerator``: the user's own words back, **byte-for-byte** —
/// no normalization, no prefix, no trimming.
///
/// ## The honesty posture (O3)
///
/// The reply is the user's own words played back. It claims nothing beyond "the machine heard
/// you" — it cannot be mistaken for agent intelligence, and it doubles as a by-ear
/// ASR-accuracy check for the P3 spoken-exchange SMOKE: hearing your words back is the
/// strongest "the loop heard me" signal. It is deterministic by construction (the identity
/// function), local, and zero-network.
///
/// `converse-wiring` composes this implementation at the R6 slot; C13's real agent replaces
/// it behind the same seam (`ReplyGenerator`).
public struct EchoReplyGenerator: ReplyGenerator {

    public init() {}

    /// Returns `text` verbatim — the identity function. An echo of empty is empty (silence,
    /// never an error); whitespace and punctuation return untouched.
    public func reply(to text: String) -> String {
        text
    }
}