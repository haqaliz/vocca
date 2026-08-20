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

/// The seam through which the BYOK cleanup provider reads its key — the read half of the
/// first `Security` surface in the repo (`byok-provider`).
///
/// The provider holds a reference and never names the Keychain: it asks ``key()`` and decides
/// what the answer *means* (absent ⇒ ``LLMProviderError/keyUnavailable``, never a prompt, never
/// a silent skip). ``SystemKeychainKeyProvider`` is the one conformer that names the
/// `Security` family — its seam row in `InjectionSeamBoundaryTests` confines `SecItem`/`kSec`/
/// `SecKeychain` to that single file, the H7 doctrine applied to a fourth system family.
///
/// `nil` means **absent** — the item is not there — which is distinct from throwing: a throw is
/// the seam reporting it could not answer (locked or unreadable), and the provider rethrows it
/// unreinterpreted. Both are first-class outcomes the cleanup chain degrades from.
public protocol KeyProvider: Sendable {
    /// Returns the key, or `nil` when the key is absent.
    ///
    /// - Throws: when the underlying store cannot answer — locked, unreadable, corrupt. A throw
    ///   is not an absence.
    func key() throws -> String?
}
