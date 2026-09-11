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

/// **The seeded no-field set — the applications that pass the frontmost-app fallback's policy
/// gate (a `.regular` activation policy) but are genuinely not dictation targets, shipped as
/// data rather than as a decision.**
///
/// The fallback in ``TargetResolution/resolve()`` substitutes a frontmost application's bundle
/// ID for the AX read's "nothing focused" answer. That substitution must not invent a target
/// where the frontmost app is real and `.regular` but has **no field to type into** — this set
/// is that last gate, the mirror image of ``SeededHostileApps`` (which withholds the
/// accessibility rung from apps whose fields *lie*, where this withholds the whole target from
/// apps that have no field at all).
///
/// ## Why the seed carries only `.regular` no-field apps
///
/// The policy gate already excludes the dock, menu-bar and utility applications: an
/// `.accessory` or `.prohibited` activation policy means the app is not a document application,
/// and ``TargetResolution`` refuses to fall back to one before this set is ever consulted. So
/// the seed carries only the `.regular` applications that are still not targets — the desktop
/// itself.
///
/// ## Why Finder
///
/// Finder is the desktop: it is `.regular`, it is frontmost whenever the user is sitting on the
/// Finder desktop or has Finder focused, and there is no text field for an insertion to land
/// in. A dictation over Finder must resolve to "no usable target" exactly as it did before the
/// fallback existed — `bundleID == nil` keeps meaning "genuinely no usable target" (`R5`).
///
/// The set is extensible: a future `.regular` no-field application is added here, with its
/// reasoning, the same way hostile applications join ``SeededHostileApps``.
public enum SeededNoFieldApps {

    /// The seed: one bundle identifier whose frontmost-app fallback is withheld.
    public static let bundleIDs: Set<String> = [
        // Finder — the desktop, `.regular` and frontmost on the desktop, with no field to type
        // into. The fallback must not turn the desktop into a target.
        "com.apple.finder",
    ]
}