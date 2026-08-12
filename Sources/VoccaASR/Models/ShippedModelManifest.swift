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

/// Why a shipped manifest could not be produced.
///
/// One case, and it is the only failure this loader can have: the JSON file is a bundle resource
/// of this module, so a missing file is a broken build or a broken install — never a runtime
/// choice.
public enum ShippedModelManifestError: Error, Equatable, CustomStringConvertible {
    /// The manifest JSON for the tier is not in this module's bundle under
    /// `Models/Manifests/`. The `Package.swift` resource declaration and this file's name table
    /// have drifted, or the resource was stripped.
    case missingBundleResource(tier: EngineTier, fileName: String)

    public var description: String {
        switch self {
        case .missingBundleResource(let tier, let fileName):
            return
                "the shipped manifest for \(tier) (\(fileName)) is not a bundle resource of this module"
        }
    }
}

/// The shipped model manifests: the tier → pinned-JSON mapping the composition root's engine
/// builder resolves, loaded from this module's bundle.
///
/// The manifest JSON files under `Sources/VoccaASR/Models/Manifests/` are the trust anchor of the
/// whole model lifecycle — every digest the store verifies against, and every file list the
/// downloader fetches, comes from these files — so they ship with the app: `Package.swift`
/// declares them as `.copy` resources, and this loader is the only route by which an engine
/// obtains its manifest (the `VoccaNetworkProbe`'s WER fixtures load from the repository path;
/// the product never does).
///
/// The mapping is closed over ``EngineTier`` — a tier added to the Core enum must be given a
/// manifest here or this switch stops compiling, which is the same shape the picker's own
/// validation uses.
public enum ShippedModelManifest {

    /// The manifest for `tier`, loaded from this module's bundle and validated by the manifest
    /// decoder (unknown fields, digest spelling and path shape all fail here, at load, rather
    /// than at download time).
    ///
    /// - Throws: ``ShippedModelManifestError/missingBundleResource(tier:fileName:)`` when the
    ///   JSON is absent from the bundle; the manifest decoder's own errors when the JSON is
    ///   malformed.
    public static func load(for tier: EngineTier) throws -> ModelManifest {
        let fileName: String
        switch tier {
        case .parakeetV3:
            fileName = "parakeet-tdt-0.6b-v3"
        case .whisperTurbo:
            fileName = "whisper-large-v3-turbo"
        case .whisperTurboQ5:
            fileName = "whisper-large-v3-turbo-q5_0"
        }
        guard
            let url = Bundle.module.url(
                forResource: fileName, withExtension: "json",
                subdirectory: "Models/Manifests")
        else {
            throw ShippedModelManifestError.missingBundleResource(
                tier: tier, fileName: fileName)
        }
        return try ModelManifest.load(from: Data(contentsOf: url))
    }
}
