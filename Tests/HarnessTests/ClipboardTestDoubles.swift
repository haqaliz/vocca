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

@testable import VoccaInject

// The doubles the clipboard rung's suite is driven through, shared by every test in
// `ClipboardRungTests.swift`.
//
// Shared rather than copied, for the reason `SessionTestDoubles.swift` gives at its top: the
// clipboard protocol's whole contract — the save→set→paste→settle→restore ordering, the
// never-clobber rule, the failure paths — is measured against these objects, and a second copy
// that drifted from this one would let one test pass against a rung that behaves differently
// from the one the others measure.

/// One clipboard-protocol event, as the ordering tests read it.
///
/// The two events the rung itself never touches — ``ClipboardProtocolEvent/paste`` and
/// ``ClipboardProtocolEvent/settle(_:)`` — are appended to the same log by the injected
/// keystroke seam and the injected settle closure, so the protocol's *whole* ordering
/// (`ARCHITECTURE.md:408-414`) lands in one place: save, set, ⌘V, settle, ownership check,
/// restore-if-ours. A log that could not show where the paste and the settle sat would leave the
/// two hazards no other test visits — pasting the old clipboard, and restoring before the paste
/// consumed ours.
enum ClipboardProtocolEvent: Equatable, CustomStringConvertible {
    case snapshot
    case set(String)
    case paste
    case settle(Duration)
    case changeCountRead
    case restore
    case readBack

    var description: String {
        switch self {
        case .snapshot: return "snapshot"
        case .set(let text): return "set(\(text.debugDescription))"
        case .paste: return "paste"
        case .settle(let delay): return "settle(\(delay))"
        case .changeCountRead: return "changeCount"
        case .restore: return "restore"
        case .readBack: return "readBack"
        }
    }
}

/// The one log every double writes into, so the ordering claims read a single interleaved
/// sequence rather than three logs a test would have to merge by hand (and, in merging, could
/// get wrong in the direction that matters — where the paste sits).
///
/// Deliberately not `@MainActor`: the keystroke seam's `pressPaste()` is a *synchronous*
/// requirement, and a main-actor-isolated witness cannot satisfy a nonisolated synchronous one
/// (the `#ConformanceIsolation` rule — there is no hop for a sync call). Every append still
/// lands on the main actor in practice — the rung is `@MainActor`, so `pressPaste`, the settle
/// closure and the pasteboard double all run there — but the log and the keystroke double must
/// not *declare* the isolation the conformance forbids.
final class ClipboardProtocolLog {
    private(set) var events: [ClipboardProtocolEvent] = []

    func append(_ event: ClipboardProtocolEvent) {
        events.append(event)
    }
}

/// **The pasteboard, with the manager taken out** — the one thing CI can execute, because the
/// real `SystemPasteboard` is session-bound and the real one the ordering tests describe has to
/// be simulated anyway.
///
/// It is a `@MainActor` class rather than an actor, and deliberately so: nothing crosses an
/// isolation boundary in these tests — the rung is `@MainActor`, so the double is confined to
/// the same domain, and an actor would split the one event log the ordering claim is made
/// against into two. The honest boundary here is the shared log, not the isolation domain; the
/// ``StubEngine`` precedent is for doubles that must cross one.
///
/// ## The simulation
///
/// ``set(text:)`` advances the change count once for the write, and — when
/// ``takesOwnershipAfterSet`` is set — once more *after* returning its value, exactly as a
/// clipboard manager (Raycast, Alfred, Paste, Maccy) does: the pasteboard's count moves under
/// our feet between the write and the ownership check, which is the race
/// `ARCHITECTURE.md:412-414` names. The value `set` returns is the count immediately after the
/// write, so the rung's later ``currentChangeCount()`` read is what exposes the takeover.
@MainActor
final class FakePasteboardManager: PasteboardManaging {
    /// The change count at the start of the run — what a `snapshot()` taken before anything
    /// happens must carry, so a test can prove the snapshot restored is the snapshot saved.
    let initialChangeCount: Int
    /// When `true`, the count moves once more after `set` returns, simulating a clipboard
    /// manager that took ownership of the pasteboard between our write and our check.
    let takesOwnershipAfterSet: Bool
    /// When `true`, `snapshot()` answers `nil` — the rung must refuse before writing anything.
    let failsSnapshot: Bool
    /// When `true`, `set(text:)` answers `nil` — the write failed, so no paste may follow.
    let failsSet: Bool

    private var changeCountValue: Int
    private var text: String?
    private let log: ClipboardProtocolLog

    /// The snapshot the rung asked to restore; `nil` until (and unless) a restore happens.
    private(set) var restoredSnapshot: PasteboardSnapshot?

    init(
        log: ClipboardProtocolLog,
        initialChangeCount: Int = 1,
        takesOwnershipAfterSet: Bool = false,
        failsSnapshot: Bool = false,
        failsSet: Bool = false
    ) {
        self.log = log
        self.initialChangeCount = initialChangeCount
        self.changeCountValue = initialChangeCount
        self.takesOwnershipAfterSet = takesOwnershipAfterSet
        self.failsSnapshot = failsSnapshot
        self.failsSet = failsSet
    }

    // MARK: - PasteboardManaging

    func snapshot() async -> PasteboardSnapshot? {
        log.append(.snapshot)
        guard !failsSnapshot else { return nil }
        return PasteboardSnapshot(changeCount: changeCountValue, items: [])
    }

    func set(text: String) async -> Int? {
        log.append(.set(text))
        guard !failsSet else { return nil }
        self.text = text
        changeCountValue += 1
        let countAfterOurWrite = changeCountValue
        if takesOwnershipAfterSet {
            changeCountValue += 1
        }
        return countAfterOurWrite
    }

    func restore(_ snapshot: PasteboardSnapshot) async {
        log.append(.restore)
        restoredSnapshot = snapshot
        text = nil
        changeCountValue = snapshot.changeCount + 1
    }

    func readBack() async -> String? {
        log.append(.readBack)
        return text
    }

    func currentChangeCount() async -> Int? {
        log.append(.changeCountRead)
        return changeCountValue
    }
}

/// **The keystroke seam, as a counter** — the ⌘V the rung must issue between its write and its
/// settle, and the one assertion that pins it: `pressPaste()` exactly once, and the paste event
/// in the shared log where the ordering claims can see it.
///
/// Not isolated, for the reason ``ClipboardProtocolLog`` gives: `pressPaste()` is a synchronous
/// requirement, and isolation on the witness is what the conformance check forbids. The rung
/// calls it on the main actor, which is where its log append lands.
final class FakeKeystrokeSource: KeystrokeSynthesizing {
    private let log: ClipboardProtocolLog

    /// How many times `pressPaste()` was called — the "exactly once" half of the claim.
    private(set) var pasteCount = 0

    init(log: ClipboardProtocolLog) {
        self.log = log
    }

    func typeText(_ text: String, chunkSize: Int) {}

    func pressPaste() {
        pasteCount += 1
        log.append(.paste)
    }
}
