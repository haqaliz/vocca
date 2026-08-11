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

/// What one rung attempt answers.
///
/// Two cases, switched exhaustively: a rung either delivered the text, or it did not. The
/// `verified` bit in the success case carries **AX read-back truth and nothing more** — the
/// *decision* interprets it (`ARCHITECTURE.md:400`), and a conformance must not pre-interpret it.
/// An adapter answers with what the system told it, raw; deciding that an unverified "success" is
/// a failure is the decision function's, and doing it twice would be two copies of one decision
/// with the second in the half CI cannot execute.
public enum RungAttempt: Sendable, Equatable {
    /// The rung believes it delivered. `verified: true` means the insert was read back and
    /// confirmed; `false` means the rung has no read-back (clipboard, keystroke) or read-back that
    /// failed to confirm.
    case succeeded(verified: Bool)
    /// The rung did not deliver.
    case failed
}

/// The seam between the ladder's decision and the per-rung adapters — one rung of the ladder,
/// with the system call taken out.
///
/// `ARCHITECTURE.md:212` names `TextInjector` as the injection seam, and `LadderInjector` is its
/// orchestration half: this protocol is the other half, the surface the adapters aspect implements
/// (`AXRung`, `ClipboardPasteRung`, `KeystrokeSynthesisRung`). The decision function holds the map
/// of rung → strategy and consults exactly these, so every branch above the system calls is
/// testable over injected handles — the `TapHealthPolicy` precedent, in the module that owns the
/// decisions.
///
/// `Sendable`, because the ladder runs on the latency path (`ARCHITECTURE.md:271`) and the
/// decision awaits each rung across suspension points.
public protocol InjectionRungStrategy: Sendable {
    /// Which rung this strategy implements — the key the decision maps on, and the identity the
    /// result's `attempted` trace records.
    var rung: InjectionRung { get }

    /// Attempt one insertion of `text` into `target`.
    ///
    /// **Answers with raw truth.** A conformance reports what the system said it did: AX
    /// read-back confirmed or not, clipboard and keystroke with no read-back at all. Interpreting
    /// `succeeded(verified: false)` as failure is the decision's, and only the decision's.
    func tryInject(_ text: String, into target: TargetContext) async -> RungAttempt
}
