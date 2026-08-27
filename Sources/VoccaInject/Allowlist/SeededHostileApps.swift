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

/// **The seeded hostile set — the applications whose first dictation must not attempt the
/// accessibility rung, shipped as data rather than as a decision.**
///
/// The mirror image of ``SeededInjectionAllowlist``. That list blesses three native AppKit
/// applications whose fields are known-good for insert-and-read-back verification; this one
/// withholds the rung from applications whose fields are known to *lie about it* — the class the
/// allowlist's own comment already names (`SeededInjectionAllowlist.swift:26-30`): browsers and
/// Electron shells, where the accessibility API reports an insertion that never landed, or where
/// the field is a custom editor the standard attributes do not reach.
///
/// The entries are folded into the strategy snapshot once, at load, as a demotion of
/// ``InjectionRung/accessibility`` with a re-probe window minted from that instant. That makes
/// the seed an **initial condition, not a life sentence**: after the window
/// (``StrategyMemoryTargets/reprobeWindowSeconds``) the rung is offered once more, so an
/// application whose next update fixes its accessibility support is rediscovered (PRD R4). A
/// *learned* entry for the same application always wins the merge, so a verified promotion is
/// never re-demoted by the seed at the next launch.
///
/// ## Why Google Docs is spelled `com.google.Chrome`
///
/// Google Docs has no bundle identifier of its own. Opened in a browser tab — how nearly everyone
/// uses it — the focused application is the browser, and the resolver reports
/// `com.google.Chrome`. Installed as a Chrome PWA it reports
/// `com.google.Chrome.app.<32-character extension hash>`, which differs per installation and so
/// cannot be seeded at all. Seeding the host is the only spelling a running application ever
/// reports, and it withholds the rung from exactly the class it is meant to: every web editor
/// reached through Chrome.
///
/// ## The identifiers are unverified data, and that is a smoke-checklist obligation
///
/// `com.google.Chrome` was read from the installed application's `CFBundleIdentifier` with
/// `plutil` (the `injection-adapters` convention). `com.tinyspeck.slackmacgap` was **not** — Slack
/// is not installed on the authoring machine — so it carries the same caveat every unverified
/// seed does: a wrong-but-plausible identifier passes every test in the suite and silently seeds
/// nothing at all.
public enum SeededHostileApps {

    /// The seed: two bundle identifiers whose accessibility rung starts demoted.
    public static let hostileBundleIDs: Set<String> = [
        // Chrome — Google Docs' actual host, and every other web editor's. The custom editor
        // surface is the canonical AX liar (`ROADMAP.md:91`'s hostile class).
        "com.google.Chrome",
        // Slack — an Electron shell; its message box reports insertions that do not land.
        "com.tinyspeck.slackmacgap",
    ]
}
