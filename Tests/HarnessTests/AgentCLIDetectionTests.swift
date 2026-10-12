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

import Synchronization
import VoccaActions
import XCTest

/// The known-agent detection resolver's contract suite (`agent-detection` spec acceptance 1-6,
/// PRD R2) — **detection = file-existence checks, nothing else**, over the injected seam.
///
/// ## The honest fact
///
/// The resolver maps the eight presets to `.detected(path:)` / `.notDetected` facts by asking
/// an injected file-existence closure about candidate paths, in a deterministic order. Never a
/// version, never "ready to run" — the surface copy says exactly that, and the resolver has no
/// vocabulary for more. Every acceptance below runs over a **recording fake**: the closure
/// records every path it was asked about, so the exact check set is asserted rather than
/// hoped — detection is provably nothing but these checks.
///
/// ## The seam ride
///
/// Existence rides `ActionConfigFileSystem.fileExists(atPath:)` (already shipped, already
/// injected into the registry) — the resolver takes the closure, never the file system, and
/// the shipped `AgentCLIDetection.swift` names no `FileManager` spelling and no transport
/// family (acceptance 5, asserted against the shipped file itself below).
///
/// ## The MVP cap, recorded
///
/// The candidate-path list ships as the **absolute** constants (`/opt/homebrew/bin`,
/// `/usr/local/bin`, `/usr/local/sbin`). The spec's `~/.local/bin`, `~/.cargo/bin` and
/// `~/.nix-profile/bin` are **kept out of the MVP**: expanding `~` needs a home directory, the
/// seam exposes none (the protocol has no home accessor), and naming the file system to find
/// one would be a third `FileManager`-naming file in `VoccaActions` — a lint-table widening,
/// not a ride. The injected PATH is the second leg, and `~`/relative/empty segments of it are
/// skipped, never checked.
final class AgentCLIDetectionTests: XCTestCase {

    // MARK: - Fixtures

    /// One preset with a stable id, `names` defaulting to the shipped single-name shape.
    private func preset(
        _ id: String, names: [String] = ["claude"], arguments: [String] = ["-p", "<task>"]
    ) -> KnownAgentPreset {
        KnownAgentPreset(id: id, displayName: id, candidateNames: names, arguments: arguments)
    }

    // MARK: - Acceptance 1 — the first candidate path resolves

    /// A preset whose candidate name exists in the first candidate path is `.detected` with
    /// that exact path — and the recording fake shows exactly one check happened: the resolver
    /// stops at the first existence, it does not keep asking.
    func testACandidateNameInTheFirstCandidatePathIsDetectedAtThatPath() async {
        let fake = RecordingFileExistence(existing: ["/opt/homebrew/bin/claude"])

        let result = await AgentCLIDetection.detect(
            catalog: [preset("claude")], fileExists: fake.fileExists, path: nil)

        XCTAssertEqual(
            result, ["claude": .detected(path: "/opt/homebrew/bin/claude")],
            "a binary in the first candidate path must resolve to that exact path")
        XCTAssertEqual(
            fake.recordedPaths, ["/opt/homebrew/bin/claude"],
            "the resolver must stop at the first existence — one check, not a sweep")
    }

    // MARK: - Acceptance 2 — first wins across candidate paths

    /// A binary present in two candidate paths reports the **earlier** one — the pinned order
    /// decides, not the file system's opinion.
    func testFirstWinsAcrossTwoCandidatePaths() async {
        let fake = RecordingFileExistence(
            existing: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"])

        let result = await AgentCLIDetection.detect(
            catalog: [preset("claude")], fileExists: fake.fileExists, path: nil)

        XCTAssertEqual(
            result, ["claude": .detected(path: "/opt/homebrew/bin/claude")],
            "the earlier candidate path must win when both hold the binary")
        XCTAssertEqual(
            fake.recordedPaths, ["/opt/homebrew/bin/claude"],
            "the winning check is the only check — first existence ends the preset's resolution")
    }

    // MARK: - Acceptance 3 — the injected PATH resolves names the candidate list does not

    /// An injected PATH string resolves a name absent from the candidate list: the candidate
    /// paths are asked first, then the PATH's **absolute** components in order. Relative,
    /// `~`-prefixed and empty segments are skipped — and the recording fake proves they were
    /// never asked about.
    func testAnInjectedPATHResolvesANameAbsentFromTheCandidateList() async {
        let fake = RecordingFileExistence(existing: ["/opt/other/codex"])

        let result = await AgentCLIDetection.detect(
            catalog: [preset("codex", names: ["codex"], arguments: ["exec", "<task>"])],
            fileExists: fake.fileExists,
            path: "/opt/tools:relative:~/bin::/opt/other")

        XCTAssertEqual(
            result, ["codex": .detected(path: "/opt/other/codex")],
            "the injected PATH must resolve a name the candidate list does not hold")
        XCTAssertEqual(
            fake.recordedPaths,
            [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "/usr/local/sbin/codex",
                "/opt/tools/codex",
                "/opt/other/codex",
            ],
            """
            the candidate paths must be asked first, then the PATH's absolute components in \
            order — and the relative, ~-prefixed and empty segments must never be checked, \
            because they resolve to nothing deterministic
            """)
        XCTAssertEqual(
            fake.recordedPaths.count, 5,
            "the skipped segments must be skipped, not asked — detection is exactly the checks "
                + "recorded")
    }

    /// Candidate names resolve **name-major**: every candidate path (and the PATH) is asked for
    /// the first name before the second name is tried anywhere. This is the shipped order the
    /// exact-check-set pin below relies on.
    func testCandidateNamesAreResolvedInOrderNameMajor() async {
        let fake = RecordingFileExistence(existing: ["/usr/local/bin/fallback"])

        let result = await AgentCLIDetection.detect(
            catalog: [preset("hybrid", names: ["primary", "fallback"])],
            fileExists: fake.fileExists,
            path: nil)

        XCTAssertEqual(
            result, ["hybrid": .detected(path: "/usr/local/bin/fallback")],
            "the second candidate name must still resolve — the first was absent everywhere")
        XCTAssertEqual(
            fake.recordedPaths,
            [
                "/opt/homebrew/bin/primary",
                "/usr/local/bin/primary",
                "/usr/local/sbin/primary",
                "/opt/homebrew/bin/fallback",
                "/usr/local/bin/fallback",
            ],
            """
            resolution must be name-major: the first candidate name is asked everywhere before \
            the second is tried anywhere — otherwise a later-named binary would shadow the \
            first name's own candidate paths
            """)
    }

    // MARK: - Acceptance 4 — absent everywhere is not detected, quietly

    /// A preset whose names exist nowhere resolves `.notDetected` — quietly: a returned value,
    /// never a throw, and the resolver has no log to be loud in. Both the nil-PATH and the
    /// injected-PATH shapes are driven.
    func testAbsentEverywhereIsNotDetectedQuietly() async {
        let withoutPATH = RecordingFileExistence(existing: [])
        let resultWithout = await AgentCLIDetection.detect(
            catalog: [preset("aider", names: ["aider"], arguments: ["--message", "<task>"])],
            fileExists: withoutPATH.fileExists,
            path: nil)
        XCTAssertEqual(resultWithout, ["aider": .notDetected])
        XCTAssertEqual(
            withoutPATH.recordedPaths,
            ["/opt/homebrew/bin/aider", "/usr/local/bin/aider", "/usr/local/sbin/aider"],
            "with no PATH injected, exactly the candidate paths are the whole check set")

        let withPATH = RecordingFileExistence(existing: [])
        let resultWith = await AgentCLIDetection.detect(
            catalog: [preset("aider", names: ["aider"], arguments: ["--message", "<task>"])],
            fileExists: withPATH.fileExists,
            path: "/usr/bin:/bin")
        XCTAssertEqual(resultWith, ["aider": .notDetected])
        XCTAssertEqual(
            withPATH.recordedPaths,
            [
                "/opt/homebrew/bin/aider",
                "/usr/local/bin/aider",
                "/usr/local/sbin/aider",
                "/usr/bin/aider",
                "/bin/aider",
            ],
            "an injected PATH widens the check set, never narrows it")
    }

    // MARK: - A1/A7 — a home-relative CLI resolves when a home is injected

    /// **A1 — a binary under the injected home resolves**, the founder's real case: `opencode`
    /// lives at `~/.opencode/bin/opencode` and was reported not detected because the resolver
    /// only looked at the absolute trio. With `homeDirectory:` injected, the home dirs are asked
    /// after the absolute trio and the first existence ends the resolution — the exact check
    /// sequence is pinned so the join rule and the order cannot drift apart.
    func testAHomeInstalledCLIResolvesWhenAHomeIsInjected() async {
        let fake = RecordingFileExistence(existing: ["/Users/aliz/.opencode/bin/opencode"])

        let result = await AgentCLIDetection.detect(
            catalog: [preset("opencode", names: ["opencode"])],
            fileExists: fake.fileExists,
            path: nil,
            homeDirectory: "/Users/aliz")

        XCTAssertEqual(
            result, ["opencode": .detected(path: "/Users/aliz/.opencode/bin/opencode")],
            "a binary under the injected home must resolve to its joined exact path")
        XCTAssertEqual(
            fake.recordedPaths,
            [
                "/opt/homebrew/bin/opencode",
                "/usr/local/bin/opencode",
                "/usr/local/sbin/opencode",
                "/Users/aliz/.local/bin/opencode",
                "/Users/aliz/.opencode/bin/opencode",
            ],
            """
            the absolute trio is asked first, then the home-relative dirs in the pinned order — \
            and the first existence ends the preset's resolution
            """)
    }

    /// **A7 — a trailing slash on the injected home is normalised by one rule**: strip one
    /// trailing `/`, then join `home + "/" + component`. Without it the join would produce
    /// `/Users/aliz//.opencode/bin/…`, a path the file system is not asked about in the form the
    /// surface reports.
    func testATrailingSlashHomeIsNormalised() async {
        let fake = RecordingFileExistence(existing: ["/Users/aliz/.opencode/bin/opencode"])

        let result = await AgentCLIDetection.detect(
            catalog: [preset("opencode", names: ["opencode"])],
            fileExists: fake.fileExists,
            path: nil,
            homeDirectory: "/Users/aliz/")

        XCTAssertEqual(
            result, ["opencode": .detected(path: "/Users/aliz/.opencode/bin/opencode")],
            "a trailing slash must be stripped before the join — one rule, one path shape")
        XCTAssertEqual(
            fake.recordedPaths.last, "/Users/aliz/.opencode/bin/opencode",
            "the joined candidate must carry exactly one slash between the home and the component")
    }

    // MARK: - A2 — no home widens nothing (byte-identical to today)

    /// **A2 — a `nil` home is byte-identical to today**: the absolute trio (and the PATH, when
    /// injected) is the whole check set, and no home-relative dir is ever asked. The exact
    /// recorded sequence proves the widening is gated on a present home rather than checked
    /// against an empty prefix.
    func testANilHomeAsksNoHomeRelativeDirectory() async {
        let fake = RecordingFileExistence(existing: [])

        let result = await AgentCLIDetection.detect(
            catalog: [preset("opencode", names: ["opencode"])],
            fileExists: fake.fileExists,
            path: nil,
            homeDirectory: nil)

        XCTAssertEqual(result, ["opencode": .notDetected])
        XCTAssertEqual(
            fake.recordedPaths,
            [
                "/opt/homebrew/bin/opencode",
                "/usr/local/bin/opencode",
                "/usr/local/sbin/opencode",
            ],
            "a nil home must add no check — the check set is exactly today's candidate paths")
    }

    /// **A2 (empty half) — an empty home string widens nothing**, the `nil`-equivalent edge: it
    /// must never produce a check like `/.local/bin/opencode` from an empty prefix.
    func testAnEmptyHomeWidensNothing() async {
        let fake = RecordingFileExistence(existing: [])

        _ = await AgentCLIDetection.detect(
            catalog: [preset("opencode", names: ["opencode"])],
            fileExists: fake.fileExists,
            path: nil,
            homeDirectory: "")

        XCTAssertEqual(
            fake.recordedPaths,
            [
                "/opt/homebrew/bin/opencode",
                "/usr/local/bin/opencode",
                "/usr/local/sbin/opencode",
            ],
            "an empty home is treated as no home — it widens nothing and never joins an empty "
                + "prefix")
    }

    // MARK: - A3 — the resolution order, name-major, with a home

    /// **A3 — the order is pinned**: per candidate name, the absolute trio, then the
    /// home-expanded dirs (in ``AgentCLIDetection/homeRelativeCandidatePaths`` order), then the
    /// PATH's absolute components — and it is **name-major**, so every leg is asked for the first
    /// name before the second name is tried anywhere. The recording fake asserts the exact
    /// sequence.
    func testTheHomeWidenedResolutionOrderIsNameMajor() async {
        let fake = RecordingFileExistence(existing: [])

        let result = await AgentCLIDetection.detect(
            catalog: [preset("hybrid", names: ["primary", "fallback"])],
            fileExists: fake.fileExists,
            path: "/opt/tools",
            homeDirectory: "/Users/aliz")

        XCTAssertEqual(result, ["hybrid": .notDetected])
        XCTAssertEqual(
            fake.recordedPaths,
            [
                "/opt/homebrew/bin/primary",
                "/usr/local/bin/primary",
                "/usr/local/sbin/primary",
                "/Users/aliz/.local/bin/primary",
                "/Users/aliz/.opencode/bin/primary",
                "/Users/aliz/.bun/bin/primary",
                "/Users/aliz/.cargo/bin/primary",
                "/Users/aliz/.nix-profile/bin/primary",
                "/Users/aliz/.volta/bin/primary",
                "/Users/aliz/bin/primary",
                "/opt/tools/primary",
                "/opt/homebrew/bin/fallback",
                "/usr/local/bin/fallback",
                "/usr/local/sbin/fallback",
                "/Users/aliz/.local/bin/fallback",
                "/Users/aliz/.opencode/bin/fallback",
                "/Users/aliz/.bun/bin/fallback",
                "/Users/aliz/.cargo/bin/fallback",
                "/Users/aliz/.nix-profile/bin/fallback",
                "/Users/aliz/.volta/bin/fallback",
                "/Users/aliz/bin/fallback",
                "/opt/tools/fallback",
            ],
            """
            per name the absolute trio comes first, then the home dirs, then the PATH — and the \
            first name is asked everywhere before the second is tried anywhere
            """)
    }

    // MARK: - A4 — the home-relative constant, pinned

    /// **A4 — the home-relative directory list is pinned verbatim** and every entry is relative:
    /// no leading `/`, no `~`, not empty. A `~`/absolute entry here would be a path nobody checks
    /// (the join is `home + "/" + component`), so the pin refuses the shape at the source.
    func testTheHomeRelativeCandidatePathsArePinned() {
        XCTAssertEqual(
            AgentCLIDetection.homeRelativeCandidatePaths,
            [
                ".local/bin",
                ".opencode/bin",
                ".bun/bin",
                ".cargo/bin",
                ".nix-profile/bin",
                ".volta/bin",
                "bin",
            ],
            "the home-relative list is the pinned widening — a retune is a reviewed edit, and "
                + "this pin is what makes it one")
        for entry in AgentCLIDetection.homeRelativeCandidatePaths {
            XCTAssertFalse(entry.isEmpty, "an empty component would join to the home itself")
            XCTAssertFalse(entry.hasPrefix("/"), "an absolute component ignores the home entirely")
            XCTAssertFalse(entry.hasPrefix("~"), "a tilde is not expanded by the join rule")
        }
    }

    // MARK: - Acceptance 6 — the exact check set, over the shipped catalog

    /// The recording fake over the **shipped catalog** proves the honest fact: detection is
    /// exactly one file-existence check per (preset, candidate name, candidate path) — 8 × 1 ×
    /// 3 = 24 checks, in the deterministic order, with no PATH injected — and nothing else.
    /// A resolver that asked about a single path more or less than that fails here.
    func testTheRecordingFakeProvesDetectionIsExactlyFileExistenceChecks() async {
        let expectedChecks = KnownAgentPresets.all.flatMap { preset in
            preset.candidateNames.flatMap { name in
                AgentCLIDetection.candidatePaths.map { "\($0)/\(name)" }
            }
        }
        XCTAssertEqual(
            expectedChecks.count, 24,
            "the shipped catalog is eight presets × one candidate name × three candidate paths — "
                + "the exact-check-set claim is only meaningful at a known size")

        let fake = RecordingFileExistence(existing: [])
        let result = await AgentCLIDetection.detect(
            catalog: KnownAgentPresets.all, fileExists: fake.fileExists, path: nil)

        XCTAssertEqual(
            Set(result.keys), Set(KnownAgentPresets.all.map(\.id)),
            "every preset in the catalog must appear in the result — the section renders rows "
                + "for all eight, detected or not")
        XCTAssertTrue(
            result.values.allSatisfy { $0 == .notDetected },
            "nothing exists in this run — every preset must be not detected")
        XCTAssertEqual(
            fake.recordedPaths, expectedChecks,
            """
            detection must be exactly the 24 file-existence checks, in the deterministic order \
            (catalog order × candidate-name order × candidate-path order): the recording fake is \
            the proof that no check happened that the suite does not know about
            """)

        let withSkippedOnlyPATH = RecordingFileExistence(existing: [])
        _ = await AgentCLIDetection.detect(
            catalog: KnownAgentPresets.all,
            fileExists: withSkippedOnlyPATH.fileExists,
            path: "relative:~/bin::")
        XCTAssertEqual(
            withSkippedOnlyPATH.recordedPaths, expectedChecks,
            "a PATH holding only skipped segments must widen nothing — the check set stays the "
                + "24 candidate-path checks")
    }

    // MARK: - The candidate-path constants, pinned

    /// The candidate-path list is the resolver's one pinned constant: exactly the three
    /// absolute directories, in the shipped order, and no `~`-prefixed entry — the spec's
    /// tilde trio is recorded as out of the MVP because the seam exposes no home directory to
    /// expand against (a `~` literal here would be a path nobody checks).
    func testTheCandidatePathConstantsArePinned() {
        XCTAssertEqual(
            AgentCLIDetection.candidatePaths,
            ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/sbin"],
            "the candidate-path list is the pinned MVP cap — a retune is a reviewed edit, and "
                + "this pin is what makes it one")
        XCTAssertTrue(
            AgentCLIDetection.candidatePaths.allSatisfy { !$0.hasPrefix("~") },
            "a tilde-prefixed candidate path could never be checked — the seam exposes no home "
                + "directory, so a ~ entry would be a dead check recorded as live")
    }

    // MARK: - Acceptance 5 — spawns nothing, names no forbidden family

    /// The resolver file is pure over its injected closure: it names no transport or
    /// subprocess family (the `ActionTransportProhibitionTests` detector, run against the
    /// shipped file itself — the lint stays green because the resolver has nothing for it to
    /// find), no `FileManager` spelling (the seam protocol is the only file-system surface, and
    /// its two permitted files are the only ones that may name the family), and imports
    /// nothing — the detection vocabulary needs only the standard library.
    func testTheResolverFileNamesNoForbiddenFamilyAndRidesTheSeam() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoccaActions")
            .appendingPathComponent("Config")
            .appendingPathComponent("AgentCLIDetection.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        XCTAssertEqual(
            ActionTransportProhibitionTests.transportIdentifiers(inSource: source), [],
            "the resolver must name no transport or subprocess family — detection is a file-"
                + "existence question, and the transport lint stays green because the resolver "
                + "has nothing for it to find")
        XCTAssertFalse(
            source.contains("FileManager"),
            "the resolver must not name FileManager — existence rides the injected "
                + "ActionConfigFileSystem closure, and a second naming file in VoccaActions "
                + "would be a seam-table widening, not a ride")
        XCTAssertFalse(
            source.contains("import "),
            "the resolver must import nothing — not even Foundation; the catalog types are "
                + "Foundation-free and the seam is injected, so an import is the first step "
                + "away from the pure resolver")
    }

    // MARK: - A6 — the composition root passes the real home

    /// **A6 — `configure`'s `detectAgents` closure passes `homeDirectory: NSHomeDirectory()`**:
    /// the resolver takes the home as a parameter and never computes it, so the widening is inert
    /// unless the composition root supplies the real home. `configure` needs an `NSApplication`,
    /// so this is a source scan of the one `AgentCLIDetection.detect(` call — the
    /// `AppBootstrapWiringTests` precedent: a reverted call (the defaulted `nil`) silently
    /// reports every home-installed CLI as not detected.
    func testTheCompositionRootPassesTheRealHome() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root.appendingPathComponent("Sources/VoccaBootstrap/AppBootstrap.swift")
        let source = SwiftSourceScanner.stripComments(
            from: try String(contentsOf: file, encoding: .utf8))
        let header = "AgentCLIDetection.detect("
        guard let start = source.range(of: header) else {
            return XCTFail(
                """
                `configure`'s `detectAgents` closure no longer calls `AgentCLIDetection.detect(`. \
                That call is where the home-installed detection happens; if it moved, this pin \
                has to move with it rather than be deleted.
                """)
        }
        var depth = 0
        var body = ""
        for character in source[start.lowerBound...] {
            if character == "(" { depth += 1 }
            if depth > 0 { body.append(character) }
            if character == ")" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        XCTAssertFalse(body.isEmpty, "the `AgentCLIDetection.detect(` call must have arguments")
        XCTAssertTrue(
            body.contains("homeDirectory: NSHomeDirectory()"),
            """
            the composition root must pass `homeDirectory: NSHomeDirectory()` — the resolver \
            computes no home of its own, so without this argument every home-installed CLI \
            (the founder's `~/.opencode/bin/opencode`) is reported not detected
            """)
    }
}

// MARK: - Test double

/// A recording file-existence fake: answers membership in `existing` and records **every** path
/// it was asked about, in order — the honest-fact witness that detection is exactly these
/// checks, nothing else. `Mutex`-backed because the resolver may invoke the closure from any
/// task, and the `ComplaintRecorder` precedent holds: capture `self`, never the lock.
private final class RecordingFileExistence: Sendable {
    private let asked = Mutex<[String]>([])
    private let existing: Set<String>

    init(existing: Set<String>) {
        self.existing = existing
    }

    /// The paths asked about, in the exact order the resolver asked.
    var recordedPaths: [String] { asked.withLock { $0 } }

    /// The seam-shaped witness: `fileExists(atPath:) async -> Bool`, recording every call.
    var fileExists: @Sendable (String) async -> Bool {
        { path in
            self.asked.withLock { $0.append(path) }
            return self.existing.contains(path)
        }
    }
}