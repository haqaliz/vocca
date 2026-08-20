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
import Security

/// **The Keychain adapter — the one file in `Sources/` permitted to name the `Security`/
/// `SecItem`/`kSec` family** (the `keychain` seam's entry in `InjectionSeamBoundaryTests`' tree-wide
/// table).
///
/// Reads the BYOK key item `dev.vocca.Vocca.byok-key` — a `kSecClassGenericPassword` (no server
/// host to key an internet item on, per `spec.md`'s open question) — via one
/// `SecItemCopyMatching`, and is translation only: it contains no decisions about what an absent
/// or locked answer *means*. Those live above the ``KeyProvider`` seam, in ``BYOKCleanupProvider``,
/// which is why this file is executed by nothing in CI — the same position as ``SystemPasteboard``
/// and ``CGEventTapSource``. Its first execution is the founder's BYOK smoke step (`root-wiring`
/// M10), after the key was written by the user's own means (`security add-generic-password`).
///
/// ## Absent vs error — the statuses pinned here
///
/// - `errSecItemNotFound` is **absent** ⇒ `nil` — the key was never written.
/// - `errSecParam` is also **absent** ⇒ `nil` — a malformed query is indistinguishable from an
///   empty one at this seam, so it reads as "nothing there" rather than a hard failure.
/// - any other `OSStatus` is **an error** ⇒ throws ``SystemKeychainKeyProviderError/status(_:)`` —
///   locked, restricted, or otherwise unanswerable; the provider rethrows it unreinterpreted.
///
/// The password is read as UTF-8 data; an item whose bytes do not decode is
/// ``SystemKeychainKeyProviderError/undecodable`` — a corrupt item is a failure, not a nil.
public struct SystemKeychainKeyProvider: KeyProvider {

    public init() {}

    public func key() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.vocca.Vocca",
            kSecAttrAccount as String: "byok-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound || status == errSecParam {
            return nil
        }
        guard status == errSecSuccess else {
            throw SystemKeychainKeyProviderError.status(status)
        }
        guard
            let data = result as? Data,
            let password = String(data: data, encoding: .utf8)
        else {
            throw SystemKeychainKeyProviderError.undecodable
        }
        return password
    }
}

/// The failures the Keychain adapter can name — the statuses that are neither success nor the two
/// absent-statuses, plus a found-but-unreadable item.
public enum SystemKeychainKeyProviderError: Error, Sendable {
    /// The Keychain answered with an unexpected `OSStatus` — anything other than `errSecSuccess`
    /// and the two absent-statuses (`errSecItemNotFound`, `errSecParam`). Carries the raw status
    /// so a caller or log can name what happened without interpreting it.
    case status(OSStatus)

    /// The item was found but its data was not a UTF-8 string.
    case undecodable
}
