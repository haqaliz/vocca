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

import VoccaCore

/// The floor under I1: where the ladder puts a transcript it could not deliver.
///
/// When the decision falls through to the failsafe — refusal or exhaustion — it routes the
/// transcript here, with the ``HeldTranscript`` fully populated: the undelivered text, the reason
/// the ladder gave up, the focused application's name for the "{app}" copy
/// (`PRODUCT_SPEC.md:112`), and the monotonic capture instant. The recovery journal (the
/// `failsafe-surface` aspect) implements this; until then the adapters aspect provides an
/// in-memory conformance for tests and the probe.
///
/// ## The I1 contract, stated exactly
///
/// **This is the floor.** A transcript that reaches the failsafe is not lost — that is the
/// invariant the whole ladder is arranged around (`ARCHITECTURE.md:199`), and the reason
/// ``InjectionResult`` with `rung == .widgetFailsafe` is a *successful* outcome. The journal
/// implementation must therefore be **durable before it returns**: the write is committed as part
/// of the hand-off, not after it, so a crash between ladder exhaustion and the journal write — the
/// one window I1's floor must close — cannot exist. `hold` throwing is the journal reporting that
/// it could not make the transcript safe; the ladder surfaces the error, and the durable-before-
/// return contract is what makes the throw effectively impossible in practice.
public protocol FailsafeHandoff: Sendable {
    /// Durably takes custody of `transcript`. Must not return before the transcript survives
    /// process death; throws when it cannot be made so.
    func hold(_ transcript: HeldTranscript) async throws
}
