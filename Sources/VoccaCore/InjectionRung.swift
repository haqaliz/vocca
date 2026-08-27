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

/// The four ways text can reach the focused field — the ladder, in `ARCHITECTURE.md:398-403`'s
/// order.
///
/// `CaseIterable` is load-bearing for the Phase C fault-injection suite, which iterates the
/// *closed set*: every rung forced to fail in sequence, every failure combination, zero loss.
/// `allCases` in declaration order is the pinned reference ordering, so a fifth case added here
/// is a deliberate, reviewed change to the ladder that re-tests the whole set — the compiler
/// makes the suite grow, not the prose.
///
/// The `String` raw values are the persisted spelling (the recovery journal, C8's strategy
/// memory), so a rename is a migration, not a refactor.
/// `Codable` so C8's strategy memory can persist a strategy per app (`strategies.json`) —
/// the String raw values are the persisted spelling, which is exactly what a synthesized
/// conformance emits. Codable is stdlib: the Core import rule is untouched.
public enum InjectionRung: String, Sendable, CaseIterable, Codable {
    /// AX insertion into an allowlisted app, gated and read-back verified. Success without
    /// verification counts as failure (`ARCHITECTURE.md:400`) — the silent-lie catch.
    case accessibility
    /// The workhorse: save → set pasteboard → synthesize ⌘V → settle → restore
    /// (`ARCHITECTURE.md:405-415`).
    case clipboardPaste
    /// Synthesized unicode keystrokes, chunked and rate-limited — for fields that refuse paste.
    case keystrokeSynthesis
    /// The failsafe window: text held for the user to copy. Always succeeds — the floor under I1.
    case widgetFailsafe
}
