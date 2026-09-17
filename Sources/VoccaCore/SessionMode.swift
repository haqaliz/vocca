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
/// **Read at the cleanup resolver since C11 (`per-mode-cleanup`).** ``CleanupContext.mode``
/// selects the cleanup provider: the resolver answers ``CleanupResolver/resolve(mode:)`` with
/// the selection the file names for that mode — the pinned dictation pipeline constructs
/// `.dictation` contexts (`DictationPipeline.swift:441-443,468-470`), and `converse-wiring`
/// constructs `.conversing`. A conformer may read it; no provider branches on it
/// (`CleanupProviderSeamTests`). The mode field's transport is unchanged since C5 — only its
/// consumption is new.
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
