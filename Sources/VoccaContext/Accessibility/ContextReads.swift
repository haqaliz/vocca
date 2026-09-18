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

/// **The raw context answer, as the AX system reported it** — the focused application's bundle
/// identifier, its focused window's title, and its selection, before any decision about what
/// they mean.
///
/// `bundleID == nil` when the query answered "nothing focused" *or* the focused application
/// yielded no bundle identifier; `windowTitle == nil` when there is no focused window to name;
/// `selectedText == nil` when there is no selection to report. `""` is present-but-empty —
/// a titleless window, a collapsed selection — and passes through as itself (the
/// ``ContextSnapshot`` contract's nil semantics, `ContextSnapshot.swift:25-35`). The AX element
/// itself never leaves the adapter: this struct is the whole answer the context read carries
/// across the seam, and it is buildable by a test — which is exactly what makes the adapter
/// headless-testable.
public struct RawContextRead: Sendable, Equatable {
    /// The focused application's bundle identifier; `nil` when nothing is focused or the
    /// focused application has none.
    public var bundleID: String?
    /// The focused window's title; `nil` when there is none to report.
    public var windowTitle: String?
    /// The focused field's selection; `nil` when there is no selection.
    public var selectedText: String?

    public init(bundleID: String?, windowTitle: String?, selectedText: String?) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.selectedText = selectedText
    }
}

/// **The seam for "what is the focused application and its selection right now"** — the AX
/// focused-app and selected-text read, taken out of the adapter so resolution is
/// headless-testable (the ``FocusedAppReading`` shape, `TargetResolution.swift:58-74`).
///
/// Answer the question **now**, every time. The focused application is a fact that changes under
/// Vocca's feet with no notification, and a cached answer would be a report of the world as it
/// was at some earlier resolution.
///
/// Synchronous, because the seam it feeds — ``ContextProvider``'s `resolveCurrent()` — is
/// synchronous (the context-seam's pinned contract: "a failure resolves to an empty snapshot,
/// never throws — expressed in the type system"). The real conformance runs its AX calls on a
/// dedicated serial queue under a per-call timeout, so "AX calls never run on the main thread"
/// holds at the queue, exactly as it does in `AXSource`. Class-bound (`AnyObject`) for the
/// reason every other state-read seam in this repo is: a value-typed conformance would be
/// copied at construction, and a state read copied is a snapshot — the fake could not express
/// focus changing between resolutions.
public protocol ContextAXReading: AnyObject, Sendable {
    /// The focused application's identity and selection, raw; `nil` when any part cannot be
    /// read (including a timeout).
    func readContext() -> RawContextRead?
}

/// **The seam for "is Secure Input in force right now"** — the Carbon read, taken out of the
/// adapter so the refusal is headless-testable.
///
/// Answer the question **now**, every time — Secure Input is a state that changes with no
/// notification, and the refusal depends on the fresh read (PRD M5b). Synchronous for the same
/// reason ``ContextAXReading`` is: the consumer's conformance witness is synchronous. Class-bound
/// for the same reason ``ContextAXReading`` is.
public protocol ContextSecureInputReading: AnyObject, Sendable {
    /// `true` when some application is holding Secure Input and no event tap is receiving key
    /// events.
    func isSecureInputActive() -> Bool
}