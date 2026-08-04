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

import AppKit

/// Vocca's composition root: everything the process does before it starts taking events.
///
/// ## Why this is a package module and not `App/VoccaApp.swift`
///
/// The Xcode app target's sources sit outside the SwiftPM package, which means outside every
/// guarantee this repository has. They are not seen by `ModuleBoundaryTests`, and — the one that
/// matters — they are not driven by `VoccaNetworkProbe`, so the zero-network invariant, a permanent
/// release blocker, says nothing whatsoever about them. That is not a hypothetical gap: `App/` is
/// exactly where an update checker, a crash reporter or a Sparkle integration lands by convention,
/// and those are the archetypal network callers.
///
/// So the bootstrap lives here, where the probe can reach it, and `App/VoccaApp.swift` is reduced
/// to a single call that a test pins character for character.
///
/// ## Why `configure` and `main` are separate
///
/// The split is structural, not stylistic. ``main()`` ends in `NSApplication.run()`, which does not
/// return — no test can call it. ``configure(_:)`` is therefore where all the start-up work goes,
/// so that the drivable seam stops just short of the run loop and the probe can exercise the real
/// thing rather than a copy of it.
///
/// **When a capability adds start-up work, it goes in ``configure(_:)``.** Work added to
/// ``main()`` around the `run()` call is invisible to the invariant.
public enum AppBootstrap {

    /// Everything the app sets up before the run loop starts. Safe to call from a test or from the
    /// network probe: it registers state and touches no run loop.
    ///
    /// `.accessory` alongside `LSUIElement` in `Info.plist`. Both are set on purpose: the plist key
    /// is what the Dock and Launch Services read before the process starts, and the activation
    /// policy is what `NSApplication` honours once it has. Setting only one leaves a window between
    /// launch and this call during which the app can take focus — and for a tool whose job is
    /// typing into *another* app's text field, taking focus means typing into the wrong place.
    @MainActor
    public static func configure(_ application: NSApplication) {
        application.setActivationPolicy(.accessory)
    }

    /// Configures the shared application and hands control to its run loop. Does not return.
    ///
    /// Deliberately trivial: everything here is beyond the reach of the zero-network probe, so the
    /// only safe amount of logic is none.
    @MainActor
    public static func main() {
        let application = NSApplication.shared
        configure(application)
        application.run()
    }
}
