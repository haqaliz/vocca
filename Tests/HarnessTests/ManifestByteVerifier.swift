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

import CryptoKit
import Foundation
import VoccaASR

/// What one manifest entry turned out to be, measured against the bytes on disk.
///
/// The failing cases are kept apart rather than folded into one "bad" answer because their
/// repairs are different: a missing file is a broken provisioning run, a wrong byte count is a
/// manifest entry that was written rather than measured, a wrong digest is bytes that are not the
/// bytes the manifest was generated from, and an unreadable file is neither — it is a path that
/// exists and is not a file. A verifier that reported all four the same way would send the reader
/// looking in the wrong place three times out of four.
enum ManifestFileVerdict: Equatable, CustomStringConvertible {
    /// The file exists and both its length and its SHA-256 match the manifest.
    case matched(name: String)
    /// The manifest declares a file that is not on disk.
    case missing(name: String)
    /// The file's length on disk is not the length the manifest declares.
    case byteCountMismatch(name: String, declared: Int, actual: Int)
    /// The file's length matches and its SHA-256 does not.
    case digestMismatch(name: String, declared: String, actual: String)
    /// The path exists but its bytes could not be read — a directory where a file is declared,
    /// or a file the process cannot open.
    case unreadable(name: String, reason: String)

    /// The manifest entry this verdict answers for.
    var fileName: String {
        switch self {
        case .matched(let name), .missing(let name):
            return name
        case .byteCountMismatch(let name, _, _):
            return name
        case .digestMismatch(let name, _, _):
            return name
        case .unreadable(let name, _):
            return name
        }
    }

    /// Whether this entry verified. Exhaustive with no `default:`, so a case added here must say
    /// which side of the line it falls on rather than defaulting to "fine".
    var isMatch: Bool {
        switch self {
        case .matched:
            return true
        case .missing, .byteCountMismatch, .digestMismatch, .unreadable:
            return false
        }
    }

    var description: String {
        switch self {
        case .matched(let name):
            return "\(name): matched"
        case .missing(let name):
            return "\(name): declared by the manifest and not on disk"
        case .byteCountMismatch(let name, let declared, let actual):
            return "\(name): manifest declares \(declared) bytes, disk has \(actual)"
        case .digestMismatch(let name, let declared, let actual):
            return "\(name): manifest declares sha256 \(declared), disk has \(actual)"
        case .unreadable(let name, let reason):
            return "\(name): could not be read — \(reason)"
        }
    }
}

/// Checks a shipped manifest's declared SHA-256 digests and byte counts against the bytes a
/// provisioned model directory actually holds.
///
/// This is the machinery behind `verification-smoke`'s R1, and it lives in the test target
/// deliberately: the product verifies digests at *download* time, inside ``ModelStore``, against
/// bytes it has just fetched. What has never been checked is the other direction — whether the
/// manifests this repository ships describe the artifacts they claim to — and that is a question
/// about the repository, asked by a test, not a runtime behaviour to add to the app.
///
/// Two properties it must have, both learned the hard way:
///
/// - **It reads local bytes and nothing else.** No transport, no store, no network. The
///   zero-network invariant is absolute, and a "verification" that fetched what it was verifying
///   would prove only that the fetch and the manifest agreed with each other.
/// - **It answers for every file in one pass.** A manifest produced by a partial provisioning run
///   has more than one wrong entry, and stopping at the first would cost a re-download per line.
enum ManifestByteVerifier {

    /// The chunk size the digest is computed over: large enough that a 1.6 GB GGUF is not read a
    /// page at a time, small enough that the file is never resident in memory whole. The store's
    /// own artifacts reach 1.6 GB, so reading a file with `Data(contentsOf:)` here would put the
    /// whole model in the test process's address space.
    private static let chunkSize = 1 << 20

    /// Verifies every file `manifest` declares against `versionDirectory`.
    ///
    /// Files are sought where ``ModelStore`` commits them: under `<versionDirectory>/` for a flat
    /// manifest, and under `<versionDirectory>/<sdkDirectory>/` for an SDK-shaped one — the
    /// layout the F1 spike measured, and the reason a verifier pointed at the version root alone
    /// would report a healthy Parakeet install as thirteen missing files.
    ///
    /// - Returns: one verdict per manifest entry, in manifest order — successes included, so a
    ///   caller can tell "nothing was checked" from "everything passed".
    static func verify(manifest: ModelManifest, versionDirectory: URL) -> [ManifestFileVerdict] {
        let filesRoot =
            manifest.sdkDirectory.map {
                versionDirectory.appendingPathComponent($0, isDirectory: true)
            } ?? versionDirectory
        return manifest.files.map { file in
            verify(file: file, under: filesRoot)
        }
    }

    /// The failing subset of a run's verdicts, in the order they were produced.
    static func failures(in verdicts: [ManifestFileVerdict]) -> [ManifestFileVerdict] {
        verdicts.filter { !$0.isMatch }
    }

    private static func verify(file: ManifestFile, under filesRoot: URL) -> ManifestFileVerdict {
        let url = filesRoot.appendingPathComponent(file.name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing(name: file.name)
        }

        let measured: (byteCount: Int, digest: String)
        do {
            measured = try measure(at: url)
        } catch {
            return .unreadable(name: file.name, reason: String(describing: error))
        }

        // Length first, and it is the only failure reported when it is wrong: bytes of the wrong
        // length necessarily hash differently, so printing both would be two lines describing one
        // defect — and the length is the legible half. It was the 2-byte `config.json` that named
        // the Parakeet placeholder for what it was.
        guard measured.byteCount == file.byteCount else {
            return .byteCountMismatch(
                name: file.name, declared: file.byteCount, actual: measured.byteCount)
        }
        guard measured.digest.lowercased() == file.sha256.lowercased() else {
            return .digestMismatch(
                name: file.name, declared: file.sha256, actual: measured.digest)
        }
        return .matched(name: file.name)
    }

    /// The file's length and SHA-256, both from the same single streaming pass.
    ///
    /// The length is counted from the bytes read rather than taken from the filesystem's
    /// metadata, because the metadata is a second source that can answer for a path the read
    /// cannot open — a directory reports a size — and this check exists precisely to stop a
    /// second source standing in for the bytes.
    private static func measure(at url: URL) throws -> (byteCount: Int, digest: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount = 0
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
            byteCount += chunk.count
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (byteCount, digest)
    }
}
