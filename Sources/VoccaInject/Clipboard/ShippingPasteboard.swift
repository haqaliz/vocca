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

/// The pasteboard write the FAILSAFE window's ⌘C routes to, exposed to the composition root.
///
/// `FailsafePanel`'s copy handler is injected (`FailsafePanel.swift:67-71`), and the pasteboard
/// adapter — ``SystemPasteboard`` — is module-internal behind the H7 per-seam table (the one
/// `NSPasteboard` file in `VoccaInject`). This is the seam between the two, in the same shape as
/// ``ShippingLadder``: a public composition surface over the internal adapter, naming no
/// pasteboard identifier itself.
///
/// The write is the whole of the ⌘C contract — "the pill offers the transcript's whole text"
/// (`PRODUCT_SPEC.md:106`) — and nothing more: the change count, the restore and the ownership
/// check are the clipboard rung's concerns, not the copy affordance's.
@MainActor
public enum ShippingPasteboard {

    /// Writes `text` to the general pasteboard — the FAILSAFE window's ⌘C route.
    ///
    /// The handler is `(HeldTranscript) -> Void`, so the root's wiring wraps this in a `Task`;
    /// the write itself is asynchronous through the seam.
    public static func write(_ text: String) async {
        _ = await SystemPasteboard().set(text: text)
    }
}
