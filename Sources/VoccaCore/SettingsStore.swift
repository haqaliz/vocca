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

/// **Where a chosen setting lives between launches** — the seam the composition root reads its two
/// live settings through, and writes them back to.
///
/// The shipped implementation is `UserDefaultsSettingsStore` (VoccaUI), the one file in `Sources/`
/// permitted to name the `UserDefaults` family for this seam. The seam exists so that the
/// composition root can read and write settings **without naming that file's type**: the root is
/// not on the permitted list and must never be, because a settings decision taken in a file the
/// headless suite cannot construct is a decision that escaped CI forever. `ShippingSettings.store()`
/// is the factory, exactly as `ShippingLadder` and `ShippingCleanup` are for their adapters.
///
/// ## The contract, and why nothing here throws
///
/// Reads are synchronous and total. Every failure — an absent value, an unreadable one, a
/// preferences file of the wrong shape — degrades to the shipped default, which is a working
/// configuration; the decisions about *which* default and *how loudly* live in
/// ``PersistedSettings``, where they are pure and CI runs all of them. A settings read must never
/// be able to make Vocca unusable, and the launch path needs an answer with no `await` in it.
///
/// Writes are best-effort and never throw, for the same reason: a failed write fails in the safe
/// direction — the setting reverts to the shipped default at the next launch, which is visible and
/// working rather than silent and broken.
/// ## Not `Sendable`, deliberately
///
/// The shipped adapter holds a `UserDefaults`, which Foundation does not declare `Sendable`, and
/// asserting it here with `@unchecked` would be claiming something about Foundation rather than
/// about Vocca. Nothing needs it: every read and write happens on the main actor — the launch
/// path's, and the root's own `setActiveMode`/`setEngineSelection` — which is the same confinement
/// `CompletionFlagStore` already relies on.
public protocol SettingsStore {
    /// The chosen engine and tier, or the shipped default.
    func engineSelection() -> EngineSelection
    /// Persist the chosen engine and tier.
    func setEngineSelection(_ selection: EngineSelection)
    /// The chosen activation mode, or the shipped default.
    func activationMode() -> HotkeyConfiguration.Activation
    /// Persist the chosen activation mode.
    func setActivationMode(_ activation: HotkeyConfiguration.Activation)
    /// The bound hotkey chord, or the shipped default (⌥Space). The activation mode is stored
    /// separately and is **not** part of this value — see ``HotkeyChord``.
    func hotkeyChord() -> HotkeyChord
    /// Persist the bound chord. Best-effort, never throws: a failed write means the binding
    /// reverts to ⌥Space at the next launch, which is a working hotkey rather than none.
    func setHotkeyChord(_ chord: HotkeyChord)
    /// Whether the user has read and accepted the cloud-cleanup confirmation
    /// (`PRODUCT_SPEC.md:273`). `false` on a fresh install, and `false` for anything unreadable —
    /// the dialog is shown again rather than an agreement being assumed.
    func hasAcknowledgedCloudCleanup() -> Bool
    /// Record — or withdraw — that acknowledgement. Best-effort, never throws: a failed write
    /// means the dialog appears once more, which is the safe direction.
    func setAcknowledgedCloudCleanup(_ acknowledged: Bool)
    /// Whether a quit initiated outside the tray menu keeps Vocca running in the menu bar.
    /// `false` on a fresh install: quitting quits.
    func keepInTray() -> Bool
    /// Persist the keep-in-tray choice. Best-effort, never throws: a failed write means the app
    /// quits when told to, which is the behaviour every fresh install already has.
    func setKeepInTray(_ keepInTray: Bool)
}
