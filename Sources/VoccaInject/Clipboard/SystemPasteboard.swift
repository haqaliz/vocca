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

import AppKit

/// **The pasteboard adapter — the one file in `VoccaInject` permitted to speak NSPasteboard.**
///
/// The clipboard rung's protocol (`ARCHITECTURE.md:405-414`) is decided above this file, in
/// ``ClipboardRungStrategy``, over the ``PasteboardManaging`` seam; what is left here is
/// translation and nothing else — the four raw operations a snapshot/write/restore round trip
/// needs, in `NSPasteboard` terms, with no decision in any of them.
///
/// The H9-style pasteboard seam lint (`InjectionSeamBoundaryTests`' pasteboard family table)
/// permits exactly this one file to name `NSPasteboard`/`NSPasteboardItem`, and nothing else in
/// `Sources/` may — the same one-file-per-seam rule the keystroke adapter is held to for
/// CoreGraphics. Every `if` this file *could* grow is a decision that belongs to the rung: the
/// "should I restore" question (`ARCHITECTURE.md:412-414`) is the rung's, asked of
/// ``PasteboardManaging/currentChangeCount()`` after the settle, and this file only ever answers
/// what the pasteboard is and what it did.
///
/// Like the keystroke adapter, this file is **executed by nothing in CI**. A pasteboard is
/// session-bound — a hosted runner has no window session worth saving — so the suite drives the
/// whole protocol over the injected seam and a racing fake manager, and the real board is
/// exercised by the smoke checklist's real-app steps.
///
/// ## Isolation
///
/// A stateless wrapper with no isolation of its own: the async methods run on whatever executor
/// the rung calls them from (the main actor, like the rest of the latency path), and
/// `NSPasteboard.general` is the one thread-safe AppKit surface this pipeline touches.
final class SystemPasteboard: PasteboardManaging {

    init() {}

    // MARK: - PasteboardManaging

    /// Everything the general pasteboard holds, item by item, type by type, with the change
    /// count read at the same instant. An empty pasteboard is a legitimate snapshot — it is not
    /// a read failure — so `nil` is reserved for the cases this wrapper cannot reach anyway; the
    /// failure channel exists for the seam's shape, not for a pasteboard that is merely empty.
    func snapshot() async -> PasteboardSnapshot? {
        let pasteboard = NSPasteboard.general
        let items: [PasteboardItem] = (pasteboard.pasteboardItems ?? []).flatMap { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return PasteboardItem(type: type.rawValue, data: data)
            }
        }
        return PasteboardSnapshot(changeCount: pasteboard.changeCount, items: items)
    }

    /// Replace the general pasteboard's contents with `text` and return the change count
    /// immediately after the write — the "ours" identity the rung compares against later. `nil`
    /// when the write itself failed, so a board our text is not on is never claimed as ours.
    ///
    /// `clearContents()` answers the *new* change count rather than a success bit — it has no
    /// failure channel to guard on — so it is discarded and the string write's own answer is
    /// the one carried.
    func set(text: String) async -> Int? {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return nil }
        return pasteboard.changeCount
    }

    /// Put a saved snapshot back: clear, then write every saved item back under its type.
    ///
    /// The caller (the rung) decided *whether* — this file only translates *how*. The type round
    /// trip through `rawValue` is lossless: `PasteboardType` is a string wrapper, so a type read
    /// as `String` is written back as exactly the type it was.
    func restore(_ snapshot: PasteboardSnapshot) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        for item in snapshot.items {
            pasteboard.setData(item.data, forType: NSPasteboard.PasteboardType(item.type))
        }
    }

    /// What the general pasteboard holds as a string, raw.
    func readBack() async -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// The general pasteboard's change count right now.
    func currentChangeCount() async -> Int? {
        NSPasteboard.general.changeCount
    }
}
