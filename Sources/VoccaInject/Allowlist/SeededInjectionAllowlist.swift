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

/// **The seeded allowlist — the P0 matrix's native AppKit set, shipped as data rather than as a
/// decision.**
///
/// ``DefaultInjectionStrategyOrder`` offers the accessibility rung first only to applications the
/// allowlist knows, and this struct is the list: exactly the three native AppKit applications of
/// the P0 matrix (`ROADMAP.md:91`) whose fields are known-good for the rung's insert-and-read-back
/// verification. The gate itself lives in the ``InjectionAllowlist`` protocol and in the strategy
/// order; this file is data, not decisions — its whole content is the bundle identifiers below,
/// and changing the policy is an edit to data, not to logic.
///
/// What is deliberately **not** here, and why:
/// - **Electron and browser applications** (VS Code, Slack, Discord, Safari, Chrome — including
///   Google Docs' custom editor). Their fields are exactly where AX lies: the API reports
///   insertion where nothing landed, or the field is a custom editor the standard attributes do
///   not reach. Clipboard leads for them by design (`ROADMAP.md:47`'s "clipboard-paste primary"),
///   and they reach accessibility only through C8's learned memory, never through this seed.
/// - **Terminals** (Terminal, iTerm2, Ghostty). A terminal is a shell before it is a field, and
///   *Secure Keyboard Entry* turns the Secure Input switch on per-app (`SMOKE_CHECKLIST.md` §6) —
///   both are failure classes a seed must not claim to know.
/// - **Java/other** (IntelliJ). The AWT field class is a different insertion surface from
///   AppKit's, unverified here.
///
/// The list is public so it is inspectable and replaceable (PRD S1): the composition root passes
/// this struct to ``DefaultInjectionStrategyOrder`` and can substitute or extend it, and C8's
/// strategy memory is a *second* ``InjectionStrategyOrder`` implementation, not a change to this
/// data.
public struct SeededInjectionAllowlist: InjectionAllowlist {

    /// The seed: three bundle identifiers, each read from the installed application's
    /// `Info.plist` and confirmed against `CFBundleIdentifier` on macOS (the `plutil` check,
    /// `injection-adapters` phase E).
    public static let seedBundleIDs: Set<String> = [
        // Notes — native AppKit text view; insert + read-back verified.
        "com.apple.Notes",
        // Mail — native AppKit message-body field; insert + read-back verified.
        "com.apple.mail",
        // TextEdit — native AppKit document text view; the matrix's plain-field exemplar.
        "com.apple.TextEdit",
    ]

    public init() {}

    public func contains(bundleID: String) -> Bool {
        Self.seedBundleIDs.contains(bundleID)
    }
}
