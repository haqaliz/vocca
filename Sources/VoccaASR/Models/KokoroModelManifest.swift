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

/// Why the Kokoro manifest could not be produced.
///
/// One case, and it is the only failure this loader can have: the JSON file is a bundle resource
/// of this module, so a missing file is a broken build or a broken install — never a runtime
/// choice.
public enum KokoroModelManifestError: Error, Equatable, CustomStringConvertible {
    /// The Kokoro manifest JSON is not in this module's bundle under `Manifests/`. The
    /// `Package.swift` resource declaration and this loader's file name have drifted, or the
    /// resource was stripped.
    case missingBundleResource(fileName: String)

    public var description: String {
        switch self {
        case .missingBundleResource(let fileName):
            return "the Kokoro manifest (\(fileName)) is not a bundle resource of this module"
        }
    }
}

/// The Kokoro TTS manifest, loaded from this module's bundle.
///
/// **A parallel loader, deliberately.** ``ShippedModelManifest`` is closed over ``EngineTier`` —
/// a tier added to the Core enum must be given an ASR manifest there or the switch stops
/// compiling — and Kokoro is not an ``EngineTier``: it is a `SpeechSynthesizer` whose bytes are
/// one tarball under its own storage key, provisioned by its own launch step. Growing the
/// closed switch would have made "engine tier" mean two different kinds of thing; this sibling
/// loader keeps the ASR mapping exactly as closed as it was, and gives the TTS artifact the same
/// discipline: the pinned JSON ships in the bundle, `Package.swift` declares the same
/// `.copy("Models/Manifests")` resource directory, and ``ModelManifest/load(from:)`` validates
/// it at load — before any download exists to disagree with it.
public enum KokoroModelManifest {

    /// The storage key and bundle-resource name of the TTS artifact. One constant, so the
    /// loader and the manifest's `engineID` cannot drift apart the way two names for one
    /// directory did in the tier-keying defect.
    public static let engineID = "kokoro-82m"

    /// The manifest, loaded from this module's bundle and validated by the manifest decoder
    /// (unknown fields, digest spelling and path shape all fail here, at load, rather than at
    /// download time).
    ///
    /// - Throws: ``KokoroModelManifestError/missingBundleResource(fileName:)`` when the JSON is
    ///   absent from the bundle; the manifest decoder's own errors when the JSON is malformed.
    public static func load() throws -> ModelManifest {
        // `Models/Manifests` is declared in `Package.swift` as `.copy("Models/Manifests")`, and
        // SwiftPM's copy tool preserves only the directory's **base name** inside the resource
        // bundle — the copied layout is `Manifests/` at the bundle root, not `Models/Manifests/`
        // (`ShippedModelManifest.swift:70-76` measured the same mapping for the ASR manifests).
        let fileName = "\(engineID).json"
        guard
            let url = Bundle.module.url(
                forResource: engineID, withExtension: "json",
                subdirectory: "Manifests")
        else {
            throw KokoroModelManifestError.missingBundleResource(fileName: fileName)
        }
        return try ModelManifest.load(from: Data(contentsOf: url))
    }
}
