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
import XCTest

/// The AND-gate's contract (`byok-context-grant` D2/D4): the pure decision that a snapshot may
/// travel with a cloud cleanup request — per-app consent **and** the separate global grant,
/// never either alone (`prd.md:102-107`) — plus the ≤ 4 KB selected-text bound (`prd.md:192-195`).
///
/// The gate is the caller-side decision the provider must never make (`CleanupProvider.swift:39-41`):
/// it is the pure, headless-tested half that `bootstrap-wiring`'s composed
/// ``GrantedContextSource`` will apply to a `ContextProvider` snapshot. The four-row AND table
/// and the byte-bound truncation live here — stdlib-only, in the one module that may name the
/// snapshot's vocabulary.
final class ContextGrantGateTests: XCTestCase {

    // MARK: - The AND table (`prd.md:102-107`)

    /// **Both gates hold → the snapshot is granted.** The one row that yields anything.
    func testConsentAndGrantYieldTheSnapshot() {
        let snapshot = ContextSnapshot(
            bundleID: "com.example.Notes", windowTitle: "Notes - The Draft", selectedText: "hi")

        XCTAssertEqual(
            ContextGrantGate.granted(
                snapshot: snapshot, consentActive: true, grantEnabled: true),
            snapshot)
    }

    /// **Consent without the grant → `nil`.** The roadmap's "never either alone"
    /// (`CAPABILITY_ROADMAP.md:353-355`): per-app consent is not enough to put context on the
    /// wire.
    func testConsentWithoutGrantIsNil() {
        let snapshot = ContextSnapshot(
            bundleID: "com.example.Notes", windowTitle: "Notes - The Draft", selectedText: "hi")

        XCTAssertNil(
            ContextGrantGate.granted(
                snapshot: snapshot, consentActive: true, grantEnabled: false))
    }

    /// **Grant without consent → `nil`.** The global grant is not a blanket licence: an app the
    /// user never consented to still contributes nothing.
    func testGrantWithoutConsentIsNil() {
        let snapshot = ContextSnapshot(
            bundleID: "com.example.Notes", windowTitle: "Notes - The Draft", selectedText: "hi")

        XCTAssertNil(
            ContextGrantGate.granted(
                snapshot: snapshot, consentActive: false, grantEnabled: true))
    }

    /// **Neither → `nil`.**
    func testNeitherIsNil() {
        let snapshot = ContextSnapshot(
            bundleID: "com.example.Notes", windowTitle: "Notes - The Draft", selectedText: "hi")

        XCTAssertNil(
            ContextGrantGate.granted(
                snapshot: snapshot, consentActive: false, grantEnabled: false))
    }

    /// **A nil snapshot with both gates on → `nil`.** The gate never invents context: nothing
    /// resolved is nothing granted.
    func testANilSnapshotIsNil() {
        XCTAssertNil(
            ContextGrantGate.granted(
                snapshot: nil, consentActive: true, grantEnabled: true))
    }

    // MARK: - The ≤ 4 KB bound (D4, `prd.md:192-195`)

    /// **Over the bound, `selectedText` is truncated to the largest UTF-8 prefix ≤ 4096 bytes —
    /// never splitting a scalar.** Multibyte content (emoji, 4 bytes per scalar) so a character
    /// count would lie: the bound is bytes, the promise is valid UTF-8.
    func testSelectedTextOverTheBoundIsTruncatedAtAByteBoundary() throws {
        let emoji = "😀"
        let over = String(repeating: emoji, count: 2000)

        let granted = ContextGrantGate.granted(
            snapshot: ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: over),
            consentActive: true, grantEnabled: true)
        let out = try XCTUnwrap(granted?.selectedText)

        XCTAssertEqual(
            out.utf8.count, ContextGrantGate.maxSelectedTextBytes,
            "1024 whole emoji are exactly 4096 bytes — the truncation lands on the bound")
        XCTAssertEqual(out, String(repeating: emoji, count: 1024))
        XCTAssertLessThan(out.utf8.count, over.utf8.count, "the input is over the bound and must shorten")

        // The misaligned shape: the bound falls inside the last scalar's bytes, and the prefix
        // must stop *before* it — a truncated scalar is corrupted text, and corrupted text is
        // worse than truncated text.
        let misaligned = String(repeating: "a", count: 4095) + emoji
        let truncated = ContextGrantGate.granted(
            snapshot: ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: misaligned),
            consentActive: true, grantEnabled: true)
        XCTAssertEqual(
            truncated?.selectedText, String(repeating: "a", count: 4095),
            "the truncation never splits a scalar — the prefix stops before the emoji's bytes")
    }

    /// **Exactly at the bound → untouched.** 4096 bytes is within the promise.
    func testSelectedTextAtTheBoundPassesUntouched() {
        let at = String(repeating: "😀", count: 1024)
        let snapshot = ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: at)

        let granted = ContextGrantGate.granted(
            snapshot: snapshot, consentActive: true, grantEnabled: true)

        XCTAssertEqual(granted, snapshot, "at the bound is within the bound — nothing is lost")
        XCTAssertEqual(granted?.selectedText?.utf8.count, 4096)
    }

    /// **Under the bound → untouched.** Short text is the normal shape and passes verbatim.
    func testSelectedTextUnderTheBoundPassesUntouched() {
        let snapshot = ContextSnapshot(
            bundleID: "com.example.Notes", windowTitle: "Notes - The Draft",
            selectedText: "a short selection")

        let granted = ContextGrantGate.granted(
            snapshot: snapshot, consentActive: true, grantEnabled: true)

        XCTAssertEqual(granted, snapshot)
    }

    /// **An empty selection passes as present.** `""` is a collapsed selection — a real fact —
    /// and the nil-vs-empty discipline is preserved: absent is not emptied, and empty is not
    /// made absent.
    func testAnEmptySelectedTextPassesAsPresent() {
        let snapshot = ContextSnapshot(
            bundleID: "com.example.Notes", windowTitle: "Notes - The Draft", selectedText: "")

        let granted = ContextGrantGate.granted(
            snapshot: snapshot, consentActive: true, grantEnabled: true)

        XCTAssertEqual(granted, snapshot, "empty is present-but-empty, and stays that way")
        XCTAssertEqual(granted?.selectedText, "")
    }
}