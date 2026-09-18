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

/// **The `ContextProvider` seam's real implementation** — the focused application and its
/// selection, resolved through the two injected module-internal reads.
///
/// The decisions that stand between the raw reads and the seam's ``ContextSnapshot`` are here,
/// and only here:
///
/// - **Secure Input refusal is ordered before the AX call** (PRD M5b, D3): when
///   ``ContextSecureInputReading`` answers `true`, the resolution is the empty snapshot and the
///   AX read is **never consulted** — for a password field, never *ask*. Asserted with a
///   recording fake (zero ``ContextAXReading`` calls when the secure-input fake answers true).
/// - **A failed or timed-out read is the empty snapshot, never a throw** (R1): `nil` at the
///   seam — a failed AX copy or a timed-out call — resolves to the all-absent snapshot, the
///   ``NullContext``-style honesty the seam's contract names. The 0.5 s per-call budget itself
///   is the raw file's translation property (`AXContextSource`), reviewed, not asserted here.
/// - **`""` is present-but-empty and passes through as itself** — a collapsed selection is not
///   "no selection"; `nil` stays `nil`.
///
/// The window title is carried for the failsafe copy's "{app}" vocabulary; it is not a decision.
///
/// ## Isolation
///
/// An **actor**, for the same reason ``TargetResolution`` is: the focused-app query is an AX
/// call, and `ARCHITECTURE.md:323`'s rule is that AX calls never run on the main thread. The
/// conformance witness is `nonisolated` and synchronous because the merged seam's
/// `resolveCurrent()` is synchronous (`ContextProvider.swift:47`) — an actor-isolated witness
/// cannot satisfy a nonisolated synchronous requirement — and the AX work still never runs on
/// the caller's thread: the raw file dispatches every call onto its own serial queue under the
/// per-call timeout, which is how the rule is satisfied for this module. The seams are
/// `let`-bound `Sendable` references, so the `nonisolated` witness reads them safely.
///
/// The adapter is **consent-agnostic** (D7): it reads what it is asked to; the never-read gate
/// over consent is the `consent-store` aspect's, asserted there with recording fakes.
public actor AccessibilityContext: ContextProvider {
    private let axRead: any ContextAXReading
    private let secureInputRead: any ContextSecureInputReading

    public init(
        axRead: any ContextAXReading,
        secureInputRead: any ContextSecureInputReading
    ) {
        self.axRead = axRead
        self.secureInputRead = secureInputRead
    }

    /// One resolution: Secure Input refused → the empty snapshot; else the raw read, with `nil`
    /// (failure or timeout) resolving to the empty snapshot — never a throw.
    public nonisolated func resolveCurrent() -> ContextSnapshot {
        guard !secureInputRead.isSecureInputActive() else {
            return ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: nil)
        }
        guard let raw = axRead.readContext() else {
            return ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: nil)
        }
        return ContextSnapshot(
            bundleID: raw.bundleID, windowTitle: raw.windowTitle, selectedText: raw.selectedText)
    }
}