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

/// The application entry point, and deliberately nothing more.
///
/// This target exists to produce a *bundle*: an identifier, an `Info.plist`, entitlements and a
/// code signature, which is what macOS binds TCC permission grants to. An SPM `.executable`
/// product cannot hold any of those, so hotkey registration, audio capture, transcription and the
/// widget would all be denied at runtime without it.
///
/// All real behaviour lives in the `Vocca*` modules of the SPM package, which this target links.
/// Nothing is started here yet — the capabilities that would start it have not been built. Resist
/// putting logic in this file when they are: an app target's sources are outside the package, so
/// they are invisible to `ModuleBoundaryTests` and to the zero-network probe, and code that lives
/// here is code those guarantees do not cover.
@main
enum VoccaApp {

    /// `@MainActor` because every `NSApplication` member is main-actor isolated under Swift 6
    /// strict concurrency. The `@main` entry point is invoked on the main thread, so this is an
    /// accurate description of where the code runs rather than a way to quiet the compiler.
    @MainActor
    static func main() {
        let application = NSApplication.shared

        // `.accessory` alongside `LSUIElement` in Info.plist. Both are set on purpose: the plist
        // key is what the Dock and Launch Services read before the process starts, and the
        // activation policy is what `NSApplication` itself honours once it has. Setting only one
        // leaves a window between launch and this line during which the app can take focus —
        // which, for a tool whose whole job is typing into *another* app's text field, means
        // typing into the wrong place.
        application.setActivationPolicy(.accessory)

        application.run()
    }
}
