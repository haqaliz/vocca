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

import Darwin
import VoccaContext
import VoccaCore
import XCTest

/// The `working-directory-source` aspect's contract suite (acceptances 1-6 of
/// `docs/planning/active-project-detection/working-directory-source/spec.md`), written
/// **before the seam exists** — every reference below is a compile pin, the
/// `AccessibilityContextSeamTests` precedent for a new adapter.
///
/// What is pinned here:
///
/// - the seam (`WorkingDirectoryRead.resolve`) returns the injected libproc closure's answer
///   unchanged, nil for nil, and a recording fake proves the exact call shape — the pid in,
///   one call, nothing else ever asked;
/// - the adapter (`WorkingDirectoryRead.libprocCwd`) is the unary pid-to-path read the
///   composition wires, and its failure path is deterministic: a pid that cannot exist
///   answers nil — never a throw (the never-throw doctrine, R1);
/// - the exposure (`AccessibilityContext.workingDirectory`) refuses Secure Input **first**
///   (the AX source's existing ordering — under Secure Input the read answers nil and the pid
///   read is never consulted), answers nil on no focused app and on any libproc failure —
///   quietly — and carries the focused pid to the libproc seam exactly once;
/// - the cwd read is the metadata lane: it never joins `ContextSnapshot`, and context
///   resolution is untouched by it.
///
/// The suite names no forbidden family of its own — no AX prefix, no FileManager spelling —
/// because the lints it verifies by their full-suite run (acceptance 5) scan the very shapes
/// this file would otherwise trip.
final class WorkingDirectoryReadTests: XCTestCase {

    /// A libproc read the test dictates, recording every pid it is asked about — a log rather
    /// than a flag, because "asked twice" and "asked at all" are different bugs. `final class`
    /// + `@unchecked Sendable`: the read is synchronous and single-threaded in these tests —
    /// the `AccessibilityContextSeamTests` double shape.
    private final class RecordingLibprocRead: @unchecked Sendable {
        private let answer: String?
        private(set) var pids: [pid_t] = []

        init(answer: String?) {
            self.answer = answer
        }

        func read(_ pid: pid_t) -> String? {
            pids.append(pid)
            return answer
        }
    }

    /// A focused-app read the test dictates — the raw context read and the pid read, counted —
    /// the `StubContextAXRead` shape with the new witness.
    private final class StubFocusedAppRead: ContextAXReading, @unchecked Sendable {
        private let raw: RawContextRead?
        private let pid: pid_t?
        private(set) var contextReadCount = 0
        private(set) var pidReadCount = 0

        init(raw: RawContextRead? = nil, pid: pid_t? = nil) {
            self.raw = raw
            self.pid = pid
        }

        func readContext() -> RawContextRead? {
            contextReadCount += 1
            return raw
        }

        func focusedProcessIdentifier() -> pid_t? {
            pidReadCount += 1
            return pid
        }
    }

    /// A Secure Input read the test dictates — the `StubContextSecureInputRead` shape.
    private final class StubSecureInputRead: ContextSecureInputReading, @unchecked Sendable {
        private let active: Bool
        private(set) var readCount = 0

        init(active: Bool = false) {
            self.active = active
        }

        func isSecureInputActive() -> Bool {
            readCount += 1
            return active
        }
    }

    /// The exposure under test: a focused app with a pid and a libproc read that answers a
    /// project path, Secure Input inactive.
    private func projectContext(
        libprocAnswer: String? = "/Users/aliz/dev/at/vocca",
        focusedPid: pid_t? = 4242
    ) -> (context: AccessibilityContext, libprocRead: RecordingLibprocRead) {
        let libprocRead = RecordingLibprocRead(answer: libprocAnswer)
        let context = AccessibilityContext(
            axRead: StubFocusedAppRead(pid: focusedPid),
            secureInputRead: StubSecureInputRead(),
            workingDirectoryRead: libprocRead.read)
        return (context, libprocRead)
    }

    // MARK: - The seam (acceptance 1-2)

    /// The seam returns the injected closure's answer unchanged — a pure pass-through.
    func testTheSeamReturnsTheInjectedAnswerUnchanged() {
        let answer = "/Users/aliz/dev/at/vocca"
        let result = WorkingDirectoryRead.resolve(pid: 42) { _ in answer }

        XCTAssertEqual(
            result, answer,
            "the seam must return the injected closure's answer unchanged")
    }

    /// A nil closure answer is a nil answer — the never-throw doctrine: any failure → nil.
    func testTheSeamReturnsNilForANilClosureAnswer() {
        XCTAssertNil(
            WorkingDirectoryRead.resolve(pid: 42) { _ in nil },
            "a nil closure answer must resolve to nil, never a throw")
    }

    /// The recording fake proves the exact call shape: the pid in, one call, nothing else.
    /// The seam's only observable side effect is the injected closure call.
    func testARecordingFakeProvesTheExactCallShape() {
        let fake = RecordingLibprocRead(answer: "/Users/aliz/dev/at/vocca")

        let result = WorkingDirectoryRead.resolve(pid: 4242, libprocRead: fake.read)

        XCTAssertEqual(
            result, "/Users/aliz/dev/at/vocca",
            "the answer must pass through unchanged")
        XCTAssertEqual(
            fake.pids, [4242],
            "the seam must ask the injected read exactly once, with exactly the pid it was "
                + "given — nothing else is ever called")
    }

    /// The real adapter's failure path is deterministic and grant-free — a pid that cannot
    /// exist answers nil, never a throw. This is the one leg of the adapter CI can execute
    /// (libproc needs no Accessibility grant, unlike the AX half): the call compiles, runs,
    /// and keeps the never-throw doctrine.
    func testTheAdapterAnswersNilForAPidThatCannotExist() {
        XCTAssertNil(
            WorkingDirectoryRead.libprocCwd(pid: -1),
            "a pid that cannot exist must answer nil — the adapter never throws")
    }

    // MARK: - The exposure (acceptance 3-4, 6)

    /// Secure Input refusal stays first (the AX source's existing ordering): under Secure
    /// Input the exposure answers nil and the pid read is never consulted — for a password
    /// field, never ask.
    func testSecureInputRefusalAnswersNilBeforeAnyPidRead() {
        let libprocRead = RecordingLibprocRead(answer: "/Users/aliz/dev/at/vocca")
        let appRead = StubFocusedAppRead(pid: 4242)
        let secureInputRead = StubSecureInputRead(active: true)
        let context = AccessibilityContext(
            axRead: appRead,
            secureInputRead: secureInputRead,
            workingDirectoryRead: libprocRead.read)

        let answer = context.workingDirectory()

        XCTAssertNil(answer, "Secure Input active means the cwd read answers nil")
        XCTAssertEqual(
            secureInputRead.readCount, 1,
            "the refusal must consult the secure-input read — the read is the fact")
        XCTAssertEqual(
            appRead.pidReadCount, 0,
            "when Secure Input is active the pid read must never be consulted — the refusal "
                + "happens before any pid resolution")
        XCTAssertEqual(
            libprocRead.pids, [],
            "when Secure Input is active the libproc seam must never be consulted")
    }

    /// No focused app (the pid read answers nil) → nil, quietly, and the libproc seam is
    /// never consulted.
    func testNoFocusedAppAnswersNilWithoutConsultingTheLibprocSeam() {
        let libprocRead = RecordingLibprocRead(answer: "/Users/aliz/dev/at/vocca")
        let context = AccessibilityContext(
            axRead: StubFocusedAppRead(pid: nil),
            secureInputRead: StubSecureInputRead(),
            workingDirectoryRead: libprocRead.read)

        let answer = context.workingDirectory()

        XCTAssertNil(answer, "no focused app means no pid means no cwd — nil, quietly")
        XCTAssertEqual(
            libprocRead.pids, [],
            "the libproc seam must never be consulted when there is no focused app")
    }

    /// Any libproc failure (the injected closure answers nil) → nil, quietly — the exposure
    /// never throws, exactly like the seam it rides.
    func testALibprocFailureAnswersNilQuietly() {
        let (context, libprocRead) = projectContext(libprocAnswer: nil)

        let answer = context.workingDirectory()

        XCTAssertNil(answer, "a failed libproc read is a nil cwd — never a throw")
        XCTAssertEqual(
            libprocRead.pids, [4242],
            "the failure is the seam's answer, not a skipped question — the read was made")
    }

    /// The focused app's pid is carried to the libproc seam exactly once, and the seam's
    /// answer is the exposure's answer, unchanged.
    func testWorkingDirectoryCarriesTheFocusedPidToTheLibprocSeamExactlyOnce() {
        let (context, libprocRead) = projectContext()

        let answer = context.workingDirectory()

        XCTAssertEqual(
            answer, "/Users/aliz/dev/at/vocca",
            "the exposure must return the libproc seam's answer unchanged")
        XCTAssertEqual(
            libprocRead.pids, [4242],
            "the focused pid must reach the libproc seam exactly once — the call shape is "
                + "pid in, answer out, nothing else")
    }

    /// The cwd read is the metadata lane: it never joins `ContextSnapshot` (the snapshot has
    /// exactly the seam's three members — pinned by `AccessibilityContextSeamTests`), and a
    /// working-directory read leaves context resolution untouched.
    func testTheCwdReadNeverJoinsTheContextSnapshot() {
        let raw = RawContextRead(
            bundleID: "com.apple.Notes", windowTitle: "Untitled",
            selectedText: "the quick brown fox")
        let appRead = StubFocusedAppRead(raw: raw, pid: 4242)
        let libprocRead = RecordingLibprocRead(answer: "/Users/aliz/dev/at/vocca")
        let context = AccessibilityContext(
            axRead: appRead,
            secureInputRead: StubSecureInputRead(),
            workingDirectoryRead: libprocRead.read)

        let snapshot = context.resolveCurrent()

        XCTAssertEqual(
            snapshot,
            ContextSnapshot(
                bundleID: "com.apple.Notes", windowTitle: "Untitled",
                selectedText: "the quick brown fox"),
            "resolution must be byte-identical whether or not the cwd read exists — the "
                + "metadata lane never rides the snapshot")
        XCTAssertEqual(
            context.workingDirectory(), "/Users/aliz/dev/at/vocca",
            "the cwd read answers independently of the snapshot — the two lanes never touch")
        XCTAssertEqual(
            appRead.contextReadCount, 1,
            "one resolution, one context read — the working-directory read adds no context read")
    }
}