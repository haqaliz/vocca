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

import Foundation

/// One pasteboard item as the seam understands it: a type name and the bytes behind it.
///
/// The type is spelled as a `String` rather than an AppKit type so this file — the seam's home —
/// names no `NSPasteboard` identifier at all; the one file permitted to speak the family
/// (`SystemPasteboard.swift`) translates both directions. This is the H7 rule in its two-sided
/// form: the seam carries the vocabulary the adapter translates, and the adapter carries the
/// system call the seam cannot name.
struct PasteboardItem: Sendable, Equatable {
    /// The uniform type identifier of the item's data (`NSPasteboard.PasteboardType.rawValue`).
    let type: String
    /// The item's bytes, exactly as they were read.
    let data: Data

    init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// Everything the pasteboard held at one instant: every item of every type, plus the change
/// count that instant carried.
///
/// ``changeCount`` is the snapshot's identity for the never-clobber rule: the clipboard rung
/// compares the count `set` returned against the count the pasteboard carries *after* the settle,
/// and restores this snapshot only when the two still agree (`ARCHITECTURE.md:408-414`). The
/// items are what the restore puts back — all types, not just `.string`, because a snapshot that
/// saved only the string would silently destroy everything else a clipboard manager keeps there.
struct PasteboardSnapshot: Sendable, Equatable {
    /// The change count the pasteboard carried when the items were read.
    let changeCount: Int
    /// Every item on the pasteboard, in read order, across every type.
    let items: [PasteboardItem]

    init(changeCount: Int, items: [PasteboardItem]) {
        self.changeCount = changeCount
        self.items = items
    }
}

/// **The pasteboard, taken out of the clipboard rung** — the seam `ARCHITECTURE.md:405-415`'s
/// protocol is decided over, in the ``ClipboardRungStrategy``/``SystemPasteboard`` split.
///
/// Four raw operations and one read, nothing more:
///
/// - ``snapshot()`` — everything on the pasteboard and its change count, or `nil` when the
///   pasteboard cannot be read at all (the rung refuses before writing if it cannot save);
/// - ``set(text:)`` — write the text, and **note the new change count**: the returned count is
///   the pasteboard's identity while our text is on it;
/// - ``restore(_:)`` — put a saved snapshot back;
/// - ``readBack()`` — what the pasteboard holds as a string, raw;
/// - ``currentChangeCount()`` — the pasteboard's count right now, the read the never-clobber
///   comparison is made against.
///
/// **No decision lives here.** Whether to restore — *only if the count is still ours* — is the
/// rung's, and the rung alone; the seam answers what the pasteboard is and what it did. The one
/// file permitted to name `NSPasteboard` is ``SystemPasteboard``, the concrete conformance;
/// everything else in `VoccaInject` speaks through this protocol, exactly as the tap adapter's
/// decisions all sit above the seam.
///
/// `Sendable`, because the rung awaits it across suspension points and the tests drive it through
/// an actor-shaped fake; the concrete conformance is a stateless wrapper around the (thread-safe)
/// general pasteboard.
protocol PasteboardManaging: Sendable {
    /// Everything the pasteboard holds now, with its change count; `nil` when the pasteboard
    /// cannot be read at all.
    func snapshot() async -> PasteboardSnapshot?

    /// Replace the pasteboard's contents with `text`, and return the pasteboard's change count
    /// immediately after the write — the count that means "ours". `nil` when the write failed,
    /// in which case nothing was written and nothing is claimed.
    func set(text: String) async -> Int?

    /// Put a saved snapshot back onto the pasteboard. The caller decides *when*; this operation
    /// only translates.
    func restore(_ snapshot: PasteboardSnapshot) async

    /// What the pasteboard holds as a string, raw; `nil` when it holds no string.
    func readBack() async -> String?

    /// The pasteboard's change count right now — the read the never-clobber comparison is made
    /// against, taken *after* the settle so a manager's move is visible.
    func currentChangeCount() async -> Int?
}
