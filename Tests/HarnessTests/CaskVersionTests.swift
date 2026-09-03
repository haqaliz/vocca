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
import XCTest

/// Pins the Homebrew cask's `version "…"` to the bundle's `CFBundleShortVersionString`
/// (`docs/planning/release-distribution/version-bump/spec.md` M5).
///
/// The cask is the install path users get — `brew install --cask haqaliz/vocca/vocca` — and
/// the release workflow's tag==bundle gate reads the built Info.plist, so a drift between the
/// two means the cask installs a version it does not claim. This suite parses both files
/// headless: no Homebrew invocation, no built app bundle, no network — `App/Info.plist` and
/// `homebrew/vocca.rb` located the way every suite in `HarnessTests` locates the package.
final class CaskVersionTests: XCTestCase {

    /// The package root, located the way every suite in `HarnessTests` locates it.
    private var packageRoot: URL {
        get throws {
            try PackageRootLocator.find(from: #filePath)
        }
    }

    /// `App/Info.plist` parsed as a dictionary — the `BundleConfigurationTests.infoPlist()`
    /// shape: located from `#filePath`, read with a `Bundle`-free plist parse.
    private func infoPlist() throws -> [String: Any] {
        let url = try packageRoot.appendingPathComponent("App/Info.plist")
        let data = try Data(contentsOf: url)
        guard
            let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else {
            throw CaskVersionTestError.notADictionaryPropertyList(path: url.path)
        }
        return plist
    }

    func testCaskVersionMatchesBundleVersion() throws {
        let plist = try infoPlist()
        let bundleVersion = try XCTUnwrap(
            plist["CFBundleShortVersionString"] as? String,
            "CFBundleShortVersionString must be present as a string in App/Info.plist")

        let caskSource = try String(
            contentsOf: try packageRoot.appendingPathComponent("homebrew/vocca.rb"),
            encoding: .utf8)

        let regex = try NSRegularExpression(pattern: #"version "([^"]+)""#)
        let range = NSRange(caskSource.startIndex..<caskSource.endIndex, in: caskSource)
        guard let match = regex.firstMatch(in: caskSource, range: range) else {
            XCTFail("homebrew/vocca.rb must contain a version \"…\" line")
            return
        }
        let caskVersion = (caskSource as NSString).substring(with: match.range(at: 1))

        XCTAssertEqual(
            caskVersion, bundleVersion,
            """
            The Homebrew cask's version must equal the bundle's CFBundleShortVersionString: \
            the cask says '\(caskVersion)', the bundle says '\(bundleVersion)'. The cask is \
            the install path users get, and the release workflow's tag==bundle gate reads the \
            built Info.plist — a drift here means the cask installs a version it does not \
            claim. Bump both in the same release.
            """)
    }
}

private enum CaskVersionTestError: Error, CustomStringConvertible {
    case notADictionaryPropertyList(path: String)

    var description: String {
        switch self {
        case .notADictionaryPropertyList(let path):
            return "\(path) is not a dictionary property list"
        }
    }
}