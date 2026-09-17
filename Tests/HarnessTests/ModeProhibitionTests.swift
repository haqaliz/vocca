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
import XCTest

/// Raised when the `Mode/` scan cannot be evaluated meaningfully, so that measuring nothing is a
/// failure rather than a pass (the `KokoroSeamTestError` non-vacuous shape).
private enum ModeProhibitionTestError: Error, CustomStringConvertible {
    case modeDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .modeDirectoryMissing(let expectedAt):
            return """
                The mode machine's module directory does not exist at \(expectedAt). The \
                TextInjector prohibition is asserted by scanning that directory; if the machine \
                has moved or been renamed, this lint enforces nothing.
                """
        case .noSwiftFilesScanned(let under):
            return """
                No .swift files were found under \(under) — the prohibition was not evaluated \
                against anything. That is the vacuous green this check exists to prevent, so it \
                is a failure.
                """
        }
    }
}

/// **R2a, the roadmap's structural prohibition** (`CAPABILITY_ROADMAP.md:319`): "A test asserts
/// that in converse mode **no `TextInjector` call is ever made**". The seam (`:321`) makes the
/// injection path reachable only from the dictate state — and this suite pins the three layers
/// of that prohibition:
///
/// 1. **The vocabulary.** ``ModeSession`` and ``SessionModeEffect`` are pinned plain data — the
///    converse surface has no member that *could* hold an injector (compile pins: the exhaustive
///    switch over the effect and the member extractor below fail to build the moment a new case
///    or member appears, and no member binds a `TextInjector`). A planted converse-path type
///    that reached for an injector cannot compile against this vocabulary.
/// 2. **The behaviour.** A full converse cycle emits only `.started(.conversing, _)` and
///    `.stopped(.conversing, _, _)`, and the target slot stays nil.
/// 3. **The scan.** `Sources/VoccaCore/Mode/` never names `TextInjector` (comments stripped, the
///    ``SwiftSourceScanner`` shape). **RED because the directory does not exist yet** — the
///    missing-dir case throws, so the test cannot pass vacuously.
final class ModeProhibitionTests: XCTestCase {

    /// A buffer the fills carry — the interchange format, content irrelevant to the machine.
    private static let someBuffer = AudioBuffer(samples: [0.25, 0.5, 0.75], sampleRate: 16_000)

    // MARK: - Layer 1: the vocabulary

    /// The converse surface's members, extracted exhaustively: every ``SessionModeEffect`` case
    /// (the switch without a `default:` is the closed-enum pin) and every ``ModeSession`` member
    /// (the tuple bind is the member pin). None of them can hold a ``TextInjector`` — the types
    /// are pinned plain data, so a converse-path type built on this vocabulary has nothing to
    /// reach.
    func testTheConverseSurfaceCarriesNoInjector() {
        func extractMembers(
            from session: ModeSession<AudioBuffer>
        ) -> (mode: SessionMode, epoch: UInt64, buffer: AudioBuffer?, transcript: String?,
            target: TargetContext?)
        {
            (session.mode, session.epoch, session.buffer, session.transcript, session.target)
        }

        func surface(
            of effect: SessionModeEffect<AudioBuffer>
        ) -> (mode: SessionMode?, epoch: UInt64, session: ModeSession<AudioBuffer>?) {
            switch effect {
            case .started(let mode, let epoch):
                return (mode, epoch, nil)
            case .sessionControl(let mode):
                return (mode, 0, nil)
            case .refused:
                return (nil, 0, nil)
            case .stopped(let mode, let epoch, let session):
                return (mode, epoch, session)
            case .unchanged:
                return (nil, 0, nil)
            }
        }

        let machine = SessionModeMachine<AudioBuffer>()
        _ = machine.observe(.start(.conversing))
        machine.fill(buffer: Self.someBuffer)
        machine.fill(transcript: "a spoken reply")
        let effects = [machine.observe(.start(.conversing)), machine.observe(.stop)]

        for effect in effects {
            let (mode, epoch, session) = surface(of: effect)
            XCTAssertTrue(
                mode == nil || mode == .conversing,
                "a converse cycle's surface names only the converse mode, got \(String(describing: mode))")
            XCTAssertLessThanOrEqual(epoch, 1)
            if let session {
                let members = extractMembers(from: session)
                XCTAssertEqual(members.mode, .conversing)
                XCTAssertNil(members.target, "a converse record never carries a target")
            }
        }
    }

    // MARK: - Layer 3: the scan

    /// No file under `Sources/VoccaCore/Mode/` may name ``TextInjector`` — comments stripped, so
    /// a doc comment may discuss the prohibition. The directory does not exist until the machine
    /// lands, so this test is RED by construction (the missing-dir case throws) and cannot pass
    /// vacuously.
    func testNoModeFileNamesTheInjector() throws {
        let root = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaCore/Mode", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ModeProhibitionTestError.modeDirectoryMissing(expectedAt: root.path)
        }
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw ModeProhibitionTestError.noSwiftFilesScanned(under: root.path)
        }

        var offenders: [String] = []
        for file in files {
            let code = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            if code.contains("TextInjector") {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(
            offenders, [],
            """
            \(offenders.joined(separator: ", ")) names TextInjector. The injection path is \
            reachable only from the dictate state — the converse surface must have nothing to \
            reach (CAPABILITY_ROADMAP.md:319).
            """)
    }

    // MARK: - Layer 2: the behaviour

    /// A full converse cycle produces only the pinned effects: exactly `.started(.conversing, _)`
    /// and `.stopped(.conversing, _, _)`, the record carried inside the stop, target slot nil.
    func testAConverseCycleProducesOnlyThePinnedEffects() {
        let machine = SessionModeMachine<AudioBuffer>()

        let first = machine.observe(.start(.conversing))
        machine.fill(buffer: Self.someBuffer)
        machine.fill(transcript: "a spoken reply")
        let second = machine.observe(.stop)

        guard case .started(.conversing, 1) = first else {
            XCTFail("expected .started(.conversing, epoch: 1), got \(first)")
            return
        }
        guard case .stopped(.conversing, 1, let record) = second else {
            XCTFail("expected .stopped(.conversing, epoch: 1, _), got \(second)")
            return
        }
        XCTAssertEqual(record.mode, .conversing)
        XCTAssertEqual(record.epoch, 1)
        XCTAssertEqual(record.buffer, Self.someBuffer)
        XCTAssertEqual(record.transcript, "a spoken reply")
        XCTAssertNil(record.target, "a converse cycle never fills the target slot")
    }
}