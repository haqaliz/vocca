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

/// The per-app strategy value C8's memory is made of: what the ladder demoted, whether the app
/// learned its way onto the accessibility allowlist, when each demoted rung may be re-probed, and
/// — when the user has pinned one — the absolute override that freezes learning (S2).
///
/// The shape matters as much as the behaviour, because every later aspect persists and renders it:
///
/// - `demotedRungs` is a `Set` of the *real* rungs — `.clipboardPaste` can never be demoted (it
///   is the workhorse, `ROADMAP.md:47`) and `.widgetFailsafe` never appears in a strategy
///   (`injector-seam` plan); the invariants are enforced by `StrategyMemory.record` and guarded
///   by the projection, but the type is constructible by hand because a hostile app's seed shape
///   is exactly that (`CAPABILITY_ROADMAP.md:185` — the first dictation pays the seed's answer,
///   never the AX discovery cost);
/// - `reprobeWindows` maps a demoted rung to the epoch second (`UInt64`) at which it may be tried
///   once more — a demoted rung with no window entry is never re-probed (tolerant-decode strays
///   stay on clipboard);
/// - `overrideRungs` is `nil` when the app is learned, and a user-pinned order when the Apps tab
///   has frozen learning for it — the override is absolute and the projection returns it verbatim.
final class InjectionStrategyTests: XCTestCase {

    /// A fresh app starts with no demotions, no learning, no windows and no override — the
    /// all-empty strategy `InjectionStrategy()` must be that state.
    func testTheEmptyStrategyIsTheDefault() {
        let strategy = InjectionStrategy()
        XCTAssertTrue(strategy.demotedRungs.isEmpty)
        XCTAssertFalse(strategy.learnedAllowlist)
        XCTAssertTrue(strategy.reprobeWindows.isEmpty)
        XCTAssertNil(strategy.overrideRungs)
    }

    /// The strategy is compared by value, field by field — two strategies built differently but
    /// holding the same state are equal, and a difference in any one field is a difference.
    func testStrategiesCompareByValue() {
        XCTAssertEqual(InjectionStrategy(), InjectionStrategy())

        let demoted = InjectionStrategy(
            demotedRungs: [.accessibility], learnedAllowlist: false,
            reprobeWindows: [.accessibility: 100], overrideRungs: nil)
        XCTAssertNotEqual(demoted, InjectionStrategy())

        XCTAssertNotEqual(
            InjectionStrategy(learnedAllowlist: true), InjectionStrategy())

        XCTAssertNotEqual(
            InjectionStrategy(reprobeWindows: [.accessibility: 100]),
            InjectionStrategy())

        XCTAssertNotEqual(
            InjectionStrategy(overrideRungs: [.clipboardPaste]),
            InjectionStrategy())

        XCTAssertEqual(
            InjectionStrategy(demotedRungs: [.accessibility], learnedAllowlist: true),
            InjectionStrategy(demotedRungs: [.accessibility], learnedAllowlist: true))
    }

    /// Compile-time: the strategy crosses actor boundaries on every path (the injector records on
    /// the latency path, the store persists off it), so it must be `Sendable`.
    func testTheStrategyIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        let strategy = InjectionStrategy(
            demotedRungs: [.accessibility], learnedAllowlist: true,
            reprobeWindows: [.accessibility: 100], overrideRungs: [.clipboardPaste])
        XCTAssertEqual(requireSendable(strategy), strategy)
    }

    /// The strategy carries its own key — the bundle ID the store upserts by (the
    /// `store-seam` contract: "the value carries its key"). The memberwise default keeps
    /// every existing construction site — `InjectionStrategy()` included — compiling
    /// unchanged; the store's key is filled in by the recorder, not by hand.
    func testTheStrategyCarriesItsBundleIDKey() {
        let strategy = InjectionStrategy(bundleID: "com.example.app")
        XCTAssertEqual(strategy.bundleID, "com.example.app")
        XCTAssertEqual(InjectionStrategy().bundleID, "", "the empty strategy carries no app yet")
    }

    /// The full-field round trip the store's `strategies.json` depends on: encode →
    /// decode → equal, with every field populated — bundle ID, demoted rungs, learned
    /// allowlist, re-probe windows and the override. `reprobeWindows`'s dictionary
    /// encodes in the alternating key/value array form (non-String keys) — accepted:
    /// the file is machine-written.
    func testTheStrategyRoundTripsCodable() throws {
        let strategy = InjectionStrategy(
            bundleID: "com.example.app",
            demotedRungs: [.accessibility, .keystrokeSynthesis],
            learnedAllowlist: true,
            reprobeWindows: [.accessibility: 100, .keystrokeSynthesis: 200],
            overrideRungs: [.clipboardPaste])

        let data = try JSONEncoder().encode(strategy)
        let decoded = try JSONDecoder().decode(InjectionStrategy.self, from: data)

        XCTAssertEqual(decoded, strategy, "a strategy must survive encode/decode whole")
    }

    /// The seed shape a hostile app starts as — AX demoted at seed time, window at
    /// `seedTime + reprobeWindowSeconds` — must be constructible by hand, the
    /// `TargetContext` plain-init doctrine: seeds are data, and data is built, not derived.
    func testMemberwiseConstructionForTheSeedShape() {
        let seedTime: UInt64 = 1_000_000
        let strategy = InjectionStrategy(
            demotedRungs: [.accessibility], learnedAllowlist: false,
            reprobeWindows: [.accessibility: seedTime + StrategyMemoryTargets.reprobeWindowSeconds],
            overrideRungs: nil)
        XCTAssertEqual(strategy.demotedRungs, [.accessibility])
        XCTAssertFalse(strategy.learnedAllowlist)
        XCTAssertEqual(
            strategy.reprobeWindows,
            [.accessibility: seedTime + StrategyMemoryTargets.reprobeWindowSeconds])
        XCTAssertNil(strategy.overrideRungs)
    }
}
