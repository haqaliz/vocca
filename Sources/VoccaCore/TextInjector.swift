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

/// The seam the loop wiring injects through — the pluggable boundary named in
/// `ARCHITECTURE.md:212` ("Injection | `TextInjector`").
///
/// One method, and it is the whole contract: text in, ``TargetContext`` in, ``InjectionResult``
/// out, always. There is no throwing variant, because exhaustion is not an error — it is the
/// failsafe handing the text back to the user. `ARCHITECTURE.md:199` is explicit: "there is no
/// `case transcriptLost`. ... `injectionExhausted` is not a loss — it means the ladder fell
/// through to the widget, which is a *successful* outcome under I1." The caller-facing contract
/// is the result, never an exception.
///
/// `Sendable`, because the injector runs on the latency path (`ARCHITECTURE.md:271` budgets the
/// whole ladder at ≤100 ms) and crosses whatever actor the loop wiring owns.
///
/// The first implementation is the orchestration half — ``LadderInjector`` — with the per-rung
/// strategies as the other half of the same seam (the adapters aspect). The
/// `@Sendable`-independent pattern here matches every other seam in this module: the core owns
/// the vocabulary and the contract; the adapters own the system calls.
public protocol TextInjector: Sendable {
    /// Inserts `text` into `target`, always returning an ``InjectionResult`` — which rung
    /// delivered, which rungs were attempted (the C8 strategy-memory input), whether the insert
    /// was read back and confirmed, and how long the whole ladder took. Never throws.
    func inject(_ text: String, into target: TargetContext) async -> InjectionResult
}
