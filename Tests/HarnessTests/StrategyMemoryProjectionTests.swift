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
import XCTest

/// The projection: how a per-app ``InjectionStrategy`` becomes the rung order the next dictation
/// attempts, and the re-probe eligibility query that drives it (`core-memory/spec.md` M2/M3/M4).
///
/// The load-bearing decisions, each with a row below:
///
/// - the projection is **canonical order minus demotions**: a demoted rung is dropped until its
///   window, and re-included once `now >= window` (inclusive, pinned both directions) — the
///   one-shot re-probe is *record*-side, so the projection stays idempotent (M6);
/// - `.accessibility` is gated twice: the allowlist gate (`allowlisted || learnedAllowlist`) and
///   the re-probe — an elapsed re-probe **beats** the gate, which is the R6 promotion probe's
///   projection shape: a seeded hostile app is re-offered AX after its window (`seeds are data,
///   not decisions`);
/// - `.clipboardPaste` is never dropped — not even from a hand-built strategy that puts it in
///   `demotedRungs` — so the projection is never empty (X3), and `.widgetFailsafe` never appears
///   in a strategy at all;
/// - a demoted rung with **no** window entry is never re-included (M4 — tolerant-decode strays
///   stay on clipboard; the store aspect inherits this decision);
/// - the two named constants — `reprobeWindowSeconds` (PROVISIONAL, re-baselined by the founder's
///   matrix run) and `canonicalRungOrder` — live in exactly one production file, pinned by scan
///   below (the ``WarmStartTargets`` precedent).
final class StrategyMemoryProjectionTests: XCTestCase {

    // MARK: - The canonical order and the allowlist gate

    /// A fresh strategy for an allowlisted app projects the canonical order, whatever `now` is.
    func testTheProjectionStartsWithTheCanonicalOrder() {
        let projection = StrategyMemory.orderedRungs(
            for: InjectionStrategy(), allowlisted: true, now: 0)
        XCTAssertEqual(projection, [.accessibility, .clipboardPaste, .keystrokeSynthesis])
    }

    /// The allowlist gate: a non-allowlisted app that has not learned anything never sees the AX
    /// rung — every Electron/browser app starts on clipboard (the seeded allowlist's promise).
    func testAccessibilityIsExcludedForANonAllowlistedAppUntilLearned() {
        let projection = StrategyMemory.orderedRungs(
            for: InjectionStrategy(), allowlisted: false, now: 0)
        XCTAssertEqual(projection, [.clipboardPaste, .keystrokeSynthesis])
    }

    /// An allowlisted app projects AX — the seeded three-app blessing, unchanged.
    func testAccessibilityIsIncludedForAnAllowlistedApp() {
        let projection = StrategyMemory.orderedRungs(
            for: InjectionStrategy(), allowlisted: true, now: 123_456_789)
        XCTAssertEqual(projection, [.accessibility, .clipboardPaste, .keystrokeSynthesis])
    }

    /// Learning is the second way through the gate: a non-allowlisted app that earned a
    /// read-back-verified AX win projects AX from then on.
    func testAccessibilityIsIncludedWhenLearned() {
        let learned = InjectionStrategy(learnedAllowlist: true)
        let projection = StrategyMemory.orderedRungs(
            for: learned, allowlisted: false, now: 0)
        XCTAssertEqual(projection, [.accessibility, .clipboardPaste, .keystrokeSynthesis])
    }

    // MARK: - Demotion and the re-probe window

    /// A demoted rung is dropped while its window is in the future — the retry that cost the user
    /// once is not offered again until the decay schedule says so.
    func testADemotedRungIsDroppedUntilItsWindow() {
        let strategy = InjectionStrategy(
            demotedRungs: [.keystrokeSynthesis],
            reprobeWindows: [.keystrokeSynthesis: 1_000])
        let projection = StrategyMemory.orderedRungs(
            for: strategy, allowlisted: true, now: 999)
        XCTAssertEqual(projection, [.accessibility, .clipboardPaste])
    }

    /// The re-probe window is inclusive: at exactly `now == window` the demoted rung is offered
    /// once more, and it stays offered while the window stays elapsed — the projection is a pure
    /// function of `(strategy, allowlisted, now)`, so "still owed" is visible until a record
    /// consumes it (M6, O4).
    func testADemotedRungIsReIncludedOnceItsWindowElapses() {
        let strategy = InjectionStrategy(
            demotedRungs: [.keystrokeSynthesis],
            reprobeWindows: [.keystrokeSynthesis: 1_000])
        XCTAssertEqual(
            StrategyMemory.orderedRungs(for: strategy, allowlisted: true, now: 1_000),
            [.accessibility, .clipboardPaste, .keystrokeSynthesis])
        XCTAssertEqual(
            StrategyMemory.orderedRungs(for: strategy, allowlisted: true, now: 1_001),
            [.accessibility, .clipboardPaste, .keystrokeSynthesis])
    }

    /// One second before the window the rung is still dropped — the inclusive boundary is pinned
    /// in both directions.
    func testARungWhoseWindowHasNotElapsedStaysDropped() {
        let strategy = InjectionStrategy(
            demotedRungs: [.keystrokeSynthesis],
            reprobeWindows: [.keystrokeSynthesis: 1_000])
        XCTAssertEqual(
            StrategyMemory.orderedRungs(for: strategy, allowlisted: true, now: 999),
            [.accessibility, .clipboardPaste])
    }

    /// A demoted rung with **no** window entry is never re-included, at any `now` — tolerant-
    /// decode strays stay on clipboard forever, an acceptable degradation the store aspect owns
    /// (O3).
    func testADemotedRungWithoutAWindowIsNeverReIncluded() {
        let strategy = InjectionStrategy(demotedRungs: [.keystrokeSynthesis])
        XCTAssertEqual(
            StrategyMemory.orderedRungs(
                for: strategy, allowlisted: true, now: .max),
            [.accessibility, .clipboardPaste])
    }

    // MARK: - The guarantee rows

    /// The projection is never empty: with every real rung demoted behind a future window, the
    /// clipboard remains — the floor under the strategy (X3).
    func testTheProjectionIsNeverEmpty() {
        let strategy = InjectionStrategy(
            demotedRungs: [.accessibility, .keystrokeSynthesis],
            reprobeWindows: [
                .accessibility: 1_000,
                .keystrokeSynthesis: 1_000,
            ])
        let projection = StrategyMemory.orderedRungs(
            for: strategy, allowlisted: true, now: 0)
        XCTAssertEqual(projection, [.clipboardPaste])
    }

    /// The never-empty guarantee holds against **invalid** state, not just valid: a hand-built
    /// strategy that puts clipboard in `demotedRungs` still projects clipboard — the projection
    /// never trusts a demotion of the workhorse.
    func testClipboardIsNeverDroppedEvenFromAHandBuiltStrategy() {
        let strategy = InjectionStrategy(
            demotedRungs: [.clipboardPaste],
            reprobeWindows: [.clipboardPaste: 1_000])
        let projection = StrategyMemory.orderedRungs(
            for: strategy, allowlisted: true, now: 0)
        XCTAssertEqual(projection, [.accessibility, .clipboardPaste, .keystrokeSynthesis])
    }

    /// `.widgetFailsafe` never appears in a projection — it is the floor under I1, not a rung to
    /// learn from, so no strategy may mention it.
    func testWidgetFailsafeNeverAppearsInAProjection() {
        let fresh = StrategyMemory.orderedRungs(
            for: InjectionStrategy(), allowlisted: false, now: 0)
        XCTAssertFalse(fresh.contains(.widgetFailsafe))

        let demoted = StrategyMemory.orderedRungs(
            for: InjectionStrategy(demotedRungs: [.keystrokeSynthesis]),
            allowlisted: false, now: .max)
        XCTAssertFalse(demoted.contains(.widgetFailsafe))
    }

    // MARK: - The seeded hostile shape

    /// The seed a hostile app starts as — AX demoted at seed time with a window a re-probe window
    /// out — projects without AX on the first dictation: the discovery cost is paid by the seed,
    /// not by the user (R5, `CAPABILITY_ROADMAP.md:185`).
    func testTheSeededHostileShapeExcludesAccessibilityOnTheFirstDictation() {
        let seedTime: UInt64 = 1_000_000
        let seeded = InjectionStrategy(
            demotedRungs: [.accessibility],
            learnedAllowlist: false,
            reprobeWindows: [
                .accessibility: seedTime + StrategyMemoryTargets.reprobeWindowSeconds
            ])
        let projection = StrategyMemory.orderedRungs(
            for: seeded, allowlisted: false, now: seedTime)
        XCTAssertEqual(projection, [.clipboardPaste, .keystrokeSynthesis])
    }

    /// Once the seed's window elapses the demotion expires like any other — seeds are data, not
    /// decisions, and R4 applies to them: the app is re-offered AX at
    /// `seedTime + 604_800` (the re-probe beats the allowlist gate).
    func testTheSeededHostileShapeIsReProbedAfterTheWindow() {
        let seedTime: UInt64 = 1_000_000
        let seeded = InjectionStrategy(
            demotedRungs: [.accessibility],
            learnedAllowlist: false,
            reprobeWindows: [
                .accessibility: seedTime + StrategyMemoryTargets.reprobeWindowSeconds
            ])
        let projection = StrategyMemory.orderedRungs(
            for: seeded, allowlisted: false,
            now: seedTime + StrategyMemoryTargets.reprobeWindowSeconds)
        XCTAssertEqual(projection, [.accessibility, .clipboardPaste, .keystrokeSynthesis])
    }

    // MARK: - Re-probe eligibility

    /// A rung that is not demoted is never eligible — eligibility is the demotion's property.
    func testEligibilityIsFalseForANonDemotedRung() {
        let fresh = InjectionStrategy()
        XCTAssertFalse(
            StrategyMemory.reprobeEligibility(
                for: .accessibility, in: fresh, now: .max))
        XCTAssertFalse(
            StrategyMemory.reprobeEligibility(
                for: .clipboardPaste, in: fresh, now: .max))
        XCTAssertFalse(
            StrategyMemory.reprobeEligibility(
                for: .keystrokeSynthesis, in: fresh, now: .max))
        XCTAssertFalse(
            StrategyMemory.reprobeEligibility(
                for: .widgetFailsafe, in: fresh, now: .max))
    }

    /// Eligibility is the inclusive boundary again: false before the window, true at exactly the
    /// window, true after it.
    func testEligibilityIsTrueOnlyAtAndAfterTheWindow() {
        let strategy = InjectionStrategy(
            demotedRungs: [.accessibility],
            reprobeWindows: [.accessibility: 1_000])
        XCTAssertFalse(
            StrategyMemory.reprobeEligibility(for: .accessibility, in: strategy, now: 999))
        XCTAssertTrue(
            StrategyMemory.reprobeEligibility(for: .accessibility, in: strategy, now: 1_000))
        XCTAssertTrue(
            StrategyMemory.reprobeEligibility(for: .accessibility, in: strategy, now: 1_001))
    }

    /// A demoted rung without a window entry is never eligible — the same rule the projection
    /// inherits, queried directly.
    func testEligibilityIsFalseForADemotedRungWithoutAWindow() {
        let strategy = InjectionStrategy(demotedRungs: [.accessibility])
        XCTAssertFalse(
            StrategyMemory.reprobeEligibility(
                for: .accessibility, in: strategy, now: .max))
    }

    // MARK: - Single-source scans

    /// The provisional re-probe window — `604_800` seconds, PROVISIONAL per `prd.md` X2 — appears
    /// in exactly one production file, once, with comments stripped: the ``WarmStartTargets``
    /// single-source scan precedent, vacuity-guarded in both directions (the scan must see the
    /// literal in the named file, and must see nothing anywhere else under `Sources/VoccaCore/`).
    /// A re-baseline from the founder's matrix run lands in exactly this one place.
    func testTheProvisionalReprobeWindowLivesInExactlyOneFile() throws {
        XCTAssertEqual(StrategyMemoryTargets.reprobeWindowSeconds, 604_800)

        let coreRoot = try packageRoot().appendingPathComponent("Sources/VoccaCore")
        let sightings = try literalOccurrences(
            of: #"(?<![0-9_])604_800(?![0-9_])"#, under: coreRoot)
        XCTAssertEqual(
            sightings, ["StrategyMemory.swift": 1],
            """
            The 604_800 literal must appear exactly once in the whole of VoccaCore, in \
            StrategyMemory.swift. A second spelling of the re-probe window is a second place a \
            re-baseline must find, and one of them will be missed. Got: \(sightings).
            """)
    }

    /// The canonical rung order — `[.accessibility, .clipboardPaste, .keystrokeSynthesis]` — is
    /// spelled in exactly one production file, once. (Tests and the VoccaInject default order may
    /// spell it: this pin guards the *Core* vocabulary, the thing `memory-order` will consume.)
    func testTheCanonicalRungOrderLivesInExactlyOnePlace() throws {
        XCTAssertEqual(
            StrategyMemoryTargets.canonicalRungOrder,
            [.accessibility, .clipboardPaste, .keystrokeSynthesis])

        let coreRoot = try packageRoot().appendingPathComponent("Sources/VoccaCore")
        let sightings = try literalOccurrences(
            of: #"\[\.accessibility, \.clipboardPaste, \.keystrokeSynthesis\]"#, under: coreRoot)
        XCTAssertEqual(
            sightings, ["StrategyMemory.swift": 1],
            """
            The canonical-order list literal must appear exactly once in the whole of VoccaCore, \
            in StrategyMemory.swift. A second spelling is a second order the projection could \
            drift to. Got: \(sightings).
            """)
    }

    // MARK: - Helpers

    private func packageRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath)
    }

    /// Per-file occurrence counts of `pattern` in every `.swift` file under `root`, comments
    /// stripped — the literal being pinned, so a doc comment naming it is not a second home.
    private func literalOccurrences(of pattern: String, under root: URL) throws -> [String: Int] {
        let regex = try NSRegularExpression(pattern: pattern)
        var sightings: [String: Int] = [:]
        for file in SwiftSourceScanner.swiftFiles(under: root) {
            let stripped = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            let count = regex.numberOfMatches(
                in: stripped, range: NSRange(stripped.startIndex..<stripped.endIndex, in: stripped))
            if count > 0 {
                sightings[file.lastPathComponent] = count
            }
        }
        return sightings
    }
}