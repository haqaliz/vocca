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

/// The token-scored ``IntentResolver`` (`intent-layer` PRD R2; `intent-seam` spec acceptance
/// 1-4) — the deterministic classifier over the enabled-tool catalog.
///
/// `intent-seam` RED: this file is the placeholder the contract tests fail against. It conforms
/// to the seam and resolves nothing, so `IntentResolverContractTests` fail on **behaviour** (a
/// seeded phrase does not resolve to a tool call) rather than on a compile error — the failing
/// tests are the spec's acceptance 1-4 written first. The token-scored matcher, the seeded
/// synonym table, the not-confident threshold and the ask path land in the GREEN commit.
public struct KeywordIntentResolver: IntentResolver {

    public init() {}

    /// RED placeholder: resolves `.none` for every utterance.
    public func resolve(_ utterance: String, against catalog: [ToolReference]) -> IntentResolution {
        .none
    }
}