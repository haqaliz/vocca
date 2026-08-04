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

import VoccaBootstrap

/// The `@main` shim, and nothing else. Do not add code here.
///
/// This file is the only source in the repository that lives outside the SwiftPM package, and that
/// costs it every guarantee the package has: `ModuleBoundaryTests` does not see it, and
/// `VoccaNetworkProbe` cannot drive it — so the zero-network invariant, a permanent release
/// blocker, says nothing at all about whatever is written here. `App/` is also where an update
/// checker, a crash reporter or a Sparkle integration lands by convention, which are exactly the
/// things that invariant exists to catch.
///
/// So the file is kept to a single call and pinned:
/// `BundleConfigurationTests.testAppTargetSourceIsOnlyAShimToTheBootstrapModule` compares its code
/// against an exact expected form and fails on any addition. Comments are free to change; code is
/// not.
///
/// **Everything that would go here goes in `AppBootstrap.configure(_:)` instead**, where the probe
/// reaches it.
@main
enum VoccaApp {
    @MainActor
    static func main() {
        AppBootstrap.main()
    }
}
