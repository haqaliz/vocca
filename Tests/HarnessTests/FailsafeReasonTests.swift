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
import VoccaCore
import VoccaInject
import VoccaUI
import XCTest

/// The two voice-processing ``FailsafeReason`` cases (`dictation-loop` PRD R5): the reason
/// vocabulary's growth is a **persisted-schema** change, so it is pinned where the schema is
/// consumed — the recovery journal — and where the copy is rendered, the FAILSAFE copy table.
///
/// The journal round trip runs over the **real** ``FileSystemJournalStore`` against a real temp
/// directory, not the recording double: the `reason` field is persisted as its raw spelling
/// (`JournalEntry.encode(to:)`), so only a real JSON encode→decode proves the spelling survives
/// the schema. The copy assertions pin the PRD's verbatim sentences and the reason-only rule
/// they carry: no held text exists, so no ladder affordance (⌘C / ⏎) may appear in the copy —
/// the `⌘C to paste` phrasing of the ladder reasons would be a lie here.
final class FailsafeReasonTests: XCTestCase {

    // MARK: - The journal round trip (the persisted schema is the consumer)

    /// `.modelUnavailable` survives the journal whole: hold, relaunch (a fresh journal over the
    /// same store — the process died and came back), read back, assert the reason came through
    /// with the raw spelling intact.
    func testModelUnavailableRoundTripsThroughTheRecoveryJournal() async throws {
        let directory = Self.tempJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = HeldTranscript(
            text: "nothing was ever held — reason-only notice",
            reason: .modelUnavailable, targetAppName: nil, capturedAt: .seconds(5))

        let first = try await RecoveryJournal(
            store: FileSystemJournalStore(directory: directory), capacity: 5)
        try await first.hold(held)

        let relaunched = try await RecoveryJournal(
            store: FileSystemJournalStore(directory: directory), capacity: 5)
        let current = await relaunched.current()
        XCTAssertEqual(current, held, "the held transcript must survive the relaunch whole")
        XCTAssertEqual(current?.reason, .modelUnavailable, "the reason must round-trip")
        XCTAssertEqual(
            current?.reason.rawValue, "modelUnavailable",
            "the persisted spelling must be the journal-safe raw value")
    }

    /// `.transcriptionFailed` survives the journal whole, identically: the schema vocabulary
    /// grows for both voice-processing reasons, not one.
    func testTranscriptionFailedRoundTripsThroughTheRecoveryJournal() async throws {
        let directory = Self.tempJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = HeldTranscript(
            text: "nothing was ever held — reason-only notice",
            reason: .transcriptionFailed, targetAppName: nil, capturedAt: .seconds(5))

        let first = try await RecoveryJournal(
            store: FileSystemJournalStore(directory: directory), capacity: 5)
        try await first.hold(held)

        let relaunched = try await RecoveryJournal(
            store: FileSystemJournalStore(directory: directory), capacity: 5)
        let current = await relaunched.current()
        XCTAssertEqual(current, held, "the held transcript must survive the relaunch whole")
        XCTAssertEqual(current?.reason, .transcriptionFailed, "the reason must round-trip")
        XCTAssertEqual(
            current?.reason.rawValue, "transcriptionFailed",
            "the persisted spelling must be the journal-safe raw value")
    }

    // MARK: - The rendered copy (no text held, no ladder affordances)

    /// `PRD R5` verbatim: the engine-not-ready sentence, target-app agnostic — and carrying no
    /// ⌘C / ⏎ ladder affordance, because there is no held text to copy or retry.
    func testModelUnavailableCopyIsNonEmptyAndCarriesNoLadderAffordances() {
        let copy = FailsafeCopy.reasonText(for: .modelUnavailable, targetAppName: "Mail")
        XCTAssertFalse(copy.isEmpty, "a shown reason must never render as an empty sentence")
        XCTAssertEqual(
            copy, "Voice processing isn't ready yet — try again in a moment.",
            "PRD R5's modelUnavailable sentence must render verbatim")
        XCTAssertFalse(copy.contains("⌘C"), "no held text exists — the copy affordance must not")
        XCTAssertFalse(copy.contains("⏎"), "no held text exists — the retry affordance must not")
    }

    /// `PRD R5` verbatim: the transcription-failure sentence, target-app agnostic — same
    /// no-affordance rule, same reason: nothing was held, nothing can be copied.
    func testTranscriptionFailedCopyIsNonEmptyAndCarriesNoLadderAffordances() {
        let copy = FailsafeCopy.reasonText(for: .transcriptionFailed, targetAppName: nil)
        XCTAssertFalse(copy.isEmpty, "a shown reason must never render as an empty sentence")
        XCTAssertEqual(
            copy, "Voice processing failed. Nothing was lost — you can try again.",
            "PRD R5's transcriptionFailed sentence must render verbatim")
        XCTAssertFalse(copy.contains("⌘C"), "no held text exists — the copy affordance must not")
        XCTAssertFalse(copy.contains("⏎"), "no held text exists — the retry affordance must not")
    }

    // MARK: - Fixtures

    private static func tempJournalDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-failsafe-reason-\(UUID().uuidString)")
    }
}
