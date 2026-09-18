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

/// The seam per-app context consent is persisted through and read back from — the store of
/// consented bundle IDs, separated from everything that decides about consent so the decision
/// runs headless (`consent-store/plan_20260918.md` D2; the `usage-store` precedent — the
/// aspect owns its own Core seam). The protocol is the only Core surface of the store; the
/// decisions stay out of it — the store moves bundle IDs, it never decides about one.
///
/// ## Concurrency contract
///
/// Single process, one writer: ``load()`` once at launch, then ``set(_:consented:)``/``save(_:)``
/// mutate the held set and persist the **whole set** atomically — a racing pair of updates ends
/// with one complete file, and the in-memory set carries the other entry forward to the next
/// persist. Implementations are actors; the atomic rename means a concurrent read sees the old
/// or the new complete file, never a partial one.
///
/// ## Persistence contract
///
/// Mirrors ``InjectionStrategyStore``'s exactly, because the failure modes are the same ones:
/// ``load()`` never throws — a missing file is the empty consent **silently** (a first run is
/// not an error), a corrupt entry is skipped with one loud log while the readable remainder
/// loads, and **a load never rewrites the file**. A whole file that cannot be read as this
/// format at all — not an object, an unknown version, or a consent field that is not a list —
/// loads as the empty consent with one loud log, and is likewise left on disk untouched.
/// ``set(_:consented:)`` throws when the persist fails, so the caller can see and log that the
/// consent it holds is not the consent on disk — and returns `false` for a refusal: an invalid
/// bundle ID or a new app at capacity, a loud refusal never an eviction. ``save(_:)`` is the
/// deliberate wholesale write — the future Apps-tab editing path — and is not subject to the
/// cap.
///
/// ## Privacy constraint (`prd.md` M10)
///
/// **The consent file holds bundle IDs only — no transcript text, no selection text, no
/// wall-clock timestamps.** The vocabulary's own shape (``ConsentBundleID``) is what keeps
/// that promise, and the store must not widen it: anything this seam could carry that a bundle
/// ID cannot hold would be a privacy decision made below the seam.
public protocol ConsentStore: Sendable {
    /// The consented bundle IDs held, loaded from the store's backing (the empty set on first
    /// run). Never throws. For the persistent store: missing → empty silently; unreadable →
    /// empty with one loud log; an invalid entry → the valid remainder with one loud log per
    /// skipped entry; the file is never rewritten.
    func load() async -> Set<String>

    /// Upsert `bundleID` into the held consent (`consented: true`) or remove it
    /// (`consented: false`) and persist.
    ///
    /// Returns `false` — and persists nothing — for a string that is not a bundle ID
    /// (``ConsentBundleID.isValid``), or when at capacity and `bundleID` is new: a loud refusal,
    /// never an eviction; the file is untouched. Updates of known apps always succeed. Throws
    /// when the persist fails (the caller must be able to see and log that the file was *not*
    /// updated).
    func set(_ bundleID: String, consented: Bool) async throws -> Bool

    /// Replace the whole held set and persist — the deliberate wholesale editing path.
    /// Deliberate wholesale writes are not subject to the cap.
    func save(_ ids: Set<String>) async throws
}

/// The one named table of the store's bounded-memory claim (D3): at this many consented apps,
/// ``ConsentStore.set(_:consented:)`` of a *new* bundle ID is refused loudly — never evicted
/// (the ``InjectionStrategyStoreConstants.maximumRememberedApps`` cap-512 precedent, in exactly
/// one place, pinned by a single-source scan). `load` and `save` are uncapped: the file is
/// user-owned, and the Apps tab is the user's own editing mechanism.
public enum ConsentStoreConstants {
    /// The cap on consented apps.
    public static let maximumConsentedApps = 512
}

/// The bundle-ID vocabulary that makes the privacy claim a property of types rather than
/// discipline: **the only strings the consent store can hold are bundle-ID-shaped** (D4).
///
/// The shape is the reverse-DNS one the matrix already applies to its bundle column
/// (`injection-matrix.sh`'s): at least one dot, no whitespace or control characters, at most
/// 255 characters. Anything the store refuses here is refused on the way in and skipped on the
/// way out, so a content-shaped string or a timestamp can never reach `context-consent.json` —
/// which is the byte-level pin's guarantee in vocabulary form (`prd.md` M10).
///
/// Stdlib-only by design: this file is the seam's home in `VoccaCore`, whose import
/// allow-list is empty (`CoreBoundaryTests`).
public enum ConsentBundleID {
    /// Whether `bundleID` has the reverse-DNS bundle-ID shape. `nil` is not a bundle ID — the
    /// gate's nil refusal lives here, so ``ContextConsentGate``'s `allows(bundleID:)` needs no
    /// nil special case of its own.
    public static func isValid(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty, bundleID.count <= 255, bundleID.contains(".") else {
            return false
        }
        return bundleID.unicodeScalars.allSatisfy { scalar in
            !scalar.properties.isWhitespace
                && scalar.value >= 0x20
                && scalar.value != 0x7F
                && !(0x80...0x9F).contains(scalar.value)
        }
    }
}