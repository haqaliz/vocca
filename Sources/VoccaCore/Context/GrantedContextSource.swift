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

/// The per-turn source of **already-gated** context snapshots (`byok-context-grant` D2): what a
/// cloud cleanup provider asks when a turn may carry context — and the answer is `nil` unless
/// the AND-gate (per-app consent **and** the separate global grant, `prd.md:102-107`) held at
/// the snapshot's moment.
///
/// The seam is the caller-side gate's delivery half. The wiring composes the source from the
/// consent store's fact, the persisted grant, the ``ContextProvider``'s snapshot and
/// ``ContextGrantGate`` — the gate is the caller's decision, never the provider's
/// (`CleanupProvider.swift:39-41`: the caller owns context decisions, a conformer must not
/// reinterpret them). So a conformer evaluates neither consent nor grant itself; it returns
/// only snapshots that already passed both.
///
/// Total by contract: a failure inside the composed source degrades to `nil` — context is
/// enrichment, never load-bearing, and a context-read failure can neither block a turn nor fail
/// open into sending context (`prd.md:170`). The call is `async` because the consent store's
/// read is, even though the snapshot itself is read synchronously off the ``ContextProvider``
/// seam.
public protocol GrantedContextSource: Sendable {

    /// The already-gated snapshot for this turn, or `nil` when the gate did not hold — or when
    /// the read failed, which is the same answer: a source that never fails open.
    func grantedSnapshot() async -> ContextSnapshot?
}