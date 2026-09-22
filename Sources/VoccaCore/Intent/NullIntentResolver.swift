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

/// The composed default ``IntentResolver``: `.none` for every utterance (the
/// ``NullActionProvider`` precedent, `CAPABILITY_ROADMAP.md` guardrail 7).
///
/// This is the D2-analogue posture (R7): a shipped configuration cannot voice-act until a future
/// slice wires a resolver deliberately, so the composed default resolves nothing and the converse
/// loop's reply generator is untouched. It is a real conformance, not a stub — the seam has two
/// implementations (keyword + null default) — and the unit record states the honest D3-shaped
/// caveat: the null default is a *default*, not a second *real* classifier (R8; S1's
/// `PhraseIntentResolver` is the retirement path).
public struct NullIntentResolver: IntentResolver {

    public init() {}

    /// `.none` for every utterance and every catalog — the resolver that never acts.
    public func resolve(_ utterance: String, against catalog: [ToolReference]) -> IntentResolution {
        .none
    }
}