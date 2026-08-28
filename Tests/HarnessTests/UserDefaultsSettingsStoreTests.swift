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
import VoccaUI
import XCTest

/// The settings store — the `settings-store` aspect's adapter half (`plan_20260828.md` phase 2):
/// the second file in `Sources/` permitted to name `UserDefaults`, beside the onboarding
/// completion flag's, and the one that makes "a setting, once chosen, stays chosen" true.
///
/// Every test runs against a **scoped** `UserDefaults(suiteName:)` injected through the
/// initializer and purged in a `defer` — never `UserDefaults.standard`, so the suite can neither
/// read nor write the developer's real settings. That injected suite is also the aspect's test
/// double: the `CompletionFlagStore` precedent takes a real `UserDefaults` over a scoped domain
/// rather than a protocol, because the thing worth faking here is the *domain*, not the API.
///
/// The store is deliberately thin. Every decision about what a stored string means lives in
/// `PersistedSettings` (VoccaCore) and is tested there; what this file pins is the part only the
/// adapter can get wrong — which key, what happens to a value that is present but not a string,
/// and that a failed read never rewrites what it failed to read.
final class UserDefaultsSettingsStoreTests: XCTestCase {

    /// A fresh, process-unique defaults suite plus its name, removed from the defaults system
    /// when the test ends — the `CompletionFlagStoreTests` shape, for the same reason: no test
    /// may leak a setting into another test or into the user's real defaults.
    private func makeScopedSuite() -> (defaults: UserDefaults, name: String) {
        let name = "vocca-settings-store-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    // MARK: - A setting, once chosen, stays chosen

    /// A written engine selection reads back from a **fresh store instance** over the same
    /// domain — the aspect's whole user outcome, and the launch that matters is the next one, so
    /// reading it back from the instance that wrote it would prove nothing about persistence.
    func testAWrittenEngineSelectionReadsBackFromAFreshInstance() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        UserDefaultsSettingsStore(defaults: defaults)
            .setEngineSelection(EngineSelection(tier: .whisperTurboQ5))

        let reread = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(reread.engineSelection(), EngineSelection(tier: .whisperTurboQ5))
    }

    /// A written activation mode reads back from a fresh instance.
    ///
    /// This is the setting the aspect exists for: `AppBootstrap.swift:888` initialised
    /// `activeMode` from a constant and read no store at all, so the Settings page's switch
    /// applied to the running process and was gone by the next launch — and for a user who
    /// cannot hold a key, "gone by the next launch" means the hotkey does nothing.
    func testAWrittenActivationModeReadsBackFromAFreshInstance() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        UserDefaultsSettingsStore(defaults: defaults).setActivationMode(.holdToTalk)

        let reread = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(reread.activationMode(), .holdToTalk)
    }

    // MARK: - A fresh install

    /// With nothing stored, both settings answer the shipped defaults and **nothing is logged**.
    ///
    /// A fresh install has chosen nothing; that is the normal path, not an error. This test pins
    /// the silence as much as the values: without it, the loud half asserted below could be
    /// satisfied by a store that simply reports everything, which would put two error lines in
    /// the log of every healthy first launch and teach a reader to ignore the category.
    func testAbsentSettingsAreTheShippedDefaultsAndAreNotLogged() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let logged = LogCollector()
        let store = UserDefaultsSettingsStore(defaults: defaults, log: { logged.append($0) })

        XCTAssertEqual(store.engineSelection(), EngineSelection.defaultSelection)
        XCTAssertEqual(store.engineSelection().tier, .parakeetV3)
        XCTAssertEqual(store.activationMode(), PersistedSettings.defaultActivation)
        XCTAssertEqual(store.activationMode(), .toggle)
        XCTAssertEqual(logged.entries, [], "a fresh install is the normal path and must be silent")
    }

    // MARK: - Values that are present and unreadable

    /// An unknown identifier under either key is the shipped default **and a log line naming it**.
    ///
    /// The loud half is what is asserted, not the fallback. A stored value that is present but
    /// unreadable means a downgrade, a hand-edit or a rename has cost the user a choice they
    /// made, and a silent reset is exactly the failure this rule exists for: the user watches
    /// their setting revert with nothing anywhere saying why. It also pins the wiring — the
    /// store's `log` really reaches the decode, rather than the decode reporting into a closure
    /// nobody passed on.
    func testAnUnknownStoredIdentifierIsTheShippedDefaultAndIsLogged() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("parakeet-v9", forKey: UserDefaultsSettingsStore.engineSelectionKey)
        defaults.set("blink-twice", forKey: UserDefaultsSettingsStore.activationModeKey)
        let logged = LogCollector()
        let store = UserDefaultsSettingsStore(defaults: defaults, log: { logged.append($0) })

        XCTAssertEqual(store.engineSelection(), EngineSelection.defaultSelection)
        XCTAssertEqual(store.activationMode(), PersistedSettings.defaultActivation)
        XCTAssertEqual(logged.entries.count, 2, "one line per unreadable value; got \(logged.entries)")
        XCTAssertTrue(
            logged.entries.contains(where: { $0.contains("parakeet-v9") }),
            "the log must name the rejected engine value; got \(logged.entries)")
        XCTAssertTrue(
            logged.entries.contains(where: { $0.contains("blink-twice") }),
            "the log must name the rejected activation value; got \(logged.entries)")
    }

    /// A stored value of the **wrong type** takes the loud path, not the silent one.
    ///
    /// This is the one case only the adapter can get right, and the obvious implementation gets
    /// it wrong: `UserDefaults.string(forKey:)` answers `nil` for a stored array exactly as it
    /// does for a key that was never written, so a preferences file corrupted by a bad migration
    /// or a hand-edit would be indistinguishable from a fresh install and would reset the user's
    /// settings in silence. Present-and-unreadable and never-written are different events and the
    /// store must keep them apart.
    func testAStoredValueOfTheWrongTypeIsTheShippedDefaultAndIsLogged() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["not", "a", "string"], forKey: UserDefaultsSettingsStore.engineSelectionKey)
        defaults.set(["neither"], forKey: UserDefaultsSettingsStore.activationModeKey)
        let logged = LogCollector()
        let store = UserDefaultsSettingsStore(defaults: defaults, log: { logged.append($0) })

        XCTAssertEqual(store.engineSelection(), EngineSelection.defaultSelection)
        XCTAssertEqual(store.activationMode(), PersistedSettings.defaultActivation)
        XCTAssertEqual(
            logged.entries.count, 2,
            "a present non-string is unreadable, not absent, and must be reported; got \(logged.entries)")
    }

    // MARK: - A failed read never writes

    /// Reading a value the store cannot decode leaves the stored bytes **exactly as they were**.
    ///
    /// The `FileSystemDictionaryStore` rule, in the other persistence family: a bad load must not
    /// rewrite the user's file. Normalising the unreadable value to the default on read would
    /// destroy the evidence and turn a value a future version could have understood into one it
    /// cannot — and it would do so on a read the user never asked for.
    func testAFailedReadDoesNotRewriteTheStoredValue() {
        let (defaults, name) = makeScopedSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("parakeet-v9", forKey: UserDefaultsSettingsStore.engineSelectionKey)
        defaults.set(["neither"], forKey: UserDefaultsSettingsStore.activationModeKey)
        let store = UserDefaultsSettingsStore(defaults: defaults, log: { _ in })

        _ = store.engineSelection()
        _ = store.activationMode()

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsSettingsStore.engineSelectionKey) as? String,
            "parakeet-v9")
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsSettingsStore.activationModeKey) as? [String],
            ["neither"])
    }

    // MARK: - The frozen keys

    /// The two keys are frozen constants, pinned here as literals.
    ///
    /// The key is the file format: change it and every existing user's choice becomes an absent
    /// value on their next launch, silently and with no error anywhere. Asked of the constant
    /// rather than written out, this test would pass through any rename — which is the event it
    /// exists to catch.
    func testTheSettingsKeysAreFrozenConstants() {
        XCTAssertEqual(UserDefaultsSettingsStore.engineSelectionKey, "settings.engineSelection")
        XCTAssertEqual(UserDefaultsSettingsStore.activationModeKey, "settings.activationMode")
    }

    /// The two keys are different keys.
    ///
    /// A collision would make each setting overwrite the other, and both would then read back as
    /// an unreadable value taking the shipped default — a user who changed one setting losing the
    /// other, with the log blaming the value rather than the key.
    func testTheTwoSettingsKeysAreDistinct() {
        XCTAssertNotEqual(
            UserDefaultsSettingsStore.engineSelectionKey,
            UserDefaultsSettingsStore.activationModeKey)
    }
}
