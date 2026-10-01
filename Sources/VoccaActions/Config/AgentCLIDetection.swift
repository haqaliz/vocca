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

/// One preset's detection fact — the vocabulary the Coding agents section renders from.
///
/// **The honest fact**: detection is *the binary exists at a resolved path*. Never a version,
/// never "ready to run" — the surface copy says exactly that, and this type has no vocabulary
/// for more.
public enum AgentDetection: Equatable, Sendable {
    /// The binary exists at `path` — the first existence the resolver found, in its pinned
    /// resolution order.
    case detected(path: String)

    /// The binary exists nowhere the resolver was allowed to look.
    case notDetected
}

/// The result of one detection pass: every preset id in the catalog, mapped to its fact.
public typealias AgentCLIDetectionResult = [String: AgentDetection]

/// The known-agent detection resolver (`agent-detection` spec, PRD R2) — a **pure** mapping
/// from the eight presets to detected/not-detected facts, over the injected file-system seam.
///
/// ## Detection = file-existence checks, nothing else
///
/// The resolver asks an injected `fileExists` closure about candidate paths, in a
/// deterministic order, and reports the first existence. It spawns nothing, versions nothing,
/// and has no other vocabulary: a preset is `.detected(path:)` when a check answered true,
/// `.notDetected` otherwise — quietly. The closure is the resolver's only contact with the
/// file system: it rides `ActionConfigFileSystem.fileExists(atPath:)` (already shipped, already
/// injected into the registry), and this file names no file-system type of its own.
///
/// ## Resolution order, pinned
///
/// Per preset, per candidate name, in order: (1) the **candidate path list**
/// (``candidatePaths``, joined with the name), (2) the injected PATH string split on `:` —
/// **absolute components only**; empty, relative and `~`-prefixed components are skipped,
/// never checked. First existence wins and ends that preset's resolution; a preset whose names
/// exist nowhere is `.notDetected`.
///
/// The environment is **injected, never read globally**: the caller passes the PATH string
/// (the app's own, at the composition root), so the resolver's behaviour is identical in the
/// suite and in the shipped app.
///
/// ## The MVP cap, recorded
///
/// The spec's `~/.local/bin`, `~/.cargo/bin` and `~/.nix-profile/bin` are **kept out of the
/// shipped candidate list**: expanding `~` needs a home directory, the seam exposes none (the
/// file-system protocol has no home accessor), and naming the file system to find one would
/// make this a third file-system-naming file in `VoccaActions` — a lint-table widening, not
/// a seam ride. The absolute trio ships, and a `~`-prefixed entry can never join the list:
/// it would be a path nobody checks, recorded as live. A home-injecting widening is a reviewed
/// edit to ``candidatePaths`` when the seam grows one.
public enum AgentCLIDetection {

    /// The candidate path list — the MVP cap, pinned verbatim by `AgentCLIDetectionTests`.
    /// Known absolute directories macOS agent CLIs install into, in the shipped order: Homebrew
    /// first, then the legacy Unix pair. A retune (a directory that became wrong, a home-
    /// injecting widening) is a reviewed edit; the pin is what makes it one.
    public static let candidatePaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/local/sbin",
    ]

    /// Resolve `catalog`'s presets against the injected existence closure and the injected PATH.
    ///
    /// - Parameters:
    ///   - catalog: The presets to resolve — every id appears in the result, detected or not.
    ///   - fileExists: The seam's existence check — `ActionConfigFileSystem.fileExists(atPath:)`
    ///     in the shipped composition, a recording fake in the suite. Asked in deterministic
    ///     order; the first `true` answers.
    ///   - path: The app process's own PATH, injected — never read globally. `nil` (or a
    ///     PATH of only skipped segments) widens nothing: the candidate paths are the whole
    ///     check set.
    /// - Returns: One `AgentDetection` per preset, keyed by preset id.
    public static func detect(
        catalog: [KnownAgentPreset],
        fileExists: @escaping @Sendable (String) async -> Bool,
        path: String?
    ) async -> AgentCLIDetectionResult {
        let pathDirectories = absolutePathComponents(of: path)
        var result: AgentCLIDetectionResult = [:]
        result.reserveCapacity(catalog.count)
        for preset in catalog {
            result[preset.id] = await detect(
                preset, fileExists: fileExists, pathDirectories: pathDirectories)
        }
        return result
    }

    /// Resolve one preset: candidate names in order, each asked against the candidate paths and
    /// then the PATH's directories. First existence wins and returns immediately.
    private static func detect(
        _ preset: KnownAgentPreset,
        fileExists: @escaping @Sendable (String) async -> Bool,
        pathDirectories: [String]
    ) async -> AgentDetection {
        for name in preset.candidateNames {
            for directory in candidatePaths {
                let candidate = directory + "/" + name
                if await fileExists(candidate) {
                    return .detected(path: candidate)
                }
            }
            for directory in pathDirectories {
                let candidate = directory + "/" + name
                if await fileExists(candidate) {
                    return .detected(path: candidate)
                }
            }
        }
        return .notDetected
    }

    /// The PATH's checkable directories: split on `:`, keeping only components that begin with
    /// `/`. An empty segment, a relative one and a `~`-prefixed one are all skipped by this
    /// single filter — none of them resolves to a deterministic absolute path to check.
    private static func absolutePathComponents(of path: String?) -> [String] {
        guard let path else { return [] }
        return path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }
}