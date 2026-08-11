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

/// **The clipboard rung — the injection ladder's workhorse, decided over the pasteboard seam.**
///
/// `ARCHITECTURE.md:405-415`'s clipboard protocol, in the order that makes it safe:
///
/// 1. snapshot the pasteboard — every type, not just the string, plus the change count;
/// 2. write our text, noting the pasteboard's new change count ("ours");
/// 3. synthesize ⌘V through the injected keystroke seam — the one `CGEvent` this module's
///    clipboard files never name;
/// 4. settle for the injected delay, so the focused app has time to consume the paste;
/// 5. restore the snapshot — **only if the change count is still ours**. A clipboard manager
///    (Raycast, Alfred, Paste, Maccy) that took the pasteboard while we were settling must not
///    be clobbered: leaving our text there is better than stomping the manager's own snapshot
///    (`ARCHITECTURE.md:412-414`).
///
/// Every one of those steps is a decision, and every decision is in this file, over the
/// ``PasteboardManaging`` and ``KeystrokeSynthesizing`` seams — the exact inverse of
/// ``SystemPasteboard``, which translates `NSPasteboard` calls and decides nothing. The whole
/// protocol therefore runs headless over fakes, including the manager race.
///
/// ## Answers with raw truth
///
/// The clipboard rung has no read-back, so it reports `.succeeded(verified: false)` — plain
/// success with no verification claim (`verified` is for AX read-back, `ARCHITECTURE.md:399-400`),
/// and interpreting an unverified success is the decision function's, never this conformance's.
/// A snapshot that cannot be saved and a write that fails both report `.failed`: the first
/// because a pasteboard we cannot restore must not be written over at all, the second because
/// there is nothing to paste.
///
/// ## Isolation
///
/// `@MainActor`, like the ladder that awaits it: the whole latency path lives in one isolation
/// domain (`ARCHITECTURE.md:271`), the keystroke seam it holds is not `Sendable`, and the
/// injected ``PasteboardManaging`` is hopped to across the suspension points. ``InjectionRungStrategy``'s
/// `Sendable` requirement is satisfied by the isolation.
@MainActor
final class ClipboardRungStrategy: InjectionRungStrategy {

    /// This strategy implements the clipboard-paste rung.
    let rung: InjectionRung = .clipboardPaste

    private let pasteboard: any PasteboardManaging
    private let keystrokes: any KeystrokeSynthesizing

    /// The settle delay the protocol's step 4 requires — an injected value so the suite can
    /// drive the whole protocol with no real waiting, defaulting to the ~80 ms
    /// `ARCHITECTURE.md:408-414` names. **The default is pinned in exactly this one place** —
    /// the only occurrence of the literal in the file.
    private let settleDelay: Duration

    /// The mechanism the settle uses, injected for the ordering tests to witness: the delay
    /// itself is ``settleDelay``, and this closure is what "waiting" means. The shipped default
    /// sleeps on the standard library's clock for exactly the injected duration.
    private let settle: (Duration) async -> Void

    /// - Parameters:
    ///   - pasteboard: The pasteboard seam. ``SystemPasteboard`` is the shipped conformance;
    ///     tests inject a fake that simulates the manager race.
    ///   - keystrokes: The ⌘V seam — the ``KeystrokeSource`` adapter in production, a counting
    ///     fake in the suite. The clipboard files never name a `CGEvent`.
    ///   - settleDelay: The delay between the paste and the ownership check, default 80 ms.
    ///   - settle: The waiting mechanism; defaults to `Task.sleep(for:)`.
    init(
        pasteboard: any PasteboardManaging,
        keystrokes: any KeystrokeSynthesizing,
        settleDelay: Duration = .milliseconds(80),
        settle: @escaping (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.pasteboard = pasteboard
        self.keystrokes = keystrokes
        self.settleDelay = settleDelay
        self.settle = settle
    }

    // MARK: - InjectionRungStrategy

    func tryInject(_ text: String, into target: TargetContext) async -> RungAttempt {
        // Step 1: save everything, or refuse to write at all. Without a snapshot there is
        // nothing to restore, so a write would permanently replace the user's clipboard — the
        // never-clobber doctrine in its first half (`ARCHITECTURE.md:413`).
        guard let saved = await pasteboard.snapshot() else { return .failed }

        // Step 2: write, and keep the pasteboard's identity while our text is on it.
        guard let ourChangeCount = await pasteboard.set(text: text) else { return .failed }

        // Step 3: the ⌘V — through the seam, exactly once.
        keystrokes.pressPaste()

        // Step 4: give the focused app time to consume the paste before we take the board back.
        await settle(settleDelay)

        // Step 5: restore only if the count is still ours. A manager that took ownership moved
        // the count under our feet; restoring now would stomp its snapshot, which is worse than
        // leaving our text where the manager now owns it (`ARCHITECTURE.md:412-414`).
        if await pasteboard.currentChangeCount() == ourChangeCount {
            await pasteboard.restore(saved)
        }

        // The paste happened; the rung reports what it did, with no read-back to invent one.
        return .succeeded(verified: false)
    }
}
