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

/// The plain-data vocabulary the context seam hands over: what the focused application and
/// selection looked like at the moment of a turn's start (`context-provider` PRD M1 — the
/// active app and selection; `ARCHITECTURE.md:281` names the seam and its implementations).
///
/// Deliberately small and deliberately free of system types — `VoccaCore` imports nothing, so
/// a Core-owned snapshot could not name `AXUIElement` anyway, but the reason is design rather
/// than capability: the seam's contract must be testable over a snapshot a test builds by
/// hand, and an opaque handle a test cannot fabricate would make the whole seam untestable
/// above the adapter.
///
/// The three fields' nil semantics are part of the contract — **`nil` is absent, `""` is
/// present-but-empty**:
///
/// - `bundleID == nil` means nothing is focused; `""` would mean a focused app the adapter
///   could not identify;
/// - `windowTitle == nil` means there is no title to report; `""` means a titleless window;
/// - `selectedText == nil` means there is no selection; `""` means a collapsed (empty)
///   selection.
///
/// ``NullContext`` returns the all-absent snapshot; the later `AccessibilityContext` returns
/// whichever is honest. Consumers must not conflate the two.
///
/// Snapshots are **ephemeral per turn, never persisted** (PRD M10, `prd.md:119-121`) and never
/// travel in a BYOK payload without the separate grant (`byok-context-grant`'s aspect) — this
/// vocabulary is consumed immediately at the turn's start and discarded. It deliberately does
/// not reuse `TargetContext` (the injection path's carrier): the snapshot is a different
/// carrier for a different seam, and the never-persisted boundary attaches to *it*, not to the
/// dictate path's metadata. Tests build these by hand, so the init is public and free of
/// defaults that could hide a missing adapter read.
public struct ContextSnapshot: Sendable, Equatable {
    /// The focused application's bundle identifier; `nil` when nothing is focused.
    public let bundleID: String?
    /// The focused window's title; `nil` when there is none to report.
    public let windowTitle: String?
    /// The focused field's selection; `nil` when there is no selection.
    public let selectedText: String?

    /// A snapshot as the adapter observed it: the focused app, its window, and its selection.
    public init(bundleID: String?, windowTitle: String?, selectedText: String?) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.selectedText = selectedText
    }
}