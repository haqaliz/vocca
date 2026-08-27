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

import VoccaUI
import XCTest

/// The persisted "onboarding complete" flag — the A3 aspect of first-run-permissions
/// (`plan_20260827.md`): the UserDefaults-backed one-file seam the `main()` show decision reads
/// synchronously, written only on TRY IT success (prd.md M4; R4 pins that no other transition
/// sets it — the reducer tests own that side, this file owns the store's).
///
/// Every test runs against a **scoped** `UserDefaults(suiteName:)` injected via the
/// initializer — never `UserDefaults.standard`, so the suite cannot read or write the user's
/// real defaults, and each suite is purged after its test.
///
/// `UserDefaults` is the deliberate divergence from the house persistence idiom: the dictionary
/// and cleanup-config stores are JSON behind one-file FileManager seams, but the `main()` show
/// decision needs a read with no async at all, and UserDefaults is synchronous by nature. The
/// price is the one-file seam family in `InjectionSeamBoundaryTests` — this store is the only
/// file in `Sources/` permitted to name `UserDefaults`.
final class CompletionFlagStoreTests: XCTestCase {

    /// A fresh, process-unique defaults suite plus its name, removed from the defaults system
    /// when the test ends. Scoped by name, never `.standard`; each test pairs it with the
    /// `defer` that purges it, so no test can leak a flag into another suite or into the user's
    /// real defaults.
    private func makeScopedSuite() -> (defaults: UserDefaults, name: String) {
        let name = "vocca-completion-flag-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    // MARK: - The flag's read

    /// An absent flag is an incomplete onboarding: a fresh install has never run TRY IT, so the
    /// window must re-show at launch (`plan_20260827.md` step 1).
    func testAnAbsentFlagIsNotComplete() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CompletionFlagStore(defaults: defaults)
        XCTAssertFalse(store.isComplete())
    }

    /// After `markComplete()` the store answers `true` — the persisted half of "onboarding
    /// complete = TRY IT success" (prd.md M4).
    func testMarkCompleteFlipsTheFlagToComplete() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CompletionFlagStore(defaults: defaults)
        store.markComplete()
        XCTAssertTrue(store.isComplete())
    }

    /// `markComplete()` is idempotent: TRY IT success is written once, and a second write (or a
    /// repeated transition the reducer cannot make, R4) must never unset the flag.
    func testMarkCompleteIsIdempotent() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CompletionFlagStore(defaults: defaults)
        store.markComplete()
        store.markComplete()
        XCTAssertTrue(store.isComplete())
    }

    /// The flag is a real Boolean in the defaults under the store's key — not a derived answer —
    /// so the value survives the process the way the `main()` decision needs it to.
    func testTheFlagIsStoredAsABooleanUnderTheKey() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CompletionFlagStore(defaults: defaults)
        store.markComplete()
        XCTAssertEqual(defaults.object(forKey: CompletionFlagStore.key) as? Bool, true)
    }

    // MARK: - Cross-instance persistence

    /// A fresh store instance over the same suite reads the same flag: the `main()` decision and
    /// the root composition (A4) read one store, and any future surface must read the same
    /// answer from a fresh instance (`plan_20260827.md` step 1).
    func testAFreshStoreInstanceReadsTheSameFlag() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = CompletionFlagStore(defaults: defaults)
        first.markComplete()

        let second = CompletionFlagStore(defaults: defaults)
        XCTAssertTrue(second.isComplete())
    }

    // MARK: - The frozen key

    /// The flag key is a frozen constant, pinned here: the `main()` show decision, the root
    /// composition, and any smoke row all read the same key — a drifted literal would re-show
    /// the window on a machine that had completed onboarding (`plan_20260827.md` step 2).
    func testTheFlagKeyIsAFrozenConstant() {
        XCTAssertEqual(CompletionFlagStore.key, "onboarding.complete")
    }
}