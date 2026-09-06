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
import Synchronization
import VoccaCore
@testable import VoccaUsage
import XCTest

/// The daily-use ledger's store — `usage-store/spec.md`'s C1–C12, in the
/// ``InjectionStrategyStoreTests`` shape it was planned against.
///
/// Like the strategy, dictionary and journal stores, `FileManager` works on a hosted runner, so
/// the real ``PersistentUsageStore`` runs here against **real temp directories**: a saved window
/// comes back from a fresh store over the same directory, a missing file loads empty silently,
/// and a load never rewrites the file. The injected file-system seam is what makes the failure
/// paths reachable and the injected log is what makes loudness assertable — both arrive with the
/// tolerance pins.
final class PersistentUsageStoreTests: XCTestCase {

    // MARK: - C1 · the round trip

    /// A window saved through the store comes back from a **fresh store over the same
    /// directory** — the restart, in the only form a test can stage it.
    ///
    /// This is the aspect's whole claim in one assertion: without it the ledger is a number that
    /// resets every launch, and a seven-day streak (`ROADMAP.md:102`) is unmeasurable by
    /// construction. It fails against the Phase 1 stub, which answers the empty window to every
    /// load.
    func testASavedWindowComesBackFromAFreshStoreOverTheSameDirectory() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = Self.twoDayWindow()

        try await PersistentUsageStore(directory: directory).save(saved)
        let loaded = await PersistentUsageStore(directory: directory).load()

        XCTAssertEqual(
            loaded, saved,
            "a window saved through the store must survive a restart — counts, rung tallies, "
                + "latency buckets and days, unchanged")
    }

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-usage-\(UUID().uuidString)")
    }

    /// Two days of real content: both columns used, three rungs credited, latencies in several
    /// buckets including the overflow one, and an onboarding loss that must not be folded into
    /// the real-work column by the format.
    private static func twoDayWindow() -> UsageWindow {
        var window = UsageWindow()
        window.insert(
            DayAggregate.folded(
                [
                    delivered(via: .accessibility, milliseconds: 90),
                    delivered(via: .accessibility, milliseconds: 140),
                    delivered(via: .clipboardPaste, milliseconds: 260),
                    heldByTheFailsafe(milliseconds: 7_000),
                    emptyPress(),
                ],
                on: day(2026, 9, 6)))
        window.insert(
            DayAggregate.folded(
                [
                    delivered(via: .clipboardPaste, milliseconds: 45),
                    lostTranscript(milliseconds: 310),
                    onboardingLoss(),
                ],
                on: day(2026, 9, 7)))
        return window
    }

    private static func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> CalendarDay {
        guard let day = CalendarDay(year: year, month: month, day: dayOfMonth) else {
            preconditionFailure("the fixture names a real date")
        }
        return day
    }

    private static func delivered(via rung: InjectionRung, milliseconds: Int) -> SessionRecord {
        record(outcome: .delivered(rung: rung, verified: true), milliseconds: milliseconds)
    }

    private static func heldByTheFailsafe(milliseconds: Int) -> SessionRecord {
        record(outcome: .failsafeHeld, milliseconds: milliseconds)
    }

    private static func lostTranscript(milliseconds: Int) -> SessionRecord {
        record(outcome: .lost, milliseconds: milliseconds)
    }

    /// A short press: nothing recorded, so it contributes a count and **no** latency sample.
    private static func emptyPress() -> SessionRecord {
        SessionRecord(
            id: SessionRecord.ID(rawValue: nextIdentifier()), outcome: .emptySkip,
            spans: [LatencySpan.cleanupNotPresent()], engine: nil, kind: .dictation)
    }

    private static func onboardingLoss() -> SessionRecord {
        SessionRecord(
            id: SessionRecord.ID(rawValue: nextIdentifier()), outcome: .lost,
            spans: [LatencySpan.recorded(name: .asr, elapsed: .milliseconds(500))], engine: nil,
            kind: .onboarding)
    }

    private static func record(
        outcome: SessionOutcomeClass, milliseconds: Int
    ) -> SessionRecord {
        SessionRecord(
            id: SessionRecord.ID(rawValue: nextIdentifier()), outcome: outcome,
            spans: [
                LatencySpan.recorded(name: .asr, elapsed: .milliseconds(milliseconds)),
                LatencySpan.cleanupNotPresent(),
            ],
            engine: nil, kind: .dictation)
    }

    /// Record identifiers are irrelevant to the aggregate — it folds counts — but they must be
    /// distinct so the fixture never reads as one record repeated.
    private static func nextIdentifier() -> Int {
        identifiers.withLock { value in
            value += 1
            return value
        }
    }

    private static let identifiers = Mutex<Int>(0)
}
