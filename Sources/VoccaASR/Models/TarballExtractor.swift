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

/// Why a tarball extraction did not complete.
///
/// Every case leaves the target directory **without the marker trio**, so the next run tries
/// again rather than trusting a partial extraction — no failure state is silently "extracted".
public enum TarballExtractorError: Error, Equatable, CustomStringConvertible {
    /// The tarball is not on disk. The download that should have produced it has not run, or its
    /// bytes were removed.
    case tarballMissing(tarball: URL)
    /// `/usr/bin/tar` exited non-zero: the archive is corrupt, truncated, or not an archive.
    case tarFailed(exitCode: Int32, tarball: URL)
    /// tar exited **0** and the marker trio is still incomplete. Measured on macOS: a zero-byte
    /// archive makes tar exit 0 silently, extracting nothing — so without this case an empty or
    /// wrong-content tarball would be a silent partial the next launch trusts.
    case markerComponentsMissing(tarball: URL)

    public var description: String {
        switch self {
        case .tarballMissing(let url):
            return "the tarball \(url.path) is not on disk"
        case .tarFailed(let exitCode, let url):
            return "tar exited \(exitCode) extracting \(url.path)"
        case .markerComponentsMissing(let url):
            return
                "extracting \(url.path) left the marker components incomplete "
                + "(\(TarballExtractor.markerComponents.joined(separator: ", ")))"
        }
    }
}

/// Extracts the Kokoro model tarball into a model directory, idempotently.
///
/// The artifact is one `kokoro-models.tar.gz` whose entries sit at the archive root
/// (`kokoro_frontend.mlmodelc/`, `kokoro_backend.mlmodelc/`, `voices/` — the release packaging
/// measured in the port's `scripts/release.sh`), so extracting into the store's SDK directory
/// puts the port's model tree exactly where `KokoroCoreML.KokoroEngine(modelDirectory:)` looks.
///
/// **The marker is the trio the port itself requires** (`ModelManager.modelsAvailable`):
/// `kokoro_frontend.mlmodelc`, `kokoro_backend.mlmodelc` and `voices/`. "Extracted" therefore
/// means "extracted far enough to run" — an interrupted extraction (the trio incomplete) is
/// re-extracted on the next run rather than trusted, which is the self-healing the launch path
/// depends on.
///
/// The extraction mechanism is `/usr/bin/tar xzf` via `Process` — Foundation only, no new
/// dependency, no network. The tarball's bytes are the store's concern (it verifies the pinned
/// digest at download time); this type owns only the layout.
public enum TarballExtractor {

    /// The components whose joint presence means the extraction completed — the port's own
    /// `modelsAvailable` check, spelled once here so the extractor and the engine cannot
    /// disagree about what "the models are there" means.
    public static let markerComponents = [
        "kokoro_frontend.mlmodelc",
        "kokoro_backend.mlmodelc",
        "voices",
    ]

    /// Extracts `tarball` into `directory` unless the marker trio is already present.
    ///
    /// - The directory is created if it does not exist.
    /// - When the trio is already there, this returns without reading the tarball — the skip is
    ///   what makes a double run safe, and what lets the launch path call this unconditionally.
    /// - When the tarball is missing, tar fails, or tar succeeds without producing the trio,
    ///   a ``TarballExtractorError`` is thrown and the directory is left without the trio, so
    ///   the next run re-extracts.
    public static func extractIfNeeded(tarball: URL, into directory: URL) throws {
        let fileManager = FileManager.default
        if hasMarkerComponents(in: directory, fileManager: fileManager) {
            return
        }
        guard fileManager.fileExists(atPath: tarball.path) else {
            throw TarballExtractorError.tarballMissing(tarball: tarball)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xzf", tarball.path, "-C", directory.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TarballExtractorError.tarFailed(
                exitCode: process.terminationStatus, tarball: tarball)
        }
        // tar exiting 0 is not proof of extraction: a zero-byte archive exits 0 and writes
        // nothing. The trio check is the guard that turns that into a recorded failure.
        guard hasMarkerComponents(in: directory, fileManager: fileManager) else {
            throw TarballExtractorError.markerComponentsMissing(tarball: tarball)
        }
    }

    /// Whether every marker component exists in `directory` — as a file or a directory, which is
    /// the same `fileExists` shape the port's own check uses.
    private static func hasMarkerComponents(in directory: URL, fileManager: FileManager) -> Bool {
        markerComponents.allSatisfy { component in
            fileManager.fileExists(atPath: directory.appendingPathComponent(component).path)
        }
    }
}
