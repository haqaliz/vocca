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

/// The ``IntentResolver`` that never acts: `.none` for every utterance (the
/// ``NullActionProvider`` precedent, `CAPABILITY_ROADMAP.md` guardrail 7).
///
/// It was the composed default from `intent-layer` (R7's D2-analogue posture: a shipped
/// configuration could not voice-act) until `phrase-intent-resolver` flipped the default to a
/// per-turn ``PhraseIntentResolver`` — which, with no phrase file, resolves nothing just as this
/// does. It stays a real, shipped conformance: the resolver a composition wires to switch the
/// voice leg off. It was never a second *real* classifier — the D3-shaped caveat (R8) that
/// ``PhraseIntentResolver`` retired.
public struct NullIntentResolver: IntentResolver {

    public init() {}

    /// `.none` for every utterance and every catalog — the resolver that never acts.
    public func resolve(_ utterance: String, against catalog: [ToolReference]) -> IntentResolution {
        .none
    }
}