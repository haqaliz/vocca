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

/// The idle re-warm contract (`rewarm-after-idle/plan_20260831.md` phase (b)).
///
/// Deliberately **not** an ``ASREngine`` requirement: ~17 conformances exist (2 real engines,
/// 2 probe engines, ~13 test doubles), and a requirement would churn all of them and force a
/// default that is either a silent no-op or a throw. This is a separate seam the two real
/// engines conform to; the resolver casts and throws ``DictationEngineResolverError/rewarmUnsupported``
/// loudly when absent — a non-conforming engine is a loud resolver error, never a silent no-op.
///
/// The contract:
/// - **Make the model resident again as if freshly prepared.** The next transcribe must be
///   warm — and recorded as ``EngineTiming/Kind/warmTranscribe``, never a second
///   ``EngineTiming/Kind/firstAfterLaunch`` (the 1.2 launch bound stays launch-pure).
/// - **Never a network download.** The store short-circuits verified-present models
///   (`downloadIfMissing`); the re-warm is disk-only and lights nothing.
/// - **Called only on a loaded engine.** The resolver routes the unprepared case to the
///   ordinary eager path; a conformer still guards strictly, because a silent no-op on an
///   unprepared engine would pretend a re-warm happened when nothing did.
/// - **A failure must leave the previous load usable.** Load-new-then-swap: the old model
///   stays resident on failure, and the engine keeps transcribing on it.
public protocol EngineRewarmable: Sendable {
    /// Re-warms the engine: reloads the selected tier's model and swaps it in.
    func rewarm() async throws
}