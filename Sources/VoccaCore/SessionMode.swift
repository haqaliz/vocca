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

/// The product's dual mode, as the cleanup seam must see it (`ARCHITECTURE.md:222`).
///
/// **Read by `SessionModeMachine` since C11.** The field exists in ``CleanupContext`` because
/// `ARCHITECTURE.md:220-225` defines the context with it now; per-mode cleanup selection — a
/// different dictionary, a different provider, a different budget for CONVERSING than for
/// dictation — is C6/C11 work (`prd.md:219-220`), and the deterministic-cleanup unit consumed
/// neither case. A conformer may read it; the mode machine reads it, and the cleanup seam's
/// per-mode selection remains C11's per-mode-cleanup aspect.
///
/// This is *not* the machine's toggle: that is a start configuration of the same session
/// (`SessionRules.swift:51-53`), not the dictate-vs-converse dual mode this enum names.
///
/// - SeeAlso: ``SessionModeMachine`` — the state machine that owns dictate-vs-converse as
///   behaviour, under `Sources/VoccaCore/Mode/`.
public enum SessionMode: Sendable, Equatable {
    /// Dictating into a field: the P0 loop's mode, and the only mode C5 serves.
    case dictation
    /// The agent conversation mode (P3). Declared now so the context's shape is
    /// `ARCHITECTURE.md`'s; consumed by C6/C11, never here.
    case conversing
}
