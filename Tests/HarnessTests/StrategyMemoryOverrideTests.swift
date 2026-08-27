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

/// The override (S2): a user-pinned rung order that is **absolute** — memory neither demotes,
/// promotes, nor re-probes an overridden app; the override wins and learning is frozen for it
/// (`core-memory/spec.md` M7).
///
/// The freeze lives here, in the Core vocabulary, in exactly the two places the memory touches:
///
/// - the projection returns the override verbatim — never reordered to the canonical order,
///   never filtered by the allowlist gate, never re-probed — whatever the demotions, windows,
///   allowlist answer and `now` say;
/// - the record fold returns the strategy unchanged before anything else — a demotion-worthy
///   loss, a promotion-worthy verified AX win and an elapsed re-probe all leave an overridden
///   app byte-for-byte alone;
/// - construction is validated: `InjectionStrategy.overriding` refuses an empty override and
///   any override mentioning `.widgetFailsafe` (the failsafe is the floor under I1, not a rung
///   a user may pin), while `.clipboardPaste` may appear anywhere in an override — a user pin
///   is not a learned invariant.
final class StrategyMemoryOverrideTests: XCTestCase {

    /// The projection returns the override verbatim: an order that is not canonical is still
    /// returned as pinned, unaffected by demotions, windows, the allowlist answer or `now`.
    func testAnOverrideIsReturnedVerbatimByTheProjection() {
        let strategy = InjectionStrategy.overriding(
            overrideRungs: [.clipboardPaste, .keystrokeSynthesis],
            demotedRungs: [.accessibility, .keystrokeSynthesis],
            reprobeWindows: [.accessibility: 0, .keystrokeSynthesis: 0])!
        XCTAssertEqual(
            StrategyMemory.orderedRungs(for: strategy, allowlisted: false, now: .max),
            [.clipboardPaste, .keystrokeSynthesis])
        XCTAssertEqual(
            StrategyMemory.orderedRungs(for: strategy, allowlisted: true, now: 0),
            [.clipboardPaste, .keystrokeSynthesis])
    }

    /// The freeze, in both directions: the projection still returns the override over elapsed
    /// windows, and the record fold leaves the strategy byte-for-byte unchanged — no demotion,
    /// no promotion, no window movement. This is the one place the freeze lives; `memory-order`
    /// has nothing to special-case.
    func testAnOverrideIsNeverReprobedOrDemoted() {
        let strategy = InjectionStrategy.overriding(
            overrideRungs: [.keystrokeSynthesis, .clipboardPaste],
            demotedRungs: [.accessibility],
            reprobeWindows: [.accessibility: 0])!
        XCTAssertEqual(
            StrategyMemory.orderedRungs(for: strategy, allowlisted: false, now: .max),
            [.keystrokeSynthesis, .clipboardPaste])

        let demoting = InjectionResult(
            rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste],
            verified: false, elapsed: .zero)
        XCTAssertEqual(
            StrategyMemory.record(
                result: demoting, attempted: [.accessibility, .clipboardPaste],
                now: 0, allowlisted: true, into: strategy),
            strategy)

        let promoting = InjectionResult(
            rung: .accessibility, attempted: [.accessibility], verified: true, elapsed: .zero)
        XCTAssertEqual(
            StrategyMemory.record(
                result: promoting, attempted: [.accessibility],
                now: .max, allowlisted: false, into: strategy),
            strategy)
    }

    /// An empty override is refused at construction: `[]` means "no pin", and the pin is the
    /// point — `nil` keeps the app learned.
    func testAnOverrideMustBeNonEmpty() {
        XCTAssertNil(InjectionStrategy.overriding(overrideRungs: []))
    }

    /// `.widgetFailsafe` is refused at construction, alone or inside a larger pin — the failsafe
    /// is the floor under I1, not a rung a strategy may name.
    func testAnOverrideNeverContainsWidgetFailsafe() {
        XCTAssertNil(InjectionStrategy.overriding(overrideRungs: [.widgetFailsafe]))
        XCTAssertNil(
            InjectionStrategy.overriding(
                overrideRungs: [.accessibility, .widgetFailsafe, .clipboardPaste]))
    }

    /// `.clipboardPaste` may appear anywhere in an override — at the front, in the middle, or
    /// alone — because a user pin is a pin, not a learned invariant.
    func testClipboardMayAppearAnywhereInAnOverride() {
        let alone = InjectionStrategy.overriding(overrideRungs: [.clipboardPaste])
        XCTAssertEqual(alone?.overrideRungs, [.clipboardPaste])

        let first = InjectionStrategy.overriding(
            overrideRungs: [.clipboardPaste, .keystrokeSynthesis])
        XCTAssertEqual(first?.overrideRungs, [.clipboardPaste, .keystrokeSynthesis])

        let middle = InjectionStrategy.overriding(
            overrideRungs: [.accessibility, .clipboardPaste, .keystrokeSynthesis])
        XCTAssertEqual(
            middle?.overrideRungs, [.accessibility, .clipboardPaste, .keystrokeSynthesis])
    }
}