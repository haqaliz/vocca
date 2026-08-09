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

/// Why a manifest could not be trusted, named by the field that failed.
///
/// Every case is a *shape* failure, not a network failure: the manifest ships in-repo and is
/// never fetched (`spec.md:43`), so what can be wrong with it is what this enum says — a field
/// missing, a field this repository does not define, two files that would collide in the store,
/// or a digest verification could never have honoured.
public enum ModelManifestError: Error, Equatable, Sendable {
    /// A required field was absent. The payload is the JSON field name.
    case missingField(String)
    /// A field this repository does not define was present. The payload is the JSON field name.
    case unknownField(String)
    /// Two entries in `files` share a name; the second would overwrite the first in the store.
    case duplicateFileName(String)
    /// A file's `sha256` is not 64 hex characters — the shape a real digest always has.
    case invalidDigest(file: String)
    /// A file's name is not a safe relative path — empty, absolute, or traversing (`..`) —
    /// which would write outside the version directory.
    case invalidPath(file: String)
    /// `sdkDirectory` is not a single safe path component — the SDK's layout rule is exactly
    /// one directory deep.
    case invalidSDKDirectory(String)
}

/// One file of a model artifact: its name inside the version directory, its SHA-256 digest, and
/// its size in bytes.
///
/// The digest is the trust anchor: ``ModelStore`` verifies every downloaded byte against it, so a
/// manifest that decoded a wrong digest silently — non-hex, wrong length, or a duplicated name
/// that would let one file stand for two — would be a checksum registry that does not check.
/// Validation therefore happens at *decode* time, where the manifest's author (or a corrupted
/// file) finds out, not at download time, where only the user would.
public struct ManifestFile: Codable, Sendable, Equatable, Hashable {
    /// The file's name within `<root>/<engineID>/<version>/`, as the store writes it.
    public let name: String
    /// The SHA-256 of the file's bytes, as exactly 64 hex characters.
    public let sha256: String
    /// The file's size in bytes, as the manifest's author measured it.
    public let byteCount: Int

    public init(name: String, sha256: String, byteCount: Int) {
        self.name = name
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    public init(from decoder: Decoder) throws {
        try Self.rejectUnknownFields(in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = try container.decodeIfPresent(String.self, forKey: .name) else {
            throw ModelManifestError.missingField("name")
        }
        guard let sha256 = try container.decodeIfPresent(String.self, forKey: .sha256) else {
            throw ModelManifestError.missingField("sha256")
        }
        guard let byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount) else {
            throw ModelManifestError.missingField("byteCount")
        }
        guard Self.isHexDigest(sha256) else {
            throw ModelManifestError.invalidDigest(file: name)
        }
        // Names may be nested (`"Encoder.mlmodelc/model.mil"` — the SDK repo tree's shape) but
        // never absolute or traversing: the name becomes a filesystem path under the version
        // directory, and a manifest is trusted data only as far as the loader checks it.
        guard Self.isSafeRelativePath(name) else {
            throw ModelManifestError.invalidPath(file: name)
        }
        self.name = name
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    /// A file name is a safe relative path: non-empty, no leading slash, and no `.` or `..`
    /// component anywhere.
    static func isSafeRelativePath(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/")
            && name.split(separator: "/").allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Throws ``ModelManifestError/unknownField(_:)`` if the decoded object carries a key this
    /// type does not define.
    ///
    /// The scan cannot run through `CodingKeys`: a `KeyedDecodingContainer` typed with a fixed
    /// `CodingKey` enum drops unknown keys before `allKeys` can see them (measured on this SDK), so
    /// it runs through ``AnyStringKey`` — a key type that accepts every string — and asks which of
    /// the resulting keys `CodingKeys` cannot represent.
    private static func rejectUnknownFields(in decoder: Decoder) throws {
        let allKeys = try decoder.container(keyedBy: AnyStringKey.self)
        if let unknown = allKeys.allKeys.map(\.stringValue).first(where: { CodingKeys(stringValue: $0) == nil }) {
            throw ModelManifestError.unknownField(unknown)
        }
    }

    /// A SHA-256 digest is exactly 64 hex characters. Accepting anything else would let a
    /// truncated or corrupted registry entry decode as a digest that verification could compare
    /// against but never match.
    static func isHexDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private enum CodingKeys: String, CodingKey {
        case name, sha256, byteCount
    }
}

/// The checksum manifest of a model artifact: the engine and pinned version it belongs to, and the
/// file list every downloaded byte is verified against.
///
/// The manifest's *content* is data generated from the real artifact (the F1 spike's first real
/// download); the format and the machinery are what this aspect builds, so ``load(from:)`` is the
/// one door the checked-in manifest JSON comes through, and the shape validation below is what
/// makes "the checksum registry" something a machine can trust.
///
/// The type is deliberately engine-agnostic: `engineID` is a string directory key, and the
/// `EngineIdentity` binding lives in `parakeet-engine` (`spec.md:20-21`). It crosses actor
/// boundaries into ``ModelStore``, so it is `Sendable`.
public struct ModelManifest: Codable, Sendable, Equatable, Hashable {
    /// The store's directory key — `EngineIdentity.id` for the engine this artifact belongs to.
    public let engineID: String
    /// The pinned version this artifact is. A version directory is immutable once verified
    /// (`PRODUCT_SPEC.md:273`), so this value must be stable for the artifact's lifetime.
    public let version: String
    /// The single directory under the version directory that the artifact's files are stored in,
    /// when the consuming SDK requires it.
    ///
    /// The spike measured that FluidAudio's manual `load(from: D)` resolves the file home to
    /// `<D.parent>/<repo.folderName>/` (`spike_20260809.md` §2) — so an SDK-shaped manifest
    /// declares `sdkDirectory == <repo.folderName>`, the store commits the files under
    /// `<version>/<sdkDirectory>/`, and the engine loads with `D = <version>/<sdkDirectory>`.
    /// `nil` keeps the flat layout every existing manifest uses.
    public let sdkDirectory: String?
    /// Every file the artifact contains, with the digest each must match.
    public let files: [ManifestFile]

    public init(
        engineID: String, version: String, sdkDirectory: String? = nil, files: [ManifestFile]
    ) {
        self.engineID = engineID
        self.version = version
        self.sdkDirectory = sdkDirectory
        self.files = files
    }

    public init(from decoder: Decoder) throws {
        try Self.rejectUnknownFields(in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let engineID = try container.decodeIfPresent(String.self, forKey: .engineID) else {
            throw ModelManifestError.missingField("engineID")
        }
        guard let version = try container.decodeIfPresent(String.self, forKey: .version) else {
            throw ModelManifestError.missingField("version")
        }
        if let sdkDirectory = try container.decodeIfPresent(String.self, forKey: .sdkDirectory) {
            guard Self.isSafeSingleComponent(sdkDirectory) else {
                throw ModelManifestError.invalidSDKDirectory(sdkDirectory)
            }
            self.sdkDirectory = sdkDirectory
        } else {
            self.sdkDirectory = nil
        }
        let files = try container.decode([ManifestFile].self, forKey: .files)

        // Two entries with the same name would silently overwrite each other in the store, and a
        // manifest that says two files are one file cannot be verified honestly.
        var seen: Set<String> = []
        if let duplicate = files.first(where: { !seen.insert($0.name).inserted }) {
            throw ModelManifestError.duplicateFileName(duplicate.name)
        }

        self.engineID = engineID
        self.version = version
        self.files = files
    }

    /// The SDK's layout rule is exactly one directory deep: no slash, no `.`/`..`, non-empty.
    static func isSafeSingleComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    /// Throws ``ModelManifestError/unknownField(_:)`` if the decoded object carries a key this
    /// type does not define.
    ///
    /// The scan cannot run through `CodingKeys`: a `KeyedDecodingContainer` typed with a fixed
    /// `CodingKey` enum drops unknown keys before `allKeys` can see them (measured on this SDK), so
    /// it runs through ``AnyStringKey`` — a key type that accepts every string — and asks which of
    /// the resulting keys `CodingKeys` cannot represent.
    private static func rejectUnknownFields(in decoder: Decoder) throws {
        let allKeys = try decoder.container(keyedBy: AnyStringKey.self)
        if let unknown = allKeys.allKeys.map(\.stringValue).first(where: { CodingKeys(stringValue: $0) == nil }) {
            throw ModelManifestError.unknownField(unknown)
        }
    }

    /// Decodes and shape-validates a manifest from JSON data.
    ///
    /// This is the loader the checked-in manifest file is read through — and the loader every
    /// synthetic manifest in the suite goes through too, so the validation below cannot drift away
    /// from what the tests demand.
    public static func load(from data: Data) throws -> ModelManifest {
        try JSONDecoder().decode(ModelManifest.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case engineID, version, sdkDirectory, files
    }
}

/// A `CodingKey` that accepts every string, used only to enumerate the keys a decoded object
/// actually carries.
///
/// A `KeyedDecodingContainer` typed with a fixed `CodingKey` enum drops keys the enum does not
/// define before `allKeys` can see them, so an unknown-key scan through the enum would always come
/// back clean. This type is the untyped view: every key survives into `allKeys`, and the scan
/// compares against the real `CodingKeys` by name.
private struct AnyStringKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
