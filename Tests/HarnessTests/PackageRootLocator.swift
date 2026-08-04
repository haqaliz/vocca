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

/// Thrown by ``PackageRootLocator/find(from:)`` when no `Package.swift` is found by walking up
/// from the given file.
struct PackageRootNotFoundError: Error, CustomStringConvertible {
    let startingFrom: String

    var description: String {
        "Could not locate Package.swift by walking up from \(startingFrom)"
    }
}

/// Locates the Vocca package root the way every suite in `HarnessTests` needs to: by walking up
/// from a source file — always `#filePath`, so this never hardcodes an absolute path and keeps
/// working across checkouts and CI runners — until a directory containing `Package.swift` is
/// found.
///
/// This used to be five near-identical copies of this same walk, one in each of
/// `LicenseHeaderTests`, `ModuleBoundaryTests`, `ZeroNetworkTests`, `BundleConfigurationTests`,
/// and `Tests/XcodeHarnessBridge/PackageSuiteBridge.swift`. Consolidated here because a path walk
/// every suite depends on is one silent divergence away from two suites disagreeing about which
/// tree they are linting.
///
/// `PackageSuiteBridge.swift` keeps its own copy rather than importing this one: it is compiled
/// directly by `Vocca.xcodeproj` as a standalone source file, not built through `swift test`, and
/// is not a target in `Package.swift` at all (see that file's own header comment for why — Xcode
/// does not surface a local package's test targets to the app's scheme). There is no module
/// boundary through which it could import `HarnessTests`, so that second copy is structural, not
/// an oversight.
enum PackageRootLocator {
    static func find(from filePath: String) throws -> URL {
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw PackageRootNotFoundError(startingFrom: filePath)
    }
}
