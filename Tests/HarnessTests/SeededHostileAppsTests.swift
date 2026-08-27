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
@testable import VoccaInject
import XCTest

/// **The seeded hostile set, pinned as data** (`memory-order/spec.md` R5).
///
/// ``SeededHostileApps`` is the counterpart of ``SeededInjectionAllowlist``: one blesses the
/// accessibility rung for applications whose fields are known-good, the other withholds it from
/// applications whose fields are known to lie. Both are *data*, so both are pinned by exact set
/// rather than by behaviour — a bundle identifier silently added to either list changes which
/// rung a user's first dictation attempts, and that is a product decision, not a refactor.
///
/// What this file cannot check, and what `SMOKE_CHECKLIST.md` must: that the identifiers are
/// **correct**. A typo fails the exact-set assertion below; a wrong-but-consistent identifier
/// passes it and silently seeds nothing. The `plutil` confirmation against the installed
/// application's `CFBundleIdentifier` is the only thing that closes that gap (the
/// `injection-adapters` convention, `SeededInjectionAllowlist.swift:43-45`).
///
/// **Google Docs is seeded as `com.google.Chrome`, and that is deliberate.** The plan named
/// `com.google.docs`; no such bundle identifier exists. Docs in a browser tab reports its
/// *host* — `com.google.Chrome`, plutil-confirmed here — and Docs installed as a Chrome PWA
/// reports `com.google.Chrome.app.<32-character extension hash>`, which differs per
/// installation and so cannot be seeded at all. Seeding the host is the only spelling a running
/// application ever reports, and it is the same class the allowlist seed already excludes for
/// the same reason (`SeededInjectionAllowlist.swift:26-30`: browsers' custom editors are exactly
/// where AX reports insertions that did not happen).
final class SeededHostileAppsTests: XCTestCase {

    /// The exact set: two identifiers, no more. Adding a third is a deliberate edit that must
    /// come here as well as to the data.
    func testTheHostileSeedIsExactlyTheTwoKnownHostileApps() {
        XCTAssertEqual(
            SeededHostileApps.hostileBundleIDs,
            ["com.google.Chrome", "com.tinyspeck.slackmacgap"],
            """
            The seeded hostile set changed. It is the list of applications whose first dictation \
            must not attempt the accessibility rung, and every entry is a product decision — \
            confirm the identifier against the installed app's CFBundleIdentifier before \
            changing it here.
            """)
    }

    /// The two seeds are disjoint. An identifier in both lists would ask the projection to
    /// bless and withhold the same rung for the same application, and the merge order — not the
    /// data — would silently decide which wins.
    func testTheHostileSeedAndTheAllowlistSeedAreDisjoint() {
        XCTAssertTrue(
            SeededHostileApps.hostileBundleIDs
                .isDisjoint(with: SeededInjectionAllowlist.seedBundleIDs),
            """
            An application appears in both the accessibility allowlist seed and the hostile seed. \
            One of the two lists is wrong: the allowlist claims its fields are read-back \
            verifiable, and the hostile list claims they lie.
            """)
    }

    /// The identifiers are spelled as bundle identifiers, not as display names. A display name
    /// here would seed nothing at all and would never fail a behavioural test, because no
    /// application ever reports it.
    func testTheHostileSeedEntriesAreReverseDNSIdentifiers() {
        for identifier in SeededHostileApps.hostileBundleIDs {
            XCTAssertTrue(
                identifier.contains("."),
                "\(identifier) is not a reverse-DNS bundle identifier.")
            XCTAssertFalse(
                identifier.contains(" "),
                "\(identifier) looks like a display name, not a bundle identifier.")
        }
    }
}
