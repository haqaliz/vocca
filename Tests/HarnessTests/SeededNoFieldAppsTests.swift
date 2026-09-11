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
@testable import VoccaInject
import XCTest

/// **The seeded no-field set, pinned as data and as reasoning** (`resolver-fallback` S1/R3).
///
/// ``SeededNoFieldApps`` is the frontmost-app fallback's last gate: the `.regular` applications
/// that are genuinely not dictation targets. It is *data*, so it is pinned by exact set rather
/// than by behaviour — a bundle identifier silently added to it changes which frontmost apps
/// resolve to "no usable target", and that is a product decision, not a refactor.
///
/// The reasoning is pinned too, and that is the load-bearing half. The set exists **only
/// because** the R2 policy gate (`.regular` activation policy) cannot exclude the desktop
/// itself; if the set's documentation ever stops naming the `.accessory`/`.prohibited`
/// exclusion, the next person no longer knows why the set is a set at all — or that adding a
/// dock/menu-bar identifier here would be a contradiction, not an extension.
///
/// What this file cannot check, and what `SMOKE_CHECKLIST.md` must: that the identifier is
/// **correct**. A typo fails the exact-set assertion below; a wrong-but-consistent identifier
/// passes it and silently seeds nothing.
final class SeededNoFieldAppsTests: XCTestCase {

    /// The `.accessory`/`.prohibited` class the R2 policy gate already excludes before the seed
    /// is ever consulted — the dock, the menu bar and the utility applications the seed's own
    /// comment names. An identifier from this class is the one thing the seed must never
    /// contain: it would contradict the documented claim that the seed carries only `.regular`
    /// no-field applications.
    private static let accessoryPolicyClassTheGateExcludes = [
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
    ]

    /// The exact set: Finder, no more. Adding a second entry is a deliberate edit that must come
    /// here as well as to the data.
    func testTheNoFieldSeedNamesFinderAndOnlyFinder() {
        XCTAssertEqual(
            SeededNoFieldApps.bundleIDs,
            ["com.apple.finder"],
            """
            The seeded no-field set changed. It is the list of frontmost applications whose \
            fallback resolution must still yield "no usable target", and every entry is a \
            product decision — it must be `.regular` and have no field to type into before it \
            belongs here.
            """)
    }

    /// The reasoning pin: the set's documentation names the `.accessory` policy exclusion, and
    /// the set contains nothing from the class that exclusion already removes.
    ///
    /// Two assertions, because the claim being pinned is two-sided. The comment half is what
    /// keeps the set extensible with its reasoning attached; the disjoint half is what keeps a
    /// later edit from seeding an identifier the gate would already have excluded — the
    /// contradiction that silently doubles the gate. `R3` names the policy exclusion as part of
    /// the shipped reasoning, so this test defines that requirement and reads the shipped file
    /// to check it.
    func testTheSeedReasoningNamesThePolicyExclusion() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/VoccaInject/Allowlist/SeededNoFieldApps.swift"),
            encoding: .utf8)

        XCTAssertTrue(
            source.contains(".accessory"),
            """
            The seed's documentation no longer names the `.accessory` policy exclusion. That \
            exclusion is the reason the set exists: the R2 gate removes dock/menu-bar/utility \
            applications before the seed is consulted, so the seed carries only `.regular` \
            no-field apps — and a reader of the file must be able to see why. Restore the \
            reasoning in the set's doc comment.
            """)

        XCTAssertTrue(
            SeededNoFieldApps.bundleIDs.isDisjoint(
                with: Self.accessoryPolicyClassTheGateExcludes),
            """
            The seed contains an identifier from the `.accessory`/`.prohibited` class the R2 \
            policy gate already excludes: \
            \(SeededNoFieldApps.bundleIDs.intersection(Self.accessoryPolicyClassTheGateExcludes).sorted().joined(separator: ", ")). \
            The set's own documentation claims it carries only `.regular` no-field applications \
            — an accessory/utility application here would be silently seeding a gate that never \
            reaches the seed.
            """)
    }
}