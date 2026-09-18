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
import VoccaUI
import XCTest

/// The persisted global grant's contract (`byok-context-grant` D7): the separate, off-by-default
/// grant `PRD M7` names (`prd.md:102-107`) — per-app consent **and** this grant, never either
/// alone — persisted as the frozen `settings.contextGrantEnabled` key.
///
/// The three-answer contract is the keep-in-tray family's shape, and the safe direction is the
/// cloud acknowledgement's: absent → `false` silently (a fresh install has granted nothing),
/// unreadable → `false` **loudly** (a corrupted preferences entry can never spend a grant the
/// user never gave — degrading the other way would send context off the machine without the
/// explicit grant the roadmap's acceptance demands, `CAPABILITY_ROADMAP.md:353-355`).
///
/// Every test runs against a **scoped** `UserDefaults(suiteName:)` injected through the
/// initializer and purged in a `defer` — never `UserDefaults.standard`, so the suite can neither
/// read nor write the developer's real settings.
final class ContextGrantPersistenceTests: XCTestCase {

    /// A fresh, process-unique defaults suite plus its name, removed from the defaults system
    /// when the test ends — the `UserDefaultsSettingsStoreTests` shape.
    private func makeScopedSuite() -> (defaults: UserDefaults, name: String) {
        let name = "vocca-context-grant-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// **The key is frozen.** The key is the file format: change it and every existing grant
    /// becomes an absent value on the next launch — silently, and the grant is exactly the
    /// setting that must never be silently spent or silently lost.
    func testTheGrantKeyIsFrozen() {
        XCTAssertEqual(
            UserDefaultsSettingsStore.contextGrantEnabledKey, "settings.contextGrantEnabled")
    }

    /// **A fresh install has no grant, silently.** Absent is the normal path — a fresh install
    /// has granted nothing — so it is reported to nobody.
    func testAFreshInstallHasNoGrant() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let logs = LogCollector()
        let store = UserDefaultsSettingsStore(defaults: defaults, log: { logs.append($0) })

        XCTAssertFalse(store.contextGrantEnabled())
        XCTAssertTrue(logs.entries.isEmpty, "a fresh install has granted nothing — not an error")
    }

    /// **A granted choice survives a relaunch, in both directions.** The round trip reads back
    /// from a **fresh store instance** over the same domain — the launch that matters is the
    /// next one — and the stored spellings are the toggle family's `"enabled"`/`"disabled"`,
    /// pinned through the real store so a spelling drift fails here.
    func testEnabledAndDisabledRoundTrip() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        UserDefaultsSettingsStore(defaults: defaults).setContextGrantEnabled(true)

        XCTAssertTrue(UserDefaultsSettingsStore(defaults: defaults).contextGrantEnabled())
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsSettingsStore.contextGrantEnabledKey) as? String,
            "enabled",
            "the stored spelling is the toggle family's")

        UserDefaultsSettingsStore(defaults: defaults).setContextGrantEnabled(false)

        XCTAssertFalse(UserDefaultsSettingsStore(defaults: defaults).contextGrantEnabled())
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsSettingsStore.contextGrantEnabledKey) as? String,
            "disabled",
            "withdrawn grants store the withdrawn spelling, so absent keeps meaning never asked")
    }

    /// **A present-but-unreadable grant is `false`, loudly.** The sentinel shape: a value that
    /// is present and unparseable is not "nothing stored", and the log names the rejected value.
    func testAnUnreadableGrantValueIsFalseLoudly() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("garbage", forKey: UserDefaultsSettingsStore.contextGrantEnabledKey)
        let logs = LogCollector()
        let store = UserDefaultsSettingsStore(defaults: defaults, log: { logs.append($0) })

        XCTAssertFalse(store.contextGrantEnabled())
        XCTAssertEqual(logs.entries.count, 1, "present and unreadable is loud, never silent")
        XCTAssertTrue(
            logs.entries[0].contains("garbage"),
            "the log must name the rejected value; got \(logs.entries)")
    }

    /// **A stored non-string takes the sentinel path — the loud one.** The `string(forKey:)`
    /// trap would read a stored array as "nothing stored" and reset the grant in silence; the
    /// sentinel routes it to the same loud fallback as an unknown spelling.
    func testAPresentNonStringGrantValueIsFalseLoudly() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["not", "a", "string"], forKey: UserDefaultsSettingsStore.contextGrantEnabledKey)
        let logs = LogCollector()
        let store = UserDefaultsSettingsStore(defaults: defaults, log: { logs.append($0) })

        XCTAssertFalse(store.contextGrantEnabled())
        XCTAssertEqual(
            logs.entries.count, 1,
            "a present non-string is unreadable, not absent, and must be reported")
    }

    /// **The safe direction: unreadable is never a spent grant.** Degrading a corrupted entry to
    /// `true` would spend a grant the user never gave and send their context off the machine
    /// without the explicit grant the acceptance demands; degrading to `false` costs only a
    /// toggle they can flip in one click. Those are not comparable failures.
    func testAnUnreadableGrantNeverSpendsAGrant() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("garbage", forKey: UserDefaultsSettingsStore.contextGrantEnabledKey)

        XCTAssertFalse(
            UserDefaultsSettingsStore(defaults: defaults, log: { _ in }).contextGrantEnabled(),
            "a value Vocca cannot read is never a grant it can spend")
    }
}